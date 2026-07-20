local resourceName = tostring(GetCurrentResourceName())

local function _isDojJob(jobName)
    if not jobName or not Config.DojJobs then return false end
    for _, name in ipairs(Config.DojJobs) do
        if name == jobName then return true end
    end
    return false
end

-- Match the server's IsEmsJob: an EMS job is recognised by its TYPE
-- (Config.MedicalJobType) OR its NAME (Config.MedicalJobs). The client used to
-- check the type only, so on servers whose EMS job type isn't literally "ems"
-- the NUI received jobType 'leo' for medics (breaking EMS-specific UI/text).
local function _isEmsJob(jobName, jobType)
    if jobType and Config.MedicalJobType and jobType == Config.MedicalJobType then return true end
    if jobName and Config.MedicalJobs then
        for _, name in ipairs(Config.MedicalJobs) do
            if name == jobName then return true end
        end
    end
    return false
end

RegisterNUICallback('checkAuth', function(_, cb)
    local jobType = ps.getJobType()
    local jobName = ps.getJob() and ps.getJob().name or ''
    local isDoj = _isDojJob(jobName) or (Config.DojJobType and jobType == Config.DojJobType)
    local isAuthorized = jobType == Config.PoliceJobType or _isEmsJob(jobName, jobType) or isDoj
    local mdtJobType = isDoj and 'doj' or (_isEmsJob(jobName, jobType) and 'ems' or 'leo')
    local onDuty = ps.getJobDuty() or false
    local playerData = ps.getPlayerData()

    local isCivilian = false
    if not isAuthorized and Config.CivilianAccess and Config.CivilianAccess.enabled then
        isCivilian = true
    end

    cb({
        authorized = isCivilian or (isAuthorized and (isDoj or onDuty)),
        playerData = type(playerData) == 'table' and {
            citizenid = playerData.citizenid,
            job = playerData.job,
            charinfo = playerData.charinfo,
        } or nil,
        isLEO = isAuthorized,
        onDuty = isCivilian or isDoj or onDuty or false,
        jobType = isCivilian and 'civilian' or mdtJobType,
        isCivilian = isCivilian,
    })
end)

-- Separate NUI callback for fetching permissions (non-blocking)
RegisterNUICallback('getMyPermissions', function(_, cb)
    if not MDTOpen then
        cb({ permissions = {}, isBoss = false })
        return
    end

    local result = ps.callback(resourceName .. ':server:getMyPermissions')
    cb(result or { permissions = {}, isBoss = false })
end)

function NUIUpdateAuth()
    local jobType = ps.getJobType()
    local jobName = ps.getJob() and ps.getJob().name or ''
    local isDoj = _isDojJob(jobName) or (Config.DojJobType and jobType == Config.DojJobType)
    local isAuthorized = jobType == Config.PoliceJobType or _isEmsJob(jobName, jobType) or isDoj
    local mdtJobType = isDoj and 'doj' or (_isEmsJob(jobName, jobType) and 'ems' or 'leo')
    local playerData = ps.getPlayerData()
    SendNUI('updateAuth', {
        authorized = isAuthorized and (ps.getJobDuty() or false),
        playerData = type(playerData) == 'table' and {
            citizenid = playerData.citizenid,
            job = playerData.job,
            charinfo = playerData.charinfo,
            metadata = type(playerData.metadata) == 'table' and {
                callsign = playerData.metadata.callsign or '',
            } or nil,
        } or nil,
        isLEO = isAuthorized,
        onDuty = ps.getJobDuty() or false,
        jobType = mdtJobType,
    })
end

RegisterNUICallback('closeUI', function(_, cb)
    -- ps.debug('MDT closeUI triggered via NUI callback')
    PlayMDTSound('close')
    cb({})
    CloseMDT()
end)

RegisterNUICallback('signOut', function(_, cb)
    -- ps.debug('MDT signOut triggered via NUI callback')
    PlayMDTSound('close')
    cb({})
    CloseMDT()
    ps.notify('Signed out of MDT', 'success')
end)

RegisterNUICallback('toggleDuty', function(_, cb)
    -- ps.debug('MDT toggleDuty triggered via NUI callback')
    PlayMDTSound('buttonClick')
    cb({})
    TriggerServerEvent('ps_lib:server:toggleDuty')
end)

-- DASHBOARD (aggregate) -----------------------------------
-- One round-trip that returns every dashboard widget's data at once, so
-- opening the MDT fires a single NUI callback instead of ~9.
RegisterNUICallback('getDashboard', function(_, cb)
    if not MDTOpen then
        cb({})
        return
    end
    local data = ps.callback(resourceName .. ':server:getDashboard')
    cb(data or {})
end)

-- JOB DATA -----------------------------------------------
RegisterNUICallback('getJobData', function(_, cb)
    local jobData = ps.callback(resourceName .. ':server:getJobData')
     ps.debug('[getJobData] Triggered NUI callback on client', jobData)
    cb(jobData or {})
end)

-- REPORT STATISTICS ---------------------------------------
RegisterNUICallback('getReportStatistics', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end
    local reportStats = ps.callback(resourceName .. ':server:getReportStatistics')
    cb(reportStats)
end)



-- TIME STATISTICS -----------------------------------------
RegisterNUICallback('getTimeStatistics', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end
    local timeStats = ps.callback(resourceName .. ':server:getTimeStatistics')
    -- ps.debug('[getTimeStatistics] Triggered NUI callback on client', timeStats)
    cb(timeStats)
end)


-- ACTIVE WARRANTS -----------------------------------------
RegisterNUICallback('getActiveWarrants', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end
    local activeWarrants = ps.callback(resourceName .. ':server:getActiveWarrants')

    -- ps.debug('[getActiveWarrants] Triggered NUI callback on client',activeWarrants)
    cb(activeWarrants)
end)

-- View Warrant
RegisterNUICallback('viewWarrant', function(data, cb)
    cb({})
    TriggerServerEvent(resourceName..':server:viewWarrant', data.warrantId)
    -- ps.debug(('Viewing Warrant ID: %s'):format(data.warrantId))
end)



-- BULLETIN BOARD ----------------------------------------
RegisterNUICallback('getBulletins', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end
    local bulletins = ps.callback(resourceName .. ':server:getBulletins')
     ps.debug('[getBulletins] Triggered NUI callback on client',bulletins )
    cb(bulletins)
end)


RegisterNUICallback('createBulletin', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    if not data or not data.content or data.content == '' then
        cb({ success = false, message = 'Content is required' })
        return
    end
    local result = ps.callback(resourceName .. ':server:createBulletin', data)
    cb(result or { success = false })
end)

RegisterNUICallback('deleteBulletin', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    if not data or not data.id then
        cb({ success = false, message = 'Missing bulletin ID' })
        return
    end
    local result = ps.callback(resourceName .. ':server:deleteBulletin', data)
    cb(result or { success = false })
end)

RegisterNUICallback('getBulletinCategories', function(_, cb)
    local result = ps.callback(resourceName .. ':server:getBulletinCategories', false)
    cb(result or {})
end)

RegisterNUICallback('saveBulletinCategories', function(data, cb)
    if not data or not data.categories then
        cb({ success = false, message = 'Invalid data' })
        return
    end
 
    for _, cat in ipairs(data.categories) do
        if type(cat.value) ~= 'string' or type(cat.label) ~= 'string' or type(cat.icon) ~= 'string' then
            cb({ success = false, message = 'Malformed category entry' })
            return
        end
        if #cat.label > 32 or #cat.icon > 48 then
            cb({ success = false, message = 'Category label or icon name too long' })
            return
        end
    end
 
    local result = ps.callback('mdt:server:saveBulletinCategories', false, data.categories)
    cb(result or { success = false, message = 'Server error' })
end)

-- RECENT REPORTS -------------------------------------

RegisterNUICallback('getRecentReports', function(data, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end
    local page = data and data.page or nil
    local limit = data and data.limit or nil
    local recentReports = ps.callback(resourceName .. ':server:getRecentReports', page, limit)
    cb(recentReports)
end)

-- ACTIVE BOLOS ---------------------------------------

RegisterNUICallback('getActiveBolos', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end
    local activeBolos = ps.callback(resourceName .. ':server:getActiveBolos')
    cb(activeBolos)
end)

-- View Report
RegisterNUICallback('viewReport', function(data, cb)
    cb({})
    TriggerServerEvent(resourceName..':server:viewReport', data.reportId)
    -- ps.debug(('Viewing Report ID: %s'):format(data.reportId))
end)

-- ACTIVE UNITS ---------------------------------------

RegisterNUICallback('getActiveUnits', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end
    local activeUnits = ps.callback(resourceName .. ':server:getActiveUnits')
    -- ps.debug('[getActiveUnits] Active Units Data:', activeUnits)
    cb(activeUnits)
end)


-- DISPATCH -------------------------------------------

-- Build player data for attaching to dispatch
local function buildPlayerData()
    return {
        charinfo = {
            firstname = ps.getCharInfo('firstname'),
            lastname = ps.getCharInfo('lastname'),
        },
        metadata = {
            callsign = ps.getMetadata('callsign'),
        },
        citizenid = ps.getIdentifier(),
        job = {
            type = ps.getJobData('type'),
            name = ps.getJobData('name'),
            label = ps.getJobData('label'),
        },
    }
end

RegisterNUICallback('getRecentDispatches', function(_, cb)
    local dispatches = GetRecentDispatch()
    cb(dispatches or {})
end)

-- ─── Provider-aware attach / detach ─────────────────────────────────────────
-- ps, qs and cd each expose their own attach/detach path. Route to the right
-- one based on Config.Dispatch.Provider so the MDT's assign flow is identical
-- regardless of which dispatch resource the server runs. Detection is silent
-- client-side; the server logs a one-time warning if none is found.
local function dispatchProvider()
    local p = (Config and Config.Dispatch and Config.Dispatch.Provider) or 'auto'
    local resByProvider = { ps = 'ps-dispatch', qs = 'qs-dispatch', cd = 'cd_dispatch' }

    if (p == 'ps' or p == 'qs' or p == 'cd') and GetResourceState(resByProvider[p]) == 'started' then
        return p
    end
    if GetResourceState('ps-dispatch') == 'started' then return 'ps' end
    if GetResourceState('qs-dispatch') == 'started' then return 'qs' end
    if GetResourceState('cd_dispatch') == 'started' then return 'cd' end
    return nil
end

local function providerAttach(dispatchId)
    -- ps-dispatch compares call ids with strict equality against its NUMERIC
    -- ids. Ids that travelled through the MDT server arrive as strings
    -- (assignToDispatch tostrings them), so a dispatcher-driven attach/detach
    -- on provider calls silently matched nothing — the unit list never
    -- updated, leaving "ghost" units on calls. Normalize once here; manual
    -- 'mdt-…' ids never reach a provider.
    dispatchId = tonumber(dispatchId) or dispatchId
    local p = dispatchProvider()
    if p == 'qs' then
        TriggerServerEvent('qs-dispatch:server:attachUnit', dispatchId)
    elseif p == 'cd' then
        TriggerServerEvent('cd_dispatch:server:attach', dispatchId)
    elseif p == 'ps' then
        TriggerServerEvent('ps-dispatch:server:attach', dispatchId, buildPlayerData())
    end
    -- Provider bookkeeping changed behind the MDT server's back — nudge it to
    -- drop its dispatch-list cache so the next refresh shows current units.
    TriggerServerEvent(resourceName .. ':server:touchDispatchCache')
end

local function providerDetach(dispatchId)
    -- Same numeric normalization as providerAttach — a string id would make
    -- the provider's strict-equality lookup miss and the unit would stay
    -- attached forever (the "ghost units" symptom).
    dispatchId = tonumber(dispatchId) or dispatchId
    local p = dispatchProvider()
    if p == 'qs' then
        TriggerServerEvent('qs-dispatch:server:detachUnit', dispatchId)
    elseif p == 'cd' then
        TriggerServerEvent('cd_dispatch:server:detach', dispatchId)
    elseif p == 'ps' then
        TriggerServerEvent('ps-dispatch:server:detach', dispatchId, buildPlayerData())
    end
    -- Provider bookkeeping changed behind the MDT server's back — nudge it to
    -- drop its dispatch-list cache so the next refresh shows current units.
    TriggerServerEvent(resourceName .. ':server:touchDispatchCache')
end

-- Real-time dispatch listeners — one per supported provider. Whichever
-- resource is running fires its event; the others simply never trigger.
RegisterNetEvent('ps-dispatch:client:notify', function(data)
    if not MDTOpen or not data then return end
    SendNUI('updateRecentDispatches', GetRecentDispatch() or {})
end)
RegisterNetEvent('qs-dispatch:client:notify', function()
    if not MDTOpen then return end
    SendNUI('updateRecentDispatches', GetRecentDispatch() or {})
end)
RegisterNetEvent('cd_dispatch:client:notify', function()
    if not MDTOpen then return end
    SendNUI('updateRecentDispatches', GetRecentDispatch() or {})
end)

RegisterNUICallback('getUsageMetrics', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end

    local result = ps.callback(resourceName .. ':server:getUsageMetrics')
    cb(result or {})
end)

RegisterNUICallback("attachToDispatch", function(data, cb)
    if not MDTOpen then cb({}) return end
    -- data may be a bare id (provider calls) or { id, manual } for MDT calls.
    local id = type(data) == 'table' and data.id or data
    local isManual = type(data) == 'table' and data.manual or false
    if isManual then
        ps.callback(resourceName .. ':server:selfDispatchAttach', { dispatch_id = id, action = 'attach' })
    else
        providerAttach(id)
    end
    if AutoStatusClientEngage then AutoStatusClientEngage(id) end

    -- Self-attach: set the waypoint like a dispatcher assign would (user
    -- preference, Settings > Dispatch > "Automatic Waypoint"). No notify on
    -- purpose — the officer is literally looking at the call on screen.
    -- Resolved from the ONE list fetch this callback does anyway for the NUI
    -- response — no extra round-trip (see coalescing note on GetRecentDispatch).
    local list = GetRecentDispatch() or {}
    if not MdtPref or MdtPref('autoWaypoint', true) ~= false then
        for _, d in ipairs(list) do
            if tostring(d.id) == tostring(id) then
                local c = d.coords
                local x = c and (tonumber(c.x) or tonumber(c[1]))
                local y = c and (tonumber(c.y) or tonumber(c[2]))
                if x and y then SetNewWaypoint(x, y) end
                break
            end
        end
    end
    cb(list)
end)

RegisterNUICallback("detachFromDispatch", function(data, cb)
    if not MDTOpen then cb({}) return end
    local id = type(data) == 'table' and data.id or data
    local isManual = type(data) == 'table' and data.manual or false
    if isManual then
        ps.callback(resourceName .. ':server:selfDispatchAttach', { dispatch_id = id, action = 'detach' })
    else
        providerDetach(id)
        Wait(100) -- give non-1of1 servers time to update the server-side table before the cb
    end
    if AutoStatusClientDisengage then AutoStatusClientDisengage(id) end
    cb(GetRecentDispatch())
end)

RegisterNUICallback("routeToDispatch", function(data, cb)
    local coords = data.coords or data.origin
    if not coords then
        cb('ok')
        ps.notify('No location data for this dispatch', 'error')
        return
    end
    local x = tonumber(coords.x) or tonumber(coords[1])
    local y = tonumber(coords.y) or tonumber(coords[2])
    if not x or not y then
        cb('ok')
        ps.notify('Invalid location data', 'error')
        return
    end
    SetNewWaypoint(x, y)
    cb('ok')
    ps.notify('Set Route to Dispatch Location', 'success')
end)
-- ---------------------------------------------------------------------------
-- Dispatcher assignment (runs on the ASSIGNED player's client).
-- Attaching through the target client mirrors the normal self-attach flow in
-- ps-dispatch exactly, and lets us set their waypoint + notify locally.
-- ---------------------------------------------------------------------------
RegisterNetEvent(resourceName .. ':client:dispatchAssign', function(data)
    data = data or {}
    if not data.id then return end

    if data.action == 'detach' then
        if not data.manual then providerDetach(data.id) end
        if AutoStatusClientDisengage then AutoStatusClientDisengage(data.id) end
        return
    end

    if not data.manual then providerAttach(data.id) end
    if AutoStatusClientEngage then AutoStatusClientEngage(data.id, data.coords) end

    -- Waypoint + notify are both user preferences (Settings > Dispatch),
    -- mirrored from the NUI via preferences.lua; defaults keep both on.
    local wantWaypoint = not MdtPref or MdtPref('autoWaypoint', true) ~= false
    local waypointSet = false
    local c = data.coords
    if wantWaypoint and c then
        local x = tonumber(c.x) or tonumber(c[1])
        local y = tonumber(c.y) or tonumber(c[2])
        if x and y then
            SetNewWaypoint(x, y)
            waypointSet = true
        end
    end

    -- The targeted alert card (sent server-side via ps-dispatch) already
    -- carries code, note and location — a second text notify would be noise.
    if data.alertSent then return end

    if MdtPref and MdtPref('assignmentNotifications', true) == false then return end

    -- 10-code for the notify comes resolved from the server (both provider
    -- and MDT-created calls). Never look it up here: a blocking
    -- GetRecentDispatch inside this handler can race the NUI's own list
    -- refresh through ps_lib's name-keyed callbacks (10s timeout).
    local code = type(data.code) == 'string' and data.code ~= '' and data.code or nil
    local what = code and ('Dispatch assigned you: %s'):format(code) or 'Dispatch assigned you to a call'
    if waypointSet then what = what .. ' — waypoint set' end

    local note = type(data.note) == 'string' and data.note ~= '' and data.note or nil
    if note then
        ps.notify(('%s. Note: %s'):format(what, note), 'success')
    else
        ps.notify(what, 'success')
    end
end)

-- A note was added/edited/removed — refresh the MDT dispatch list so the note
-- travels with the call everywhere it's shown.
RegisterNetEvent(resourceName .. ':client:dispatchNoteChanged', function(_)
    if not MDTOpen then return end
    SendNUI('updateRecentDispatches', GetRecentDispatch() or {})
end)

-- You're already on a call and dispatch changed its note.
RegisterNetEvent(resourceName .. ':client:dispatchNoteNotify', function(data)
    data = data or {}
    local text = type(data.text) == 'string' and data.text or ''
    ps.notify('Dispatch updated the note on your call: ' .. text, 'inform')
end)

-- Dispatcher-side NUI bridge: assign/detach a set of units to a call.
RegisterNUICallback('assignToDispatch', function(data, cb)
    if not MDTOpen then cb({ success = false, error = 'MDT is not open' }) return end
    local result = ps.callback(resourceName .. ':server:assignToDispatch', data or {})
    cb(result or { success = false })
end)

-- A dispatcher dismissed a call globally — refresh our MDT's dispatch list
-- (the server already filters the dismissed id out of every response).
RegisterNetEvent(resourceName .. ':client:dispatchDismissed', function(_)
    if not MDTOpen then return end
    SendNUI('updateRecentDispatches', GetRecentDispatch() or {})
end)

RegisterNUICallback('dismissDispatch', function(data, cb)
    if not MDTOpen then cb({ success = false, error = 'MDT is not open' }) return end
    local result = ps.callback(resourceName .. ':server:dismissDispatch', data or {})
    cb(result or { success = false })
end)

RegisterNUICallback('setDispatchNote', function(data, cb)
    if not MDTOpen then cb({ success = false, error = 'MDT is not open' }) return end
    local result = ps.callback(resourceName .. ':server:setDispatchNote', data or {})
    cb(result or { success = false })
end)

RegisterNUICallback('deleteDispatchNote', function(data, cb)
    if not MDTOpen then cb({ success = false, error = 'MDT is not open' }) return end
    local result = ps.callback(resourceName .. ':server:deleteDispatchNote', data or {})
    cb(result or { success = false })
end)

-- Create Call modal: return the configured 10-codes.
RegisterNUICallback('getCallCodes', function(_, cb)
    cb((Config and Config.DispatchCodes) or {})
end)

-- Create Call modal: resolve a picked map coordinate to "Street, Zone".
RegisterNUICallback('resolveDispatchStreet', function(data, cb)
    data = data or {}
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z) or 0.0
    if not x or not y then cb({ street = '' }) return end
    local zone = GetLabelText(GetNameOfZone(x + 0.0, y + 0.0, z + 0.0))
    local hash = GetStreetNameAtCoord(x + 0.0, y + 0.0, z + 0.0)
    local street = GetStreetNameFromHashKey(hash)
    local out = street or ''
    if zone and zone ~= '' then out = (out ~= '' and (out .. ', ') or '') .. zone end
    cb({ street = out })
end)

RegisterNUICallback('createManualDispatch', function(data, cb)
    if not MDTOpen then cb({ success = false, error = 'MDT is not open' }) return end
    local result = ps.callback(resourceName .. ':server:createManualDispatch', data or {})
    cb(result or { success = false })
end)