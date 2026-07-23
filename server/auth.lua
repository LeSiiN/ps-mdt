-- Authorisation --

local function isDojJob(jobName)
    if not jobName or not Config.DojJobs then return false end
    for _, name in ipairs(Config.DojJobs) do
        if name == jobName then return true end
    end
    return false
end

function CheckAuth(source)
    -- Never feed an invalid/offline source into the framework bridge: some
    -- bridges index the player object without a nil-check and raise a non-string
    -- error ("attempt to index a nil value (local player)"). If that happens
    -- inside a NUI callback it never replies, and the UI hangs until it times
    -- out. Fail closed instead of crashing.
    if not source or (tonumber(source) or 0) <= 0 then
        return false
    end

    local ok, jobType, jobName = pcall(function()
        return ps.getJobType(source), ps.getJobName(source)
    end)
    if not ok then
        return false
    end

    ps.debug('Checking MDT Authorization')
    local dojCheck = isDojJob(jobName) or (Config.DojJobType and jobType == Config.DojJobType)
    if jobType ~= Config.PoliceJobType and jobType ~= Config.MedicalJobType and not dojCheck then
        ps.debug('Access Denied for ID: ' .. tostring(source) .. ', not an authorized job type')
        return false
    end
    ps.debug('Access Granted for ID: ' .. tostring(source) .. ', job type: ' .. tostring(jobType))
    return true
end

-- Check if a player has a specific permission (by job + grade lookup)

-- ── Department policy permissions ────────────────────────────────────────────
-- Config.PermissionDefaults grants permissions by rank the way a department's
-- own regulations would: they are not something a supervisor hands out in the
-- MDT, they come with the rank itself.
--
-- Three modes decide how they interact with what a boss configures in the
-- Management tab (Config.PermissionDefaultsMode):
--
--   'merge'         policy ALWAYS applies, on top of whatever is stored.
--                   Adding a permission to the config takes effect
--                   immediately, including for ranks that were saved long ago.
--   'seed'          the pre-2.x behaviour: the moment a rank is saved in the
--                   MDT, its stored list is the only thing that counts and the
--                   config is ignored for that rank forever.
--   'authoritative' policy wins outright — for servers that manage permissions
--                   in the file only and want the MDT to be read-only.
---@return string
local function permissionDefaultsMode()
    local mode = Config and Config.PermissionDefaultsMode
    if mode == 'seed' or mode == 'authoritative' then return mode end
    return 'merge'
end

--- Permissions granted by department policy for a job + grade.
---
--- Ranks build on each other, so by default a grade inherits everything the
--- lower grades are granted — defining grade 0 and grade 5 no longer leaves
--- grades 1-4 with nothing. Set Config.PermissionDefaultsCumulative = false
--- for strict per-grade lists.
---@param jobName string
---@param gradeValue number|string
---@return table
function GetPolicyPermissions(jobName, gradeValue)
    local defaults = Config and Config.PermissionDefaults and Config.PermissionDefaults[jobName]
    if type(defaults) ~= 'table' then return {} end

    local out, seen = {}, {}
    local function add(list)
        for _, perm in ipairs(list or {}) do
            if perm and not seen[perm] then
                seen[perm] = true
                out[#out + 1] = perm
            end
        end
    end

    local target = tonumber(gradeValue)
    if target == nil or (Config and Config.PermissionDefaultsCumulative == false) then
        add(defaults[tostring(gradeValue)])
        return out
    end

    for key, list in pairs(defaults) do
        local keyNum = tonumber(key)
        if keyNum and keyNum <= target then add(list) end
    end
    return out
end

--- Is `permName` granted by department policy for this job + grade?
---@return boolean
function HasPolicyPermission(jobName, gradeValue, permName)
    for _, perm in ipairs(GetPolicyPermissions(jobName, gradeValue)) do
        if perm == permName then return true end
    end
    return false
end

--- The active mode, exposed so the management tab can describe it.
---@return string
function GetPermissionDefaultsMode()
    return permissionDefaultsMode()
end

function CheckPermission(source, permName)
    if not source or not permName then return false end

    -- Boss always has all permissions
    if ps.isBoss and ps.isBoss(source) then return true end

    local jobData = ps.getJobData and ps.getJobData(source) or nil
    local isBoss = false
    local gradeValue = 0

    if jobData and jobData.grade then
        if type(jobData.grade) == 'table' then
            gradeValue = jobData.grade.level or jobData.grade.grade or jobData.grade.rank or jobData.grade.value or jobData.grade.id or 0
            isBoss = jobData.grade.isboss == true or jobData.grade.isBoss == true or jobData.grade.boss == true
        else
            gradeValue = jobData.grade
        end
    end

    if isBoss then return true end

    local jobName = ps.getJobName(source) or 'police'
    local gradeStr = tostring(gradeValue)

    local mode = permissionDefaultsMode()

    -- Policy first when it outranks the MDT.
    if mode == 'authoritative' then
        return HasPolicyPermission(jobName, gradeValue, permName)
    end

    -- What a supervisor configured in the Management tab.
    local row = MySQL.single.await('SELECT permissions FROM mdt_permission_roles WHERE job = ? AND grade = ?', { jobName, tonumber(gradeStr) })
    if row and row.permissions then
        local ok, decoded = pcall(json.decode, row.permissions)
        if ok and type(decoded) == 'table' then
            for _, p in ipairs(decoded) do
                if p == permName then return true end
            end
            -- 'seed' stops here: once a rank has been saved, its stored list
            -- is the whole truth. In 'merge' the rank still keeps whatever
            -- department policy grants it.
            if mode == 'seed' then return false end
        end
    end

    return HasPolicyPermission(jobName, gradeValue, permName)
end

local function upsertProfileSession(src, action)
    if not src then return end
    local citizenid = ps.getIdentifier(src)
    if not citizenid then return end

    -- On logout — and especially on playerDropped — the player is already gone from the
    -- framework, so any live ps.* lookup (getMetadata, getPlayerName, getJobData) indexes
    -- a nil player and errors. The logout branch below only needs the profile id anyway,
    -- so we resolve just that from the DB and skip everything that touches the live player.
    if action ~= 'login' then
        -- Resolve the profile straight from the DB (the player row may already be gone)
        -- and close its open session. No live lookups, no callsign work — none of it is
        -- needed to stamp a logout time.
        local profileId = MySQL.scalar.await(
            'SELECT id FROM mdt_profiles WHERE citizenid = ? LIMIT 1', { citizenid })
        if not profileId then return end

        local okTx, errTx = pcall(MySQL.transaction.await, {
            {
                query = [[
                    UPDATE mdt_profile_sessions
                    SET logout_at = NOW()
                    WHERE profile_id = ? AND logout_at IS NULL
                    ORDER BY id DESC
                    LIMIT 1
                ]],
                values = { profileId }
            },
            {
                query = 'UPDATE mdt_profiles SET last_logout_at = NOW() WHERE id = ?',
                values = { profileId }
            },
        })
        if not okTx then
            ps.warn('Failed to update logout session (transaction): ' .. tostring(errTx))
        end
        return
    end

    -- Login path: the player is online, so live lookups are safe.
    local fullName = ps.getPlayerName(src)
    local job = ps.getJobData and ps.getJobData(src) or nil
    local jobName = job and job.name or ps.getJobName(src)
    local jobGrade = job and job.grade and job.grade.name or ps.getJobGradeName(src)

    local existing = MySQL.scalar.await(
        'SELECT callsign FROM mdt_profiles WHERE citizenid = ? LIMIT 1', { citizenid })
    local metaCallsign = ps.getMetadata(src, 'callsign')

    local callsign
    if existing and existing ~= '' then
        callsign = existing
        -- Heal the cache so the uniqueness check (which reads player metadata) and the
        -- TopBar readout stop showing the stale number.
        if metaCallsign ~= existing then
            local Player = ps.getPlayerByIdentifier(citizenid)
            if Player and Player.Functions and Player.Functions.SetMetaData then
                Player.Functions.SetMetaData('callsign', existing)
                PersistLiveMetadata(Player, citizenid)
            end
        end
    else
        callsign = metaCallsign
    end

    local ok, profileId = pcall(EnsureProfileData,
        citizenid,
        fullName,
        callsign,
        callsign,
        jobGrade,
        jobName
    )

    if not ok or not profileId then
        ps.warn('Failed to upsert profile session for ' .. tostring(citizenid) .. ': ' .. tostring(profileId))
        return
    end

    -- Only the login path reaches here (logout returned early above).
    local okTx, errTx = pcall(MySQL.transaction.await, {
        {
            query = [[
                UPDATE mdt_profile_sessions
                SET logout_at = NOW()
                WHERE profile_id = ? AND logout_at IS NULL
            ]],
            values = { profileId }
        },
        {
            query = [[
                INSERT INTO mdt_profile_sessions (profile_id, citizenid, source, login_at)
                VALUES (?, ?, ?, NOW())
            ]],
            values = { profileId, citizenid, src }
        },
        {
            query = 'UPDATE mdt_profiles SET last_login_at = NOW() WHERE id = ?',
            values = { profileId }
        },
    })
    if not okTx then
        ps.warn('Failed to create login session (transaction): ' .. tostring(errTx))
    end
end

-- FiveManage log helper for duty logging
local function SendDutyLog(officerName, citizenid, action, jobName)
    if not FiveManageQueueLog then return end

    FiveManageQueueLog({
        action = action == 'login' and 'mdt_clock_in' or 'mdt_clock_out',
        category = 'duty',
        message = (action == 'login' and 'Clock In' or 'Clock Out') .. ': ' .. (officerName or 'Unknown'),
        metadata = {
            officer = officerName or 'Unknown',
            citizenid = citizenid or 'N/A',
            department = jobName or 'Unknown',
            time = os.date('%Y-%m-%d %H:%M:%S')
        }
    })
end

RegisterNetEvent('ps-mdt:server:trackLogin', function()
    local src = source
    upsertProfileSession(src, 'login')
    if ps.auditLog then
        ps.auditLog(src, 'mdt_login', 'profile', ps.getIdentifier(src), {})
    end
    -- FiveManage duty log
    local officerName = ps.getPlayerName(src) or 'Unknown'
    local citizenid = ps.getIdentifier(src) or 'N/A'
    local jobName = ps.getJobName(src) or 'Unknown'
    SendDutyLog(officerName, citizenid, 'login', jobName)
end)

RegisterNetEvent('ps-mdt:server:trackLogout', function()
    local src = source
    upsertProfileSession(src, 'logout')
    if ps.auditLog then
        ps.auditLog(src, 'mdt_logout', 'profile', ps.getIdentifier(src), {})
    end
    -- FiveManage duty log
    local officerName = ps.getPlayerName(src) or 'Unknown'
    local citizenid = ps.getIdentifier(src) or 'N/A'
    local jobName = ps.getJobName(src) or 'Unknown'
    SendDutyLog(officerName, citizenid, 'logout', jobName)
end)

AddEventHandler('playerDropped', function()
    local src = source
    -- The player is already disconnected here, so even resolving their identifier can
    -- fail depending on the framework's teardown order. Wrap it so a dropped session can
    -- never surface as a console error on leave.
    pcall(upsertProfileSession, src, 'logout')
end)

ps.registerCallback(tostring(GetCurrentResourceName())..':server:checkAuth', function(source)
    local civAccess = Config.CivilianAccess and Config.CivilianAccess.enabled
    local isAuthed = CheckAuth(source)
    if isAuthed then
        return isAuthed
    end

    -- If not LEO/EMS but civilian access is enabled, return civilian flag
    if civAccess then
        return { isCivilian = true }
    end

    return false
end)

-- Get the current player's permissions based on their job + grade
ps.registerCallback(tostring(GetCurrentResourceName())..':server:getMyPermissions', function(source)
    local src = source
    if not CheckAuth(src) then return { permissions = {} } end

    local jobName = ps.getJobName(src) or 'police'
    local jobData = ps.getJobData and ps.getJobData(src) or nil
    local gradeValue = 0
    local isBoss = false

    if jobData and jobData.grade then
        if type(jobData.grade) == 'table' then
            gradeValue = jobData.grade.level or jobData.grade.grade or jobData.grade.rank or jobData.grade.value or jobData.grade.id or 0
            isBoss = jobData.grade.isboss == true or jobData.grade.isBoss == true or jobData.grade.boss == true
        else
            gradeValue = jobData.grade
        end
    end

    -- Boss gets all permissions
    if isBoss or (ps.isBoss and ps.isBoss(src)) then
        local allPerms = (Config and Config.ManagementPermissions) or {}
        return { permissions = allPerms, isBoss = true }
    end

    local gradeStr = tostring(gradeValue)

    local mode = GetPermissionDefaultsMode()
    local policy = GetPolicyPermissions(jobName, gradeValue)

    if mode == 'authoritative' then
        return { permissions = policy, isBoss = false }
    end

    local granted, seen = {}, {}
    local function add(list)
        for _, perm in ipairs(list or {}) do
            if perm and not seen[perm] then
                seen[perm] = true
                granted[#granted + 1] = perm
            end
        end
    end

    -- Stored role first, so the list reads in the order a supervisor set it.
    local stored, hasStored = nil, false
    local row = MySQL.single.await('SELECT permissions FROM mdt_permission_roles WHERE job = ? AND grade = ?', { jobName, tonumber(gradeStr) })
    if row and row.permissions then
        local ok, decoded = pcall(json.decode, row.permissions)
        if ok and type(decoded) == 'table' then
            stored, hasStored = decoded, true
            add(decoded)
        end
    end

    -- In 'seed', a saved rank ignores policy entirely; in 'merge' policy is
    -- always added on top.
    if not (mode == 'seed' and hasStored) then
        add(policy)
    end

    return { permissions = granted, isBoss = false }
end)