local resourceName = tostring(GetCurrentResourceName())

local function getEffectiveJobType(src)
    local jobType = ps.getJobType(src)
    local jobName = ps.getJobName(src)
    if Config.DojJobs then
        for _, name in ipairs(Config.DojJobs) do
            if name == jobName then return 'doj' end
        end
    end
    if Config.DojJobType and jobType == Config.DojJobType then return 'doj' end
    -- Normalise to a stable MDT domain (name + type aware) instead of returning
    -- the raw core job type, so EMS is detected even when its type isn't "ems".
    if IsEmsJob(jobName, jobType) then return 'ems' end
    return 'leo'
end

local function computeJobData(src)
    return {
        rank    = ps.getJobGradeName(src) or 'Officer',
        payRate = '$' .. (ps.getJobGradePay(src) or 300) .. '/hr',
    }
end

ps.registerCallback(resourceName .. ':server:getJobData', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return {} end
    return computeJobData(src)
end)

local function computeReportStatistics()
    return Cache.getOrSet('dashboard:reportStats', Config.CacheTTL and Config.CacheTTL.ReportStats or 30, function()
        local response = MySQL.query.await([[
            SELECT
                COUNT(CASE WHEN datecreated >= NOW() - INTERVAL 1 WEEK THEN 1 END) AS totalThisWeek,
                COUNT(CASE WHEN datecreated >= NOW() - INTERVAL 2 WEEK AND datecreated < NOW() - INTERVAL 1 WEEK THEN 1 END) AS totalLastWeek
            FROM mdt_reports
        ]], {})

        local row = response and response[1] or { totalThisWeek = 0, totalLastWeek = 0 }
        return {
            totalThisWeek      = tonumber(row.totalThisWeek) or 0,
            changeFromLastWeek = (tonumber(row.totalThisWeek) or 0) - (tonumber(row.totalLastWeek) or 0),
        }
    end)
end

ps.registerCallback(resourceName .. ':server:getReportStatistics', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return {} end
    return computeReportStatistics()
end)

local function computeTimeStatistics(src)
    local citizenid = ps.getIdentifier(src)
    if not citizenid then return {} end

    local rows = MySQL.query.await([[
        SELECT DATE(login_at) AS day,
               SUM(TIMESTAMPDIFF(SECOND, login_at, COALESCE(logout_at, NOW()))) AS seconds
        FROM mdt_profile_sessions
        WHERE citizenid = ?
          AND login_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
        GROUP BY DATE(login_at)
        ORDER BY day ASC
    ]], { citizenid })

    local secondsByDay = {}
    for _, row in ipairs(rows or {}) do
        secondsByDay[tostring(row.day)] = tonumber(row.seconds) or 0
    end

    local result = {}
    for i = 6, 0, -1 do
        local dayTs  = os.time() - (i * 24 * 60 * 60)
        local dayKey = os.date('%Y-%m-%d', dayTs)
        local label  = os.date('%a', dayTs)
        result[#result + 1] = {
            day   = label,
            hours = math.floor(((secondsByDay[dayKey] or 0) / 3600) * 10) / 10,
        }
    end
    return result
end

ps.registerCallback(resourceName .. ':server:getTimeStatistics', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return {} end
    return computeTimeStatistics(src)
end)

-- Active warrants handled in server/backend/warrants.lua

local function computeBulletins()
    local rows = MySQL.query.await('SELECT id, content FROM mdt_bulletins ORDER BY id DESC')
    if not rows or #rows == 0 then
        return { { content = 'No bulletins found..' } }
    end
    return rows
end

ps.registerCallback(resourceName .. ':server:getBulletins', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return {} end
    return computeBulletins()
end)

ps.registerCallback(resourceName .. ':server:createBulletin', function(source, payload)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end

    payload = payload or {}
    local content = payload.content
    if not content or content == '' then
        return { success = false, message = 'Bulletin content is required' }
    end

    local inserted = MySQL.insert.await('INSERT INTO mdt_bulletins (content) VALUES (?)', { content })
    if not inserted then
        return { success = false, message = 'Failed to create bulletin' }
    end

    Cache.invalidate('dashboard:bulletins')
    return { success = true, id = inserted }
end)

ps.registerCallback(resourceName .. ':server:deleteBulletin', function(source, payload)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end

    payload = payload or {}
    local id = tonumber(payload.id)
    if not id then
        return { success = false, message = 'Invalid bulletin ID' }
    end

    MySQL.query.await('DELETE FROM mdt_bulletins WHERE id = ?', { id })
    Cache.invalidate('dashboard:bulletins')
    return { success = true }
end)

ps.registerCallback(resourceName .. ':server:getRecentReports', function(source, page, limit)
    local src      = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return {} end
    local pageNumber = math.max(1, tonumber(page) or 1)
    local pageSize   = math.min(50, math.max(1, tonumber(limit) or 10))

    local identifier = ps.getIdentifier(src)
    local job        = ps.getJobName(src)
    local jobType    = getEffectiveJobType(src)
    local offset     = (pageNumber - 1) * pageSize

    local rows = MySQL.query.await([[
        SELECT mr.id, mr.title, mr.type, mr.contentplaintext, mr.author, mr.authorplaintext, mr.datecreated, mr.dateupdated
        FROM mdt_reports mr
        LEFT JOIN mdt_reports_restrictions mrr ON mr.id = mrr.reportid
        WHERE (
            (? = 'doj' AND NOT EXISTS(
                SELECT 1 FROM mdt_reports_restrictions mrr_ems
                WHERE mrr_ems.reportid = mr.id AND mrr_ems.type = 'jobtype' AND mrr_ems.identifier = 'ems'
            ))
            OR (mrr.reportid IS NULL AND (? = 'leo' OR ? = 'ems'))
            OR (mrr.type = 'citizenid' AND mrr.identifier = ?)
            OR (mrr.type = 'job'       AND mrr.identifier = ?)
            OR (mrr.type = 'jobtype'   AND mrr.identifier = ?)
        )
        GROUP BY mr.id
        ORDER BY mr.datecreated DESC
        LIMIT ?
        OFFSET ?
    ]], { jobType, jobType, jobType, identifier, job, jobType, pageSize, offset })
    return rows or {}
end)

local function computeActiveBolos(src)
    local BOLOS = MySQL.query.await('SELECT id, type, subject_id, subject_name, reportId, notes, status FROM mdt_bolos WHERE status = ? ORDER BY id DESC', { 'active' })
    local result = {}
    for _, v in pairs(BOLOS or {}) do
        result[#result + 1] = {
            id       = v.id,
            reportId = v.reportId and tostring(v.reportId) or 'N/A',
            name     = v.subject_name or ps.getPlayerNameByIdentifier(v.subject_id) or 'Unknown',
            type     = v.type,
            notes    = v.notes or '',
            status   = v.status,
        }
    end
    return result
end

ps.registerCallback(resourceName .. ':server:getActiveBolos', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return {} end
    return computeActiveBolos(src)
end)

local function computeActiveUnits()
    return Cache.getOrSet('dashboard:activeUnits', Config.CacheTTL and Config.CacheTTL.ActiveUnits or 10, function()
        return { count = ps.getJobTypeCount('leo') }
    end)
end

ps.registerCallback(resourceName .. ':server:getActiveUnits', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return { count = 0 } end
    return computeActiveUnits()
end)

local function sanitizeDispatch(call)
    if not call or type(call) ~= 'table' then return nil end
    local sanitized = {
        id          = call.id,
        message     = call.message     or call.dispatchMessage or '',
        code        = call.code        or call.dispatchCode    or '',
        street      = call.street      or '',
        priority    = call.priority    or 0,
        time        = call.time        or 0,
        gender      = call.gender,
        plate       = call.plate,
        color       = call.color,
        model       = call.model,
        weapon      = call.weapon,
        heading     = call.heading,
        speed       = call.speed,
        callSign    = call.callSign,
        description = call.description,
        camId       = call.camId,
        firstColor  = call.firstColor,
    }
    if call.coords then
        if type(call.coords) == 'vector3' or type(call.coords) == 'vector4' then
            sanitized.coords = { x = call.coords.x, y = call.coords.y, z = call.coords.z }
        elseif type(call.coords) == 'table' then
            sanitized.coords = { x = call.coords.x or call.coords[1], y = call.coords.y or call.coords[2], z = call.coords.z or call.coords[3] }
        end
    end
    sanitized.units = {}
    if call.units and type(call.units) == 'table' then
        for _, unit in pairs(call.units) do
            if type(unit) == 'table' then
                sanitized.units[#sanitized.units + 1] = {
                    citizenid = unit.citizenid,
                    charinfo  = unit.charinfo,
                    job       = unit.job,
                    metadata  = unit.metadata and { callsign = unit.metadata.callsign } or nil,
                }
            end
        end
    end
    if call.jobs and type(call.jobs) == 'table' then
        sanitized.jobs = {}
        for _, job in ipairs(call.jobs) do
            sanitized.jobs[#sanitized.jobs + 1] = job
        end
    end
    return sanitized
end

-- Latest open investigations for the dashboard.
local function computeOpenCases()
    local rows = MySQL.query.await([[
        SELECT id, case_number, title, status, priority, updated_at
        FROM mdt_cases
        WHERE status IN ('open', 'in_progress')
        ORDER BY updated_at DESC
        LIMIT 6
    ]])
    return rows or {}
end

-- Next few calendar entries (court/training/meetings) for the dashboard.
local function computeUpcomingHearings(src)
    local domain = (GetMdtDomain and GetMdtDomain(src)) or 'police'
    local rows = MySQL.query.await([[
        SELECT id, title, category, hearing_type, defendant_name, scheduled_at, location, status
        FROM mdt_court_hearings
        WHERE job_type = ?
          AND status IN ('scheduled', 'in_session')
          AND scheduled_at >= (NOW() - INTERVAL 1 HOUR)
        ORDER BY scheduled_at ASC
        LIMIT 6
    ]], { domain })
    return rows or {}
end

-- Globally dismissed calls (dispatcher action) — filtered out of every list.
-- Entries auto-expire so the table can't grow forever.
local DismissedDispatches = {}
local DISMISS_TTL = 2 * 60 * 60 -- seconds

local function pruneDismissed()
    local now = os.time()
    for id, at in pairs(DismissedDispatches) do
        if (now - at) > DISMISS_TTL then DismissedDispatches[id] = nil end
    end
end

local function filterDismissed(list)
    pruneDismissed()
    if not next(DismissedDispatches) then return list end
    local out = {}
    for _, call in ipairs(list or {}) do
        if not DismissedDispatches[tostring(call.id)] then
            out[#out + 1] = call
        end
    end
    return out
end

local function computeRecentDispatches(src)
    local dispatchResource = Config and Config.Dispatch and Config.Dispatch.Resource or 'ps-dispatch'
    local ok, recentDispatches = pcall(function()
        return exports[dispatchResource] and exports[dispatchResource]:GetDispatchCalls() or {}
    end)
    if not ok then return {} end
    recentDispatches = recentDispatches or {}

    recentDispatches = filterDismissed(recentDispatches)

    local dispatches = recentDispatches
    if Config and Config.Dispatch and Config.Dispatch.FilterByJob == true then
        local jobName = ps.getJobName(src)
        local jobType = ps.getJobType and ps.getJobType(src) or nil
        if jobName then
            local filtered = {}
            for _, call in ipairs(recentDispatches) do
                if not call.jobs or #call.jobs == 0 then
                    filtered[#filtered + 1] = call
                else
                    for _, job in ipairs(call.jobs) do
                        if job == jobName or job == jobType then
                            filtered[#filtered + 1] = call
                            break
                        end
                    end
                end
            end
            dispatches = filtered
        end
    end

    local result = {}
    for _, call in ipairs(dispatches) do
        local sanitized = sanitizeDispatch(call)
        if sanitized then result[#result + 1] = sanitized end
    end
    return result
end

ps.registerCallback(resourceName .. ':server:getRecentDispatches', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    if not CheckAuth(src) then return {} end
    return computeRecentDispatches(src)
end)

local function computeUsageMetrics()
    return Cache.getOrSet('dashboard:usageMetrics', Config.CacheTTL and Config.CacheTTL.UsageMetrics or 60, function()
        local function safeCount(query, params)
            local ok, result = pcall(MySQL.scalar.await, query, params or {})
            return ok and (tonumber(result) or 0) or 0
        end
        return {
            totals = {
                reports       = safeCount('SELECT COUNT(*) FROM mdt_reports'),
                arrests       = safeCount('SELECT COUNT(*) FROM mdt_arrests'),
                activeWarrants = safeCount('SELECT COUNT(*) FROM mdt_reports_warrants WHERE expirydate >= NOW()'),
            },
            windows = {
                reportsLast7   = safeCount('SELECT COUNT(*) FROM mdt_reports WHERE datecreated >= NOW() - INTERVAL 7 DAY'),
                reportsLast30  = safeCount('SELECT COUNT(*) FROM mdt_reports WHERE datecreated >= NOW() - INTERVAL 30 DAY'),
                arrestsLast7   = safeCount('SELECT COUNT(*) FROM mdt_arrests WHERE created_at >= NOW() - INTERVAL 7 DAY'),
                arrestsLast30  = safeCount('SELECT COUNT(*) FROM mdt_arrests WHERE created_at >= NOW() - INTERVAL 30 DAY'),
            },
        }
    end)
end

ps.registerCallback(resourceName .. ':server:getUsageMetrics', function(source)
    local src = source
    if not CheckAuth(src) then return {} end
    return computeUsageMetrics()
end)

-- ============================================================================
--  Aggregate: one round-trip for the whole dashboard.
--  The frontend previously fired ~9 separate NUI callbacks on open (one per
--  widget). This bundles them into a single callback so opening the MDT does
--  one server round-trip + one cb() serialisation instead of nine, which is
--  the bulk of the on-open client spike.
-- ============================================================================
ps.registerCallback(resourceName .. ':server:getDashboard', function(source)
    local src = source
    if not CheckAuth(src) then return {} end
    return {
        jobData          = computeJobData(src),
        upcomingHearings = computeUpcomingHearings(src),
        openCases        = computeOpenCases(),
        reportStatistics = computeReportStatistics(),
        timeStatistics   = computeTimeStatistics(src),
        activeWarrants   = (GetActiveWarrantsData and GetActiveWarrantsData(src)) or {},
        bulletins        = computeBulletins(),
        activeBolos      = computeActiveBolos(src),
        activeUnits      = computeActiveUnits(),
        recentDispatches = computeRecentDispatches(src),
        usageMetrics     = computeUsageMetrics(),
    }
end)
-- Dispatcher: globally dismiss a call — it disappears from every MDT.
ps.registerCallback(resourceName .. ':server:dismissDispatch', function(source, data)
    local src = source
    if not CheckAuth(src) then return { success = false } end
    if not CheckPermission(src, 'dispatch_assign') then
        return { success = false, error = 'No permission' }
    end
    data = data or {}
    local id = data.dispatch_id and tostring(data.dispatch_id) or nil
    if not id then return { success = false, error = 'Invalid request' } end

    DismissedDispatches[id] = os.time()
    if ps.auditLog then
        ps.auditLog(src, 'dispatch_dismiss', 'dispatch', 0, { dispatch = id })
    end
    -- Nudge every open MDT to refresh its (now filtered) dispatch list.
    TriggerClientEvent(resourceName .. ':client:dispatchDismissed', -1, id)
    return { success = true }
end)

-- ---------------------------------------------------------------------------
-- Dispatcher: assign or detach OTHER units to/from a dispatch call.
-- The actual attach runs on the TARGET client (same path as self-attach via
-- ps-dispatch), which also sets their waypoint and notifies them. This keeps
-- ps-dispatch's unit bookkeeping identical to a self-attach.
-- ---------------------------------------------------------------------------
ps.registerCallback(resourceName .. ':server:assignToDispatch', function(source, data)
    local src = source
    if not CheckAuth(src) then return { success = false } end
    if not CheckPermission(src, 'dispatch_assign') then
        return { success = false, error = 'No permission' }
    end

    data = data or {}
    local dispatchId = data.dispatch_id
    local action = data.action == 'detach' and 'detach' or 'attach'
    local citizenids = type(data.citizenids) == 'table' and data.citizenids or {}
    if not dispatchId or #citizenids == 0 then
        return { success = false, error = 'Invalid request' }
    end

    local okCore, QBCore = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if not okCore then QBCore = nil end

    local hit, miss = 0, 0
    for _, cid in ipairs(citizenids) do
        local targetSrc = nil
        if ps.getPlayerByIdentifier then
            local p = ps.getPlayerByIdentifier(cid)
            targetSrc = p and (p.PlayerData and p.PlayerData.source or p.source) or nil
        end
        if not targetSrc and QBCore and QBCore.Functions.GetPlayerByCitizenId then
            local p = QBCore.Functions.GetPlayerByCitizenId(cid)
            targetSrc = p and p.PlayerData and p.PlayerData.source or nil
        end
        if targetSrc then
            TriggerClientEvent(resourceName .. ':client:dispatchAssign', targetSrc, {
                id = dispatchId,
                action = action,
                coords = data.coords, -- {x, y} for waypoint (attach only)
            })
            hit = hit + 1
        else
            miss = miss + 1
        end
    end

    if ps.auditLog then
        ps.auditLog(src, 'dispatch_' .. action .. '_units', 'dispatch', 0,
            { dispatch = tostring(dispatchId), count = hit })
    end
    return { success = hit > 0, assigned = hit, offline = miss }
end)