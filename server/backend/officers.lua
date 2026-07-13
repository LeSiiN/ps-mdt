local resourceName = tostring(GetCurrentResourceName())
local ok, QBCore = pcall(function() return exports['qb-core']:GetCoreObject() end)
if not ok then QBCore = nil end
 
-- Get player source ID by citizenId
ps.registerCallback(resourceName .. ':server:GetPlayerSourceId', function(source, targetCitizenId)
    if not targetCitizenId then return nil end
    local targetPlayer = ps.getPlayerByIdentifier(targetCitizenId)
    if not targetPlayer then
        ps.notify(source, 'Citizen seems asleep / missing', 'error')
        return nil
    end
    return targetPlayer.source or targetPlayer.PlayerData.source
end)
 
-- Set Callsign
ps.registerCallback(resourceName .. ':server:setCallsign', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    payload = payload or {}
    local cid = payload.citizenid or payload.cid
    local newCallsign = payload.callsign or payload.newcallsign
 
    if not cid or not newCallsign then
        return { success = false, message = 'Missing citizen ID or callsign' }
    end
    if not QBCore then return { success = false, message = 'Core framework not available' } end

    newCallsign = tostring(newCallsign)

    local valid, why = ValidateCallsignPick(src, newCallsign, cid)
    if not valid then
        return { success = false, message = why }
    end

    local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
    if Player then
        Player.Functions.SetMetaData('callsign', newCallsign)
        TriggerClientEvent(resourceName .. ':client:updateCallsign', Player.PlayerData.source, newCallsign)
 
        MySQL.update.await('UPDATE mdt_profiles SET callsign = ? WHERE citizenid = ?', { newCallsign, cid })
 
        if ps.auditLog then
            ps.auditLog(src, 'callsign_changed', 'officer', cid, { callsign = newCallsign })
        end
 
        return { success = true, message = 'Callsign updated to ' .. newCallsign }
    end
    return { success = false, message = 'Player must be online to update callsign' }
end)
 
--- Everything the callsign picker needs, in one round-trip: the range, who holds
--- what, and what is reserved. The taken list is one query rather than one per box.
ps.registerCallback(resourceName .. ':server:getCallsignAvailability', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false } end

    local cfg, problem = CallsignConfigForPlayer(src)
    if not cfg then
        -- An unconfigured job is a server-owner mistake, not an officer's. Say what's
        -- wrong rather than showing an empty grid nobody can explain.
        ps.warn('[callsigns] ' .. tostring(problem))
        return { success = false, error = problem }
    end

    -- Who currently holds a callsign. Names come along so the picker can show whose
    -- box it is instead of just "taken".
    local rows = MySQL.query.await([[
        SELECT citizenid, callsign, fullname
        FROM mdt_profiles
        WHERE callsign IS NOT NULL AND callsign <> ''
    ]], {}) or {}

    local taken = {}
    for _, r in ipairs(rows) do
        taken[tostring(r.callsign)] = { citizenid = r.citizenid, name = r.fullname }
    end

    -- Reserved is keyed by number in the config; hand it over keyed by the rendered
    -- callsign so the UI never has to know about padding or prefixes.
    local reserved = {}
    for n, why in pairs(cfg.Reserved or {}) do
        reserved[FormatCallsign(n, cfg)] = tostring(why)
    end

    return {
        success  = true,
        -- The picker greys reserved boxes out for everyone else; whoever has this can
        -- click them.
        canAssignReserved = CanAssignReservedCallsign(src),
        min      = cfg.Min,
        max      = cfg.Max,
        pad      = cfg.Pad,
        prefix   = cfg.Prefix,
        pageSize = cfg.PageSize,
        source   = cfg.Source,
        taken    = taken,
        reserved = reserved,
    }
end)

ps.registerCallback(resourceName .. ':server:getCallsign', function(source, payload)
    if not CheckAuth(source) then return { callsign = '' } end

    -- No citizenid means "mine". The top bar asks about the officer holding the MDT,
    -- and without this it silently got an empty string back every time.
    local cid = payload.citizenid or (ps.getIdentifier and ps.getIdentifier(source))
    if not cid then return { callsign = '' } end
 
    if not QBCore then return { success = false, message = 'Core framework not available' } end
    local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
    if Player then
        return { callsign = tostring(Player.PlayerData.metadata.callsign or '') }
    end
    local row = MySQL.single.await('SELECT callsign FROM mdt_profiles WHERE citizenid = ?', { cid })
    return { callsign = tostring(row and row.callsign or '') }
end)
 
-- Set Radio Frequency
ps.registerCallback(resourceName .. ':server:setRadio', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
 
    payload = payload or {}
    local cid = payload.citizenid or payload.cid
    local newRadio = payload.radio or payload.newradio
 
    if not cid or not newRadio then
        return { success = false, message = 'Missing citizen ID or radio frequency' }
    end
 
    if not QBCore then return { success = false, message = 'Core framework not available' } end
    local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(cid)
    if not targetPlayer then
        return { success = false, message = 'Officer must be online' }
    end
 
    local targetSource = targetPlayer.PlayerData.source
 
    local radio = targetPlayer.Functions.GetItemByName('radio')
    if not radio then
        return { success = false, message = targetPlayer.PlayerData.charinfo.firstname .. ' does not have a radio!' }
    end
 
    TriggerClientEvent(resourceName .. ':client:setRadio', targetSource, newRadio)
    return { success = true, message = 'Radio set to ' .. newRadio }
end)
 
-- Get Unit Location (GPS to officer)
ps.registerCallback(resourceName .. ':server:getUnitLocation', function(source, cid)
    if not CheckAuth(source) then return {} end
    if not cid then return {} end
 
    if not QBCore then return {} end
    local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
    if Player then
        local coords = GetEntityCoords(GetPlayerPed(Player.PlayerData.source))
        return { x = coords.x, y = coords.y, z = coords.z }
    end
 
    return {}
end)