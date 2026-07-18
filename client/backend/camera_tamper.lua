local resourceName = tostring(GetCurrentResourceName())

local function cfg()
    return (Config and Config.CameraTamper) or {}
end

local coolDown = false

-- Driven by the game's own gunshot event rather than a polling loop: the engine already
-- knows the moment a shot is fired, so there's nothing to poll for and no window to miss.
--
-- CEventGunShot also fires when the player merely *witnesses* someone else shooting, so
-- IsPedShooting() confirms the shot was actually ours before we report anything.
AddEventHandler('CEventGunShot', function(_, ped)
    if cfg().Enabled ~= true then return end
    if coolDown then return end

    local playerPed = PlayerPedId()
    if not IsPedShooting(playerPed) then return end

    coolDown = true
    SetTimeout(cfg().ReportCooldownMs or 250, function() coolDown = false end)

    -- Note the singular "Coord" — the native is GET_PED_LAST_WEAPON_IMPACT_COORD.
    local hasHit, impactPos = GetPedLastWeaponImpactCoord(playerPed)
    if not hasHit or not impactPos then return end

    ps.debug(('Weapon impact at %.2f %.2f %.2f'):format(impactPos.x, impactPos.y, impactPos.z))

    TriggerServerEvent(resourceName .. ':server:reportWeaponImpact', {
        x = impactPos.x, y = impactPos.y, z = impactPos.z,
    })
end)

-- A camera changed state somewhere in the world; let an open MDT reflect it without a
-- full reload.
RegisterNetEvent(resourceName .. ':client:cameraStatusChanged', function(data)
    if not data or not data.camId then return end
    SendNUIMessage({
        action = 'cameraStatusChanged',
        data = { camId = data.camId, isOnline = data.isOnline == true },
    })
end)