-- ─────────────────────────────────────────────────────────────────────────────
-- On-site impound
--
-- /impound takes the vehicle the officer is sitting in, or the closest one.
--
-- Two outcomes, decided by the server:
--   * The vehicle has an owner  → the full impound form opens (the same UI as in
--     the MDT) and the car is removed once the record is written.
--   * Nobody owns it (traffic)  → it is simply towed away and the officer earns a
--     small payout for keeping the streets clear.
--
-- The client only proposes; every check that matters (distance, occupants,
-- ownership, payout limits) is re-done server-side.
-- ─────────────────────────────────────────────────────────────────────────────

local resourceName = tostring(GetCurrentResourceName())

local busy = false

local function cfg()
    return ((Config and Config.Impound) or {}).OnSite or {}
end

-- The vehicle the officer means: the one they're in, else the nearest in range.
local function targetVehicle()
    local ped = PlayerPedId()

    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 and DoesEntityExist(veh) then return veh end

    local maxDist = cfg().MaxDistance or 6.0
    local coords = GetEntityCoords(ped)
    local best, bestDist = nil, maxDist + 0.01

    for _, v in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(v) then
            local d = #(GetEntityCoords(v) - coords)
            if d < bestDist then
                best, bestDist = v, d
            end
        end
    end

    return best
end

-- Is a real player in there? NPC occupants are fine — a parked car with a sleeping
-- ped in it is still litter. Only actual players block the tow.
local function hasPlayerInside(veh)
    for _, playerId in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(playerId)
        if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) == veh then
            return true
        end
    end
    return false
end

local function openImpoundForm(ctx)
    SendNUIMessage({
        action = 'showImpoundForm',
        data = {
            plate = ctx.plate,
            model = ctx.model,
            netId = ctx.netId,
        },
    })
    SetNuiFocus(true, true)
end

local function runImpound()
    if busy then return end
    busy = true

    local veh = targetVehicle()
    if not veh then
        ps.notify('No vehicle nearby', 'error')
        busy = false
        return
    end

    if hasPlayerInside(veh) then
        ps.notify('There is somebody in that vehicle', 'error')
        busy = false
        return
    end

    -- Make sure the entity is networked before handing a net id to the server.
    local netId = NetworkGetNetworkIdFromEntity(veh)
    if not netId or netId == 0 then
        ps.notify('That vehicle cannot be impounded', 'error')
        busy = false
        return
    end

    local plate = GetVehicleNumberPlateText(veh)
    if plate then plate = plate:gsub('%s+', ''):upper() end

    local model = GetDisplayNameFromVehicleModel(GetEntityModel(veh))

    local res = ps.callback(resourceName .. ':server:inspectOnSiteVehicle', {
        netId = netId,
        plate = plate,
        model = model,
    })

    if not res or not res.success then
        ps.notify((res and res.message) or 'Could not inspect that vehicle', 'error')
        busy = false
        return
    end

    if res.owned then
        -- Owned: officer fills in reason, fee, lot, notes, photo.
        openImpoundForm({ plate = res.plate, model = res.model, netId = netId })
        busy = false
        return
    end

    -- Unowned traffic: no form, just tow it.
    local out = ps.callback(resourceName .. ':server:cleanupVehicle', {
        netId = netId,
        plate = plate,
    })

    if out and out.success then
        ps.notify(out.message or 'Vehicle removed', 'success')
    else
        ps.notify((out and out.message) or 'Could not remove that vehicle', 'error')
    end

    busy = false
end

RegisterCommand(cfg().Command or 'impound', function()
    CreateThread(runImpound)
end, false)

-- So the command can be bound to a target/interaction later on.
exports('impoundNearbyVehicle', function()
    CreateThread(runImpound)
end)

-- ── NUI callbacks for the standalone form ──────────────────────────────────────
-- Deliberately no MDTOpen check: this form lives outside the MDT.

RegisterNUICallback('submitOnSiteImpound', function(data, cb)
    if not data or not data.netId or not data.plate then
        cb({ success = false, message = 'Missing vehicle' })
        return
    end
    local result = ps.callback(resourceName .. ':server:impoundOnSite', data)
    cb(result or { success = false, message = 'Impound failed' })
end)

RegisterNUICallback('closeImpoundForm', function(_, cb)
    SetNuiFocus(false, false)
    cb({ success = true })
end)

-- The standalone form needs the reason/lot/fee config too.
RegisterNUICallback('getImpoundFormConfig', function(_, cb)
    local result = ps.callback(resourceName .. ':server:getImpoundConfig', {})
    cb(result or {})
end)
