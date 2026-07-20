local resourceName = tostring(GetCurrentResourceName())
local bodycamInstances = {}
local bodycamViewers = {}

-- Bodycam power state, keyed by citizenid rather than by session source so it survives a
-- reconnect within the same shift. A missing entry means "on": a bodycam is running
-- unless its officer deliberately switched it off.
local bodycamPower = {}

--- Is this officer's bodycam currently running?
local function isBodycamOn(citizenid)
    if not citizenid then return true end
    return bodycamPower[citizenid] ~= false
end

--- Read-only accessor for other modules (the map/tracking payload needs to know whether
--- an officer's bodycam is actually recording). The power table itself stays file-local.
---@param citizenid string
---@return boolean
function IsOfficerBodycamOn(citizenid)
    return isBodycamOn(citizenid)
end

local function getBodycamConfig()
    return Config and Config.Bodycam or {}
end

local function shouldUseQbCore()
    local cfg = getBodycamConfig()
    if cfg.DutyEventMode == 'pslib' then
        return false
    end
    return exports[cfg.DutyResource] ~= nil
end

local function getQbCoreObject()
    local cfg = getBodycamConfig()
    local resource = exports[cfg.DutyResource]
    if not resource then
        return nil
    end
    return resource:GetCoreObject()
end

local function getOnDutyOfficers()
    local officers = {}

    if shouldUseQbCore() then
        local QBCore = getQbCoreObject()
        if QBCore and QBCore.Functions and QBCore.Functions.GetQBPlayers then
            local players = QBCore.Functions.GetQBPlayers() or {}
            for _, player in pairs(players) do
                local data = player.PlayerData
                if data and data.job and data.job.onduty and IsPoliceJob(data.job.name, data.job.type) then
                    officers[#officers + 1] = player
                end
            end
        end
        return officers
    end

    if ps and ps.getAllPlayers then
        local players = ps.getAllPlayers() or {}
        for _, playerId in pairs(players) do
            if ps.getJobDuty and ps.getJobDuty(playerId) then
                local jobName = ps.getJobName and ps.getJobName(playerId) or nil
                local jobType = ps.getJobType and ps.getJobType(playerId) or nil
                if IsPoliceJob(jobName, jobType) then
                    local player = ps.getPlayer and ps.getPlayer(playerId) or nil
                    if player then
                        officers[#officers + 1] = player
                    end
                end
            end
        end
    end

    return officers
end

-- Get all bodycams for on-duty officers
-- Helper function to create bodycam for officer
local function createOfficerBodycam(playerId, playerData)
    local bodycamId = tostring(playerId)
    local officerName = playerData.charinfo.firstname .. ' ' .. playerData.charinfo.lastname

    bodycamInstances[bodycamId] = {
        id = bodycamId,
        officerName = officerName,
        callsign = (playerData.metadata and playerData.metadata.callsign) or 'Unknown',
        rank = (playerData.job and playerData.job.grade and playerData.job.grade.name) or 'Officer',
        playerId = playerId,
        citizenid = playerData.citizenid,
        createdAt = os.time()
    }

    ps.debug('Created bodycam for officer:', officerName, 'ID:', bodycamId)
end

-- Helper function to remove bodycam for officer
local function removeOfficerBodycam(playerId)
    local bodycamId = tostring(playerId)

    if bodycamInstances[bodycamId] then
        bodycamInstances[bodycamId] = nil
        ps.debug('Removed bodycam for officer going off duty:', playerId)
    end
end

-- Bodycam ids are the officer's server id as a STRING (see
-- createOfficerBodycam). Callers pass whatever their UI happened to hold —
-- the Bodycams tab sends the string, the dispatch map popup a number — and in
-- Lua a numeric key never matches a string one, so normalize every lookup.
local function normalizeBodycamId(id)
    if type(id) == 'table' then id = id.id or id.bodycamId end
    if id == nil or id == '' then return nil end
    return tostring(id)
end

-- The registry is filled lazily (by getBodycams, i.e. opening the Bodycams
-- tab) and on duty CHANGES. An officer already on duty when the viewer joined
-- — or when the resource restarted — therefore has no entry yet, and viewing
-- them failed with "Bodycam not found" until someone opened that tab once.
-- Rebuild on demand instead.
local function resolveBodycam(bodycamId)
    if not bodycamId then return nil end
    if bodycamInstances[bodycamId] then return bodycamInstances[bodycamId] end

    for _, player in pairs(getOnDutyOfficers() or {}) do
        local pd = player.PlayerData
        if pd and tostring(pd.source) == bodycamId then
            createOfficerBodycam(pd.source, pd)
            ps.debug('resolveBodycam: rebuilt missing instance for', bodycamId)
            return bodycamInstances[bodycamId]
        end
    end
    return nil
end

ps.registerCallback(resourceName .. ':server:getBodycams', function(source)
    local src = source
    ps.debug('getBodycams called by source:', src)

    if not CheckAuth(src) then
        ps.debug('getBodycams: CheckAuth failed for source:', src)
        return {}
    end

    ps.debug('getBodycams: CheckAuth passed for source:', src)
    local bodycams = {}

    local officers = getOnDutyOfficers()
    ps.debug('getBodycams: Found on-duty officers:', officers and #officers or 0)

    for _, player in pairs(officers or {}) do
        local playerData = player.PlayerData
        if playerData then
            local bodycamId = tostring(playerData.source)
            local officerName = playerData.charinfo.firstname .. ' ' .. playerData.charinfo.lastname

            if not bodycamInstances[bodycamId] then
                bodycamInstances[bodycamId] = {
                    id = bodycamId,
                    officerName = officerName,
                    callsign = playerData.metadata and playerData.metadata.callsign or 'Unknown',
                    rank = playerData.job.grade and playerData.job.grade.name or 'Officer',
                    playerId = playerData.source,
                    citizenid = playerData.citizenid,
                    createdAt = os.time()
                }
                ps.debug('Created bodycam on-demand for officer:', officerName, 'ID:', bodycamId)
            else
                local data = bodycamInstances[bodycamId]
                data.officerName = officerName
                data.callsign = playerData.metadata and playerData.metadata.callsign or 'Unknown'
                data.rank = playerData.job.grade and playerData.job.grade.name or 'Officer'
            end
        end
    end

    local instanceCount = 0
    for _ in pairs(bodycamInstances) do
        instanceCount = instanceCount + 1
    end
    ps.debug('getBodycams: Total bodycam instances before verification:', instanceCount)
    for bodycamId, _ in pairs(bodycamInstances) do
        ps.debug('getBodycams: Bodycam instance found:', bodycamId)
    end

    for bodycamId, data in pairs(bodycamInstances) do
        ps.debug('getBodycams: Verifying bodycam:', bodycamId, 'for player:', data.playerId)
        local isStillOnline = false

        local player = nil
        if shouldUseQbCore() then
            local QBCore = getQbCoreObject()
            if QBCore and QBCore.Functions and QBCore.Functions.GetPlayer then
                player = QBCore.Functions.GetPlayer(data.playerId)
            end
        elseif ps and ps.getPlayer then
            player = ps.getPlayer(data.playerId)
        end

        if player and player.PlayerData and player.PlayerData.job and player.PlayerData.job.onduty then
            isStillOnline = true
            ps.debug('getBodycams: Officer verified as online:', data.officerName)
        end

        ps.debug('getBodycams: Officer', data.officerName, 'isStillOnline:', isStillOnline)

        if isStillOnline then
            local viewerCount = 0
            if bodycamViewers[bodycamId] then
                for _ in pairs(bodycamViewers[bodycamId]) do
                    viewerCount = viewerCount + 1
                end
            end

            table.insert(bodycams, {
                id = bodycamId,
                officerName = data.officerName,
                callsign = data.callsign,
                rank = data.rank,
                citizenid = data.citizenid,
                -- The real state now, not a constant: a bodycam listed here belongs to an
                -- on-duty officer, but it may well be switched off.
                isOnline = isBodycamOn(data.citizenid),
                viewerCount = viewerCount,
            })
            ps.debug('getBodycams: Added bodycam to return list:', bodycamId, 'with', viewerCount, 'viewers')
        else
            -- Remove offline bodycam
            bodycamInstances[bodycamId] = nil
            ps.debug('getBodycams: Removed offline bodycam:', bodycamId)
        end
    end

    ps.debug('getBodycams: Returning', #bodycams, 'bodycams')
    return bodycams
end)

-- View a specific bodycam
ps.registerCallback(resourceName .. ':server:viewBodycam', function(source, bodycamId)
    local src = source
    if not CheckAuth(src) then
        return { success = false, error = "Unauthorized" }
    end

    bodycamId = normalizeBodycamId(bodycamId)
    local bodycamData = resolveBodycam(bodycamId)
    if not bodycamData then
        return { success = false, error = "Bodycam not found" }
    end

    -- A switched-off bodycam has nothing to show; say so instead of opening a
    -- live feed the officer believes is off. The toggle stays logged either
    -- way (see setBodycamPower) — this is only about what a viewer sees.
    if not isBodycamOn(bodycamData.citizenid) then
        return { success = false, error = "This officer's bodycam is switched off" }
    end

    local targetSource = bodycamData.playerId
    if not targetSource then
        return { success = false, error = "Invalid target source" }
    end

    local targetPlayer = GetPlayerName(targetSource)
    if not targetPlayer then
        return { success = false, error = "Officer is no longer online" }
    end

    local targetPed = GetPlayerPed(targetSource)
    if not targetPed or targetPed == 0 then
        return { success = false, error = "Unable to access officer's bodycam" }
    end

    local coords = GetEntityCoords(targetPed)
    local heading = GetEntityHeading(targetPed)

    -- Start bodycam view for the requesting player
    TriggerClientEvent(resourceName .. ':client:startCameraView', src, {
        coords = coords,
        rotation = vector3(0.0, 0.0, heading),
        networkId = nil, -- No entity to hide for bodycams
        isBodycam = true,
        targetSource = targetSource,
        officerName = bodycamData.officerName
    })

    -- Track this viewer
    if not bodycamViewers[bodycamId] then
        bodycamViewers[bodycamId] = {}
    end
    bodycamViewers[bodycamId][src] = {
        startTime = os.time()
    }
    ps.debug('Added viewer', src, 'to bodycam', bodycamId)

    return {
        success = true,
        camera = {
            id = bodycamId,
            label = bodycamData.officerName .. " Bodycam",
            coords = coords,
            rotation = vector3(0.0, 0.0, heading)
        }
    }
end)

-- Clean up bodycam when player disconnects
AddEventHandler('playerDropped', function(reason)
    local playerId = source
    local bodycamId = tostring(playerId)

    if bodycamInstances[bodycamId] then
        bodycamInstances[bodycamId] = nil
        ps.debug('Cleaned up bodycam instance for disconnected player:', playerId)
    end

    -- Clean up any viewer entries for this player
    for bcId, viewers in pairs(bodycamViewers) do
        if viewers and viewers[playerId] then
            viewers[playerId] = nil
            ps.debug('Removed viewer', playerId, 'from bodycam', bcId, 'due to disconnect')
        end
    end
end)

-- Handle bodycam view deactivation
RegisterNetEvent(resourceName .. ':server:deactivateBodycam', function(bodycamId)
    local playerId = source
    if not CheckAuth(playerId) then return end
    bodycamId = normalizeBodycamId(bodycamId)
    if not bodycamId then return end
    ps.debug('Deactivating bodycam for player:', playerId, 'Bodycam ID:', bodycamId)

    if bodycamViewers[bodycamId] then
        ps.debug('Found viewer table for bodycam:', bodycamId)
        if bodycamViewers[bodycamId][playerId] then
            local viewDuration = os.time() - bodycamViewers[bodycamId][playerId].startTime
            bodycamViewers[bodycamId][playerId] = nil
            ps.debug('Player', playerId, 'stopped viewing bodycam', bodycamId, 'after', viewDuration, 'seconds')

            -- Clean up empty viewer table
            if next(bodycamViewers[bodycamId]) == nil then
                bodycamViewers[bodycamId] = nil
                ps.debug('Cleaned up empty viewer table for bodycam:', bodycamId)
            end
        else
            ps.debug('Player', playerId, 'was not found in viewers for bodycam:', bodycamId)
        end
    else
        ps.debug('No viewer table found for bodycam:', bodycamId)
    end
end)

-- Listen for QBCore duty status changes
local function handleDutyChange(playerId, job, onDuty, employeeData)
    local jobName = job and job.name or employeeData and employeeData.job or nil
    local jobType = job and job.type or employeeData and employeeData.jobType or nil
    if not IsPoliceJob(jobName, jobType) then
        return
    end

    if onDuty then
        local playerData = nil
        if employeeData and employeeData.name then
            playerData = {
                charinfo = {
                    firstname = employeeData.firstname or '',
                    lastname = employeeData.lastname or '',
                },
                metadata = { callsign = employeeData.callsign },
                job = {
                    grade = { name = employeeData.rank or 'Officer' },
                }
            }
            if employeeData.name then
                local nameParts = {}
                for part in tostring(employeeData.name):gmatch('%S+') do
                    nameParts[#nameParts + 1] = part
                end
                playerData.charinfo.firstname = nameParts[1] or employeeData.name
                playerData.charinfo.lastname = nameParts[#nameParts] or ''
            end
            createOfficerBodycam(playerId, playerData)
            ps.debug('Created bodycam via duty event for officer:', employeeData.name, 'ID:', tostring(playerId))
            return
        end

        if shouldUseQbCore() then
            local QBCore = getQbCoreObject()
            local Player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer and QBCore.Functions.GetPlayer(playerId) or nil
            if Player then
                createOfficerBodycam(playerId, Player.PlayerData)
                return
            end
        elseif ps and ps.getPlayer then
            local player = ps.getPlayer(playerId)
            if player and player.PlayerData then
                createOfficerBodycam(playerId, player.PlayerData)
                return
            end
        end
    else
        removeOfficerBodycam(playerId)
    end
end

local function registerDutyEvents()
    local cfg = getBodycamConfig()

    if cfg.DutyEventMode == 'qbcore' then
        RegisterNetEvent(cfg.DutyEvent, function(source, job)
            local src = source
            if not src or not job then return end
            handleDutyChange(src, job, job.onduty == true, nil)
        end)
    elseif cfg.DutyEventMode == 'pslib' then
        RegisterNetEvent(cfg.DutyEvent, function(playerId, jobName, onDuty, employeeData)
            if not playerId then return end
            handleDutyChange(playerId, { name = jobName }, onDuty == true, employeeData)
        end)
    end

    if cfg.MultiJobDutyEvent and GetResourceState(cfg.MultiJobResource) == 'started' then
        RegisterNetEvent(cfg.MultiJobDutyEvent, function(playerId, jobName, onDuty, employeeData)
            if not playerId then return end
            handleDutyChange(playerId, { name = jobName }, onDuty == true, employeeData)
        end)
    end
end

-- Initialize bodycams for officers already on duty when resource starts
CreateThread(function()
    Wait(5000)

    local cfg = getBodycamConfig()
    local multiJobAvailable = GetResourceState(cfg.MultiJobResource) == 'started'
    if multiJobAvailable and exports[cfg.MultiJobResource] then
        local police = exports[cfg.MultiJobResource]:getEmployees('police')
        if police then
            for _, officer in pairs(police) do
                if officer.citizenid then
                    if shouldUseQbCore() then
                        local QBCore = getQbCoreObject()
                        local Player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayerByCitizenId and QBCore.Functions.GetPlayerByCitizenId(officer.citizenid) or nil
                        if Player and Player.PlayerData.job and Player.PlayerData.job.onduty then
                            createOfficerBodycam(Player.PlayerData.source, Player.PlayerData)
                        end
                    elseif ps and ps.getPlayerByIdentifier then
                        -- getEmployees() returns offline staff too; resolving an
                        -- offline citizenid can throw inside the framework bridge
                        -- (nil player index), so guard it.
                        local okp, player = pcall(ps.getPlayerByIdentifier, officer.citizenid)
                        if okp and player and player.PlayerData and player.PlayerData.job and player.PlayerData.job.onduty then
                            createOfficerBodycam(player.PlayerData.source, player.PlayerData)
                        end
                    end
                end
            end
        end
    elseif shouldUseQbCore() then
        local QBCore = getQbCoreObject()
        local players = QBCore and QBCore.Functions and QBCore.Functions.GetQBPlayers and QBCore.Functions.GetQBPlayers() or {}

        for _, player in pairs(players or {}) do
            local playerData = player.PlayerData
            if playerData and playerData.job and playerData.job.onduty and IsPoliceJob(playerData.job.name, playerData.job.type) then
                createOfficerBodycam(player.PlayerData.source, playerData)
            end
        end
    else
        local officers = getOnDutyOfficers()
        for _, player in pairs(officers or {}) do
            if player and player.PlayerData then
                createOfficerBodycam(player.PlayerData.source, player.PlayerData)
            end
        end
    end

    local instanceCount = 0
    for _ in pairs(bodycamInstances) do
        instanceCount = instanceCount + 1
    end
    -- do not spell this with a Z
    ps.debug('Initialised ' .. instanceCount .. ' bodycams')
end)

registerDutyEvents()
-- ── Officer-controlled power ─────────────────────────────────────────────────
-- An officer may switch their own bodycam off. That is not blocked: it is recorded,
-- and supervisors can read the record. Nobody can toggle anyone else's — the state is
-- always keyed to the caller's own citizenid, never to an id from the payload.

local function bodycamCfg()
    return (Config and Config.Bodycam) or {}
end

---@param reason string 'manual' | 'duty_on' | 'duty_off'
---@param desired boolean|nil nil = flip the current state
local function setBodycamPower(src, desired, reason)
    local citizenid = ps.getIdentifier(src)
    if not citizenid then return nil end

    local current = isBodycamOn(citizenid)
    local target = desired
    if target == nil then target = not current end
    if target == current then return current end

    bodycamPower[citizenid] = target

    -- The audit log is the record. It already carries actor, name, timestamp and a JSON
    -- details blob, so a dedicated bodycam table would only duplicate it — the callsign
    -- and the reason ride along in `details`.
    local callsign = ps.getMetadata and ps.getMetadata(src, 'callsign') or nil

    -- action_label is what the roster's activity timeline prints when present, so the
    -- entry reads as a sentence instead of "bodycam off".
    local why = ({
        manual   = 'manually',
        duty_on  = 'on going on duty',
        duty_off = 'on going off duty',
    })[reason or 'manual'] or 'manually'

    if ps.auditLog then
        -- Written on its own thread: ps.auditLog ends in a blocking MySQL insert, and
        -- holding the toggle's reply for it stalls the NUI callback queue behind it.
        -- Nothing here depends on the write finishing.
        local label = (target and 'Bodycam activated ' or 'Bodycam deactivated ') .. why
        CreateThread(function()
            pcall(ps.auditLog, src, target and 'bodycam_on' or 'bodycam_off', 'bodycam', citizenid, {
                reason = reason or 'manual',
                callsign = callsign,
                action_label = label,
            })
        end)
    end

    -- Anyone currently watching this feed loses it. Targeted at those viewers only —
    -- a broadcast to -1 made every client in the server reload their bodycam list.
    if not target then
        local bodycamId = tostring(src)
        for viewerId in pairs(bodycamViewers[bodycamId] or {}) do
            TriggerClientEvent(resourceName .. ':client:bodycamPowerOff', viewerId, { id = bodycamId })
        end
    end

    return target
end

-- Toggle own bodycam. No target parameter by design.
ps.registerCallback(resourceName .. ':server:toggleBodycam', function(source, payload)
    if bodycamCfg().Enabled == false then return { success = false, message = 'Bodycams are disabled' } end
    if not CheckAuth(source) then return { success = false, message = 'Unauthorized' } end

    payload = payload or {}
    local desired = nil
    if type(payload.on) == 'boolean' then desired = payload.on end

    local state = setBodycamPower(source, desired, 'manual')
    if state == nil then return { success = false, message = 'Could not resolve officer' } end
    return { success = true, isOnline = state }
end)

-- Read own current state (for the toggle's initial rendering).
ps.registerCallback(resourceName .. ':server:getMyBodycam', function(source)
    if not CheckAuth(source) then return { success = false } end
    local citizenid = ps.getIdentifier(source)
    return { success = true, isOnline = isBodycamOn(citizenid), citizenid = citizenid }
end)

-- Automatic switching with duty, driven by the officer's own preference. The client
-- decides whether to call this (the preference lives in the NUI), the server stays the
-- authority on the state itself.
RegisterNetEvent(resourceName .. ':server:bodycamDutyChange', function(onDuty)
    local src = source
    if bodycamCfg().Enabled == false then return end
    if not CheckAuth(src) then return end
    setBodycamPower(src, onDuty == true, onDuty and 'duty_on' or 'duty_off')
end)

-- Free the state when the player disconnects so the table doesn't grow unbounded. The
-- log keeps the history; this is only the live flag.
AddEventHandler('playerDropped', function()
    -- The player is already disconnected here, so resolving their identifier can fail
    -- depending on the framework's teardown order.
    local src = source
    local ok, citizenid = pcall(function()
        return ps.getIdentifier and ps.getIdentifier(src) or nil
    end)
    if ok and citizenid then bodycamPower[citizenid] = nil end
end)