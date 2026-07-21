local resourceName = tostring(GetCurrentResourceName())

local function cfg()
    return (Config and Config.CameraTamper) or {}
end

-- Impacts are validated HERE rather than on the client, so camera positions never leave
-- the server. A client only ever says "my bullet landed at X" — it never learns whether a
-- camera is nearby unless one actually goes down. That keeps the map of every camera out
-- of reach of a modified client.
RegisterNetEvent(resourceName .. ':server:reportWeaponImpact', function(impact)
    if cfg().Enabled ~= true then return end

    local src = source
    if not src or src <= 0 then return end

    -- Sustained automatic fire would otherwise report every single round.
    if not RateLimit(src, 'cameraImpact', cfg().ReportsPerWindow or 12, cfg().ReportWindowMs or 1000) then
        return
    end

    -- Never trust the shape of a client payload.
    if type(impact) ~= 'table' then return end
    local x, y, z = tonumber(impact.x), tonumber(impact.y), tonumber(impact.z)
    if not x or not y or not z then return end

    local coords = vector3(x, y, z)

    -- The client reports where ITS bullet landed, but a modified client could report
    -- anywhere on the map. Anchor the claim to where the player actually is: a bullet
    -- can't land 500m away from the shooter in a straight line they never had.
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local pedCoords = GetEntityCoords(ped)
        if pedCoords and #(coords - pedCoords) > 250.0 then
            ps.warn(('Rejected implausible weapon impact from %s (%.0fm away)')
                :format(GetPlayerName(src) or src, #(coords - pedCoords)))
            return
        end
    end

    local camId, camera, nearestDist = FindOnlineCameraNear(coords, cfg().HitRadius or 2.0)
    if not camId or not camera then
        -- Log how close the nearest camera was, so a miss can be diagnosed: no distance at
        -- all means no online static cameras exist; a distance just above the radius means
        -- HitRadius needs raising.
        if nearestDist then
            ps.debug(('Impact %.2fm from nearest camera (radius %.1fm)')
                :format(nearestDist, cfg().HitRadius or 2.0))
        else
            ps.debug('Impact received but no camera matched — ' ..
                (DescribeCameraRegistry and DescribeCameraRegistry() or 'registry unavailable'))
        end
        return
    end

    local ok = SetCameraOfflineFor(camId, cfg().OfflineMs or 600000)
    if not ok then return end

    local label = camera.camLabel or camId
    -- Where the camera really is: the prop for prop-backed cameras, the feed
    -- position for virtual ones (whose stored coords describe nothing).
    local at = (CameraHitCoords and CameraHitCoords(camera)) or camera.coords
    local citizenid = ps.getIdentifier and ps.getIdentifier(src) or nil
    local playerName = ps.getPlayerName and ps.getPlayerName(src) or (GetPlayerName(src) or 'Unknown')

    ps.debug(('Camera %s (%s) shot out by %s'):format(camId, label, playerName))

    if ps.auditLog then
        pcall(ps.auditLog, src, 'camera_tampered', 'camera', camId, {
            label = label,
            coords = at and { x = at.x, y = at.y, z = at.z } or nil,
        })
    end

    -- Hand the alert off as an event rather than calling into a dispatch resource, so a
    -- server can route it wherever it likes without the MDT taking a dependency.
    if cfg().EmitEvent ~= false then
        TriggerEvent(resourceName .. ':server:cameraTampered', {
            camId = camId,
            label = label,
            coords = at,
            offlineMs = cfg().OfflineMs or 600000,
            suspectSource = src,
            suspectCitizenId = citizenid,
            suspectName = playerName,
        })
    end

    -- Refresh anyone with the camera list open so the status flips live.
    TriggerClientEvent(resourceName .. ':client:cameraStatusChanged', -1, {
        camId = camId,
        isOnline = false,
    })
end)