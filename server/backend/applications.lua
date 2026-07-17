local resourceName = tostring(GetCurrentResourceName())

-- ── Config helpers ───────────────────────────────────────────────────────────
local function appCfg()
    return (Config and Config.Applications) or {}
end

local function isEnabled()
    return appCfg().Enabled == true
end

-- Is `department` one the config actually defines? Guards every server path against a
-- forged department id in a payload.
local function isKnownDepartment(dept)
    for _, d in ipairs(appCfg().Departments or {}) do
        if d.id == dept then return true end
    end
    return false
end

-- The MDT's built-in domain is only police-vs-ems, and it lumps DOJ in with police.
-- Applications need three separate buckets — police, ems, doj — so a judge doesn't manage
-- LSPD's questions and an officer doesn't manage the DOJ's. We resolve a finer bucket by
-- checking the DOJ job list explicitly BEFORE falling back to the police/ems split.
local function isDojJob(jobName)
    if not jobName then return false end
    for _, name in ipairs((Config and Config.DojJobs) or {}) do
        if name == jobName then return true end
    end
    return false
end

-- One of 'police' | 'ems' | 'doj' for the caller.
local function applicantBucketForSrc(src)
    local jobName = ps.getJobName and ps.getJobName(src) or nil
    if isDojJob(jobName) then return 'doj' end
    return GetMdtDomain(src) == 'ems' and 'ems' or 'police'
end

-- Which department id does a configured department belong to? Mirrors the buckets above.
local function bucketForDepartment(deptId)
    if deptId == 'ambulance' or deptId == 'ems' then return 'ems' end
    if deptId == 'doj' then return 'doj' end
    return 'police'
end

-- Which department ids may the caller touch? Exactly those in their own bucket — police
-- sees police, ems sees ems, doj sees doj, with no overlap.
local function departmentsForDomain(src)
    local bucket = applicantBucketForSrc(src)
    local out = {}
    for _, d in ipairs(appCfg().Departments or {}) do
        if bucketForDepartment(d.id) == bucket then
            out[#out + 1] = d.id
        end
    end
    return out
end

-- Is this department one the caller's domain is allowed to touch?
local function isDepartmentInDomain(src, dept)
    for _, d in ipairs(departmentsForDomain(src)) do
        if d == dept then return true end
    end
    return false
end

local VALID_TYPES = {
    short = true, long = true, choice = true, boolean = true, number = true, link = true,
}

-- ── Self-healing schema ──────────────────────────────────────────────────────
-- Mirrors the pattern used elsewhere: create the tables if the SQL wasn't run, so the
-- feature works on a fresh install without a manual migration step.
CreateThread(function()
    Wait(2500)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `mdt_application_questions` (
          `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
          `department` varchar(50) NOT NULL,
          `label` varchar(300) NOT NULL,
          `type` enum('short','long','choice','boolean','number','link') NOT NULL DEFAULT 'short',
          `options` text DEFAULT NULL,
          `required` tinyint(1) NOT NULL DEFAULT 0,
          `sort_order` int(10) NOT NULL DEFAULT 0,
          `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
          PRIMARY KEY (`id`),
          KEY `department` (`department`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `mdt_applications` (
          `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
          `application_number` varchar(20) NOT NULL,
          `department` varchar(50) NOT NULL,
          `applicant_citizenid` varchar(50) NOT NULL,
          `applicant_name` varchar(100) NOT NULL,
          `applicant_phone` varchar(20) DEFAULT NULL,
          `answers` longtext NOT NULL,
          `status` enum('pending','accepted','rejected') NOT NULL DEFAULT 'pending',
          `reviewed_by` varchar(50) DEFAULT NULL,
          `reviewed_by_name` varchar(100) DEFAULT NULL,
          `review_note` text DEFAULT NULL,
          `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
          `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
          PRIMARY KEY (`id`),
          UNIQUE KEY `application_number` (`application_number`),
          KEY `department` (`department`),
          KEY `status` (`status`),
          KEY `applicant_citizenid` (`applicant_citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
end)

local function buildApplicationNumber(id)
    return ('APP-%s-%05d'):format(os.date('%Y'), id)
end

-- ── Reading questions ────────────────────────────────────────────────────────
-- Shared shape used by both the applicant form and the editor. `options` is decoded
-- from its JSON column into a real array (or nil).
local function fetchQuestions(department)
    local rows = MySQL.query.await([[
        SELECT id, department, label, type, options, required, sort_order
        FROM mdt_application_questions
        WHERE department = ?
        ORDER BY sort_order ASC, id ASC
    ]], { department }) or {}

    for _, q in ipairs(rows) do
        q.required = (q.required == 1 or q.required == true)
        if q.options and q.options ~= '' then
            local ok, decoded = pcall(json.decode, q.options)
            q.options = (ok and type(decoded) == 'table') and decoded or nil
        else
            q.options = nil
        end
    end
    return rows
end

-- Applicant-facing: the questions for a department's form. NO auth — any civilian can
-- open an application form. Returns the department label too so the form can title itself.
ps.registerCallback(resourceName .. ':server:getApplicationForm', function(source, department)
    if not isEnabled() then return { success = false, message = 'Applications are disabled' } end
    if not isKnownDepartment(department) then
        return { success = false, message = 'Unknown department' }
    end

    local label
    for _, d in ipairs(appCfg().Departments or {}) do
        if d.id == department then label = d.label break end
    end

    return { success = true, department = department, label = label or department,
             questions = fetchQuestions(department) }
end)

-- ── Submitting an application ─────────────────────────────────────────────────
local SubmitCooldown = {}   -- [citizenid .. ':' .. department] = GetGameTimer()

ps.registerCallback(resourceName .. ':server:submitApplication', function(source, payload)
    if not isEnabled() then return { success = false, message = 'Applications are disabled' } end

    local src = source
    payload = payload or {}
    local department = payload.department
    if not isKnownDepartment(department) then
        return { success = false, message = 'Unknown department' }
    end

    local citizenid = ps.getIdentifier(src)
    if not citizenid then return { success = false, message = 'Missing citizen id' } end

    -- Per-department anti-spam.
    local cooldownMs = appCfg().CooldownMs or 0
    if cooldownMs > 0 then
        local key = citizenid .. ':' .. department
        local last = SubmitCooldown[key]
        if last and (GetGameTimer() - last) < cooldownMs then
            local wait = math.ceil((cooldownMs - (GetGameTimer() - last)) / 1000)
            return { success = false, message = ('Please wait %ds before applying again.'):format(wait) }
        end
    end

    -- Re-fetch the questions server-side and validate against THEM, never trusting the
    -- client's idea of the form. This also produces the answer snapshot we store, so a
    -- later edit to a question can't rewrite what an applicant was actually asked.
    local questions = fetchQuestions(department)
    if #questions == 0 then
        return { success = false, message = 'This department is not accepting applications yet.' }
    end

    local maxLen = appCfg().MaxAnswerLength or 2000
    local clientAnswers = type(payload.answers) == 'table' and payload.answers or {}
    local snapshot = {}

    for _, q in ipairs(questions) do
        local raw = clientAnswers[tostring(q.id)]
        local answer

        if q.type == 'boolean' then
            answer = (raw == true or raw == 'true' or raw == 1) and 'Yes' or 'No'
        elseif q.type == 'number' then
            local n = tonumber(raw)
            answer = n and tostring(n) or ''
        else
            answer = type(raw) == 'string' and raw:sub(1, maxLen) or ''
        end

        -- Required-field enforcement (server-side, so a crafted payload can't skip it).
        -- A boolean is never "missing" — No is a valid answer.
        if q.required and q.type ~= 'boolean' and answer == '' then
            return { success = false, message = ('"%s" is required.'):format(q.label) }
        end

        -- A choice answer must be one of the offered options.
        if q.type == 'choice' and answer ~= '' then
            local ok = false
            for _, opt in ipairs(q.options or {}) do
                if opt == answer then ok = true break end
            end
            if not ok then return { success = false, message = ('Invalid selection for "%s".'):format(q.label) } end
        end

        snapshot[#snapshot + 1] = { label = q.label, type = q.type, answer = answer }
    end

    local applicantName = ps.getPlayerName(src) or 'Unknown'
    local phone = GetCitizenPhoneNumber and GetCitizenPhoneNumber(citizenid, nil) or nil

    local id = MySQL.insert.await([[
        INSERT INTO mdt_applications
            (application_number, department, applicant_citizenid, applicant_name,
             applicant_phone, answers, status)
        VALUES ('', ?, ?, ?, ?, ?, 'pending')
    ]], { department, citizenid, applicantName, phone, json.encode(snapshot) })

    if not id then return { success = false, message = 'Could not submit application.' } end

    local number = buildApplicationNumber(id)
    MySQL.update.await('UPDATE mdt_applications SET application_number = ? WHERE id = ?', { number, id })

    if cooldownMs > 0 then
        SubmitCooldown[citizenid .. ':' .. department] = GetGameTimer()
    end

    return { success = true, number = number }
end)

-- The configured departments, for the editor's tab strip. Auth-gated like the rest of
-- the editor.
ps.registerCallback(resourceName .. ':server:getApplicationDepartments', function(source)
    if not CheckAuth(source) then return { success = false, departments = {} } end
    -- Scope to the caller's domain: LSPD sees police (+ DOJ), EMS sees EMS. Without this
    -- an LSPD officer could open — and edit — EMS's application questions.
    local allowed = departmentsForDomain(source)
    local allowedSet = {}
    for _, id in ipairs(allowed) do allowedSet[id] = true end

    local out = {}
    for _, d in ipairs(appCfg().Departments or {}) do
        if allowedSet[d.id] then
            out[#out + 1] = { id = d.id, label = d.label or d.id }
        end
    end
    return { success = true, departments = out }
end)

-- ── Question editor (MDT-side, permission-gated) ──────────────────────────────
-- These power Management → Applications. They require auth AND the management_settings
-- permission, the same gate the other editable-config tabs use.
local function canManage(src)
    if not CheckAuth(src) then return false end
    return CheckPermission(src, 'management_settings')
end

-- List questions for a department, for the editor.
ps.registerCallback(resourceName .. ':server:getApplicationQuestions', function(source, department)
    if not canManage(source) then return { success = false, message = 'Unauthorized' } end
    if not isKnownDepartment(department) then return { success = false, message = 'Unknown department' } end
    if not isDepartmentInDomain(source, department) then return { success = false, message = 'Unauthorized' } end
    return { success = true, questions = fetchQuestions(department) }
end)

-- Normalise + validate one question coming from the editor.
local function sanitizeQuestion(q)
    q = q or {}
    local label = type(q.label) == 'string' and q.label:sub(1, 300) or ''
    if label == '' then return nil, 'A question needs a label.' end

    local qtype = tostring(q.type or 'short')
    if not VALID_TYPES[qtype] then return nil, 'Invalid question type.' end

    local options = nil
    if qtype == 'choice' then
        local list = {}
        for _, opt in ipairs(type(q.options) == 'table' and q.options or {}) do
            if type(opt) == 'string' and opt ~= '' then list[#list + 1] = opt:sub(1, 200) end
        end
        if #list < 2 then return nil, 'A choice question needs at least two options.' end
        options = json.encode(list)
    end

    return {
        label = label,
        type = qtype,
        options = options,
        required = (q.required == true or q.required == 1) and 1 or 0,
    }
end

ps.registerCallback(resourceName .. ':server:saveApplicationQuestion', function(source, payload)
    if not canManage(source) then return { success = false, message = 'Unauthorized' } end
    payload = payload or {}
    local department = payload.department
    if not isKnownDepartment(department) then return { success = false, message = 'Unknown department' } end
    if not isDepartmentInDomain(source, department) then return { success = false, message = 'Unauthorized' } end

    local clean, err = sanitizeQuestion(payload)
    if not clean then return { success = false, message = err } end

    if payload.id then
        -- Update. sort_order left untouched here (reordering is its own call).
        MySQL.update.await([[
            UPDATE mdt_application_questions
            SET label = ?, type = ?, options = ?, required = ?
            WHERE id = ? AND department = ?
        ]], { clean.label, clean.type, clean.options, clean.required, payload.id, department })
        return { success = true, id = payload.id }
    end

    -- Insert at the end of the department's list.
    local maxOrder = MySQL.scalar.await(
        'SELECT COALESCE(MAX(sort_order), 0) FROM mdt_application_questions WHERE department = ?',
        { department }) or 0
    local id = MySQL.insert.await([[
        INSERT INTO mdt_application_questions (department, label, type, options, required, sort_order)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { department, clean.label, clean.type, clean.options, clean.required, maxOrder + 1 })

    if not id then return { success = false, message = 'Could not save question.' } end
    return { success = true, id = id }
end)

ps.registerCallback(resourceName .. ':server:deleteApplicationQuestion', function(source, payload)
    if not canManage(source) then return { success = false, message = 'Unauthorized' } end
    payload = payload or {}
    if not payload.id then return { success = false, message = 'Missing question id' } end

    -- The payload only carries an id, so resolve the question's department and make sure
    -- it's one this domain may touch before deleting.
    local dept = MySQL.scalar.await(
        'SELECT department FROM mdt_application_questions WHERE id = ?', { payload.id })
    if dept and not isDepartmentInDomain(source, dept) then
        return { success = false, message = 'Unauthorized' }
    end

    MySQL.update.await('DELETE FROM mdt_application_questions WHERE id = ?', { payload.id })
    return { success = true }
end)

-- Persist a new order: payload.order is an array of question ids in the desired sequence.
ps.registerCallback(resourceName .. ':server:reorderApplicationQuestions', function(source, payload)
    if not canManage(source) then return { success = false, message = 'Unauthorized' } end
    payload = payload or {}
    local department = payload.department
    if not isKnownDepartment(department) then return { success = false, message = 'Unknown department' } end
    if not isDepartmentInDomain(source, department) then return { success = false, message = 'Unauthorized' } end
    local order = type(payload.order) == 'table' and payload.order or {}

    for i, id in ipairs(order) do
        MySQL.update.await(
            'UPDATE mdt_application_questions SET sort_order = ? WHERE id = ? AND department = ?',
            { i, id, department })
    end
    return { success = true }
end)


-- ── Reviewing applications (Roster → Applications) ────────────────────────────
-- Officers with roster management permission list, read and decide applications for
-- their own domain. Applicants only ever see their own; here we scope by department so
-- police can't leaf through EMS applications and vice-versa.


local function canReview(src)
    if not CheckAuth(src) then return false end
    return CheckPermission(src, 'roster_manage_officers')
end

-- List applications, newest first, scoped to the caller's domain and optionally filtered
-- by status. Answers aren't decoded here — the list only needs headers.
ps.registerCallback(resourceName .. ':server:getApplications', function(source, payload)
    if not canReview(source) then return { success = false, applications = {} } end
    payload = payload or {}

    local depts = departmentsForDomain(source)
    if #depts == 0 then return { success = true, applications = {} } end

    -- Build the IN (...) placeholder list for the domain's departments.
    local placeholders = {}
    local params = {}
    for _, d in ipairs(depts) do
        placeholders[#placeholders + 1] = '?'
        params[#params + 1] = d
    end

    local statusFilter = ''
    if payload.status == 'pending' or payload.status == 'accepted' or payload.status == 'rejected' then
        statusFilter = ' AND status = ?'
        params[#params + 1] = payload.status
    end

    local rows = MySQL.query.await(([[
        SELECT id, application_number, department, applicant_name, applicant_citizenid,
               status, reviewed_by_name, created_at
        FROM mdt_applications
        WHERE department IN (%s)%s
        ORDER BY
            CASE status WHEN 'pending' THEN 0 ELSE 1 END,  -- pending float to the top
            id DESC
        LIMIT 200
    ]]):format(table.concat(placeholders, ','), statusFilter), params) or {}

    return { success = true, applications = rows }
end)

-- Full detail of one application, including the decoded answer snapshot.
ps.registerCallback(resourceName .. ':server:getApplication', function(source, payload)
    if not canReview(source) then return { success = false } end
    payload = payload or {}
    if not payload.id then return { success = false, message = 'Missing id' } end

    local row = MySQL.single.await([[
        SELECT * FROM mdt_applications WHERE id = ?
    ]], { payload.id })
    if not row then return { success = false, message = 'Not found' } end

    -- Domain scoping: don't let one side open the other's applications by id.
    local allowed = false
    for _, d in ipairs(departmentsForDomain(source)) do
        if d == row.department then allowed = true break end
    end
    if not allowed then return { success = false, message = 'Not found' } end

    local ok, answers = pcall(json.decode, row.answers or '[]')
    row.answers = (ok and type(answers) == 'table') and answers or {}

    -- Attach the applicant's profile picture from their file, so the reviewer sees the
    -- same portrait the citizen record shows (and can open it in a lightbox).
    local pic = MySQL.scalar.await(
        'SELECT profilepicture FROM mdt_profiles WHERE citizenid = ? LIMIT 1',
        { row.applicant_citizenid })
    row.applicant_image = (pic and pic ~= '') and pic or nil
    return { success = true, application = row }
end)

-- Notify the applicant of a decision, if configured and a mail bridge exists.
local function notifyDecision(row, status, note)
    if appCfg().NotifyOnDecision ~= true then return end
    if not SendCitizenMail then return end
    if not row.applicant_citizenid then return end

    local deptLabel = row.department
    for _, d in ipairs(appCfg().Departments or {}) do
        if d.id == row.department then deptLabel = d.label or d.id break end
    end

    local verdict = status == 'accepted' and 'accepted' or 'not successful'
    local body = ('Your application %s to %s was %s.'):format(
        row.application_number or '', deptLabel, verdict)
    if note and note ~= '' then
        body = body .. ('\n\nNote from the reviewer:\n%s'):format(note)
    end

    SendCitizenMail(
        row.applicant_citizenid,
        deptLabel .. ' Recruitment',
        ('Application %s — decision'):format(row.application_number or ''),
        body
    )
end

-- Accept or reject. A note is optional and travels to the applicant with the decision.
ps.registerCallback(resourceName .. ':server:decideApplication', function(source, payload)
    if not canReview(source) then return { success = false, message = 'Unauthorized' } end
    payload = payload or {}
    local id = payload.id
    local status = payload.status
    if not id then return { success = false, message = 'Missing id' } end
    if status ~= 'accepted' and status ~= 'rejected' then
        return { success = false, message = 'Invalid decision' }
    end

    local row = MySQL.single.await('SELECT * FROM mdt_applications WHERE id = ?', { id })
    if not row then return { success = false, message = 'Not found' } end

    -- Domain scoping again — the decision path is a write, so guard it independently.
    local allowed = false
    for _, d in ipairs(departmentsForDomain(source)) do
        if d == row.department then allowed = true break end
    end
    if not allowed then return { success = false, message = 'Not found' } end

    local note = type(payload.note) == 'string' and payload.note:sub(1, 1000) or nil
    local reviewerCid = ps.getIdentifier(source)
    local reviewerName = ps.getPlayerName(source) or 'Unknown'

    MySQL.update.await([[
        UPDATE mdt_applications
        SET status = ?, reviewed_by = ?, reviewed_by_name = ?, review_note = ?
        WHERE id = ?
    ]], { status, reviewerCid, reviewerName, note, id })

    -- Fire-and-forget the applicant notification; a mail failure must not fail the review.
    pcall(notifyDecision, row, status, note)

    if ps.auditLog then
        ps.auditLog(source, 'mdt_application_' .. status, 'application',
            row.application_number or tostring(id), {})
    end

    return { success = true }
end)