-- ─────────────────────────────────────────────────────────────────────────────
-- Impound lot spawning
--
-- An officer releases a vehicle from the MDT (from anywhere). The OWNER then
-- collects it: when they drive to the impound lot, their released vehicle is
-- parked into a free spot. No officer has to escort cars to the lot.
--
-- This runs for every player, but the server only ever hands a client vehicles
-- that belong to them.
--
-- The free-spot check runs here on purpose: only the client can actually see the
-- vehicles standing in the lot, so this is the only place an occupancy test is
-- trustworthy. Vehicles are placed into the first free spot, never on top of
-- each other.
-- ─────────────────────────────────────────────────────────────────────────────

local resourceName = tostring(GetCurrentResourceName())
local QBCore = exports['qb-core']:GetCoreObject()

local claiming = false          -- guards against overlapping claim round-trips
local spawnedRecently = {}      -- [plate] = GetGameTimer(), short-lived dedupe

local function cfg()
    return (Config and Config.Impound) or {}
end

local function lots()
    return cfg().Lots or {}
end

-- Apply the stored damage so a wreck comes out of the lot as a wreck.
local function doCarDamage(veh, data)
    local engine = (data.engine or 1000.0) + 0.0
    local body   = (data.body or 1000.0) + 0.0

    if engine < 200.0 then engine = 200.0 end
    if engine > 1000.0 then engine = 950.0 end
    if body < 150.0 then body = 150.0 end

    Wait(100)
    SetVehicleEngineHealth(veh, engine)

    if body < 950.0 then
        for i = 0, 4 do SmashVehicleWindow(veh, i) end
    end
    if body < 920.0 then
        SetVehicleDoorBroken(veh, 1, true)
        SetVehicleDoorBroken(veh, 6, true)
        SetVehicleDoorBroken(veh, 4, true)
        for i = 1, 4 do SetVehicleTyreBurst(veh, i, false, 990.0) end
    end
    if body < 1000.0 then
        SetVehicleBodyHealth(veh, 985.1)
    end
end

-- Is any vehicle sitting on this spot already?
local function isSpotTaken(spot, clearance)
    local spotCoords = vector3(spot.x, spot.y, spot.z)
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) then
            local d = #(GetEntityCoords(veh) - spotCoords)
            if d < clearance then return true end
        end
    end
    return false
end

-- First free spot in a lot, or nil when the lot is full.
local function findFreeSpot(lot)
    local clearance = cfg().SpotClearance or 3.0
    for _, spot in ipairs(lot.spots or {}) do
        if not isSpotTaken(spot, clearance) then return spot end
    end
    return nil
end

local function spawnImpoundVehicle(data, spot)
    local p = promise.new()

    QBCore.Functions.SpawnVehicle(data.vehicle, function(veh)
        if not veh or not DoesEntityExist(veh) then
            p:resolve(false)
            return
        end

        QBCore.Functions.TriggerCallback('qb-garage:server:GetVehicleProperties', function(properties)
            if properties then
                QBCore.Functions.SetVehicleProperties(veh, properties)
            end

            SetVehicleNumberPlateText(veh, data.plate)
            SetEntityHeading(veh, spot.w or 0.0)
            FreezeEntityPosition(veh, false)

            local fuelExport = Config.Fuel or 'LegacyFuel'
            if GetResourceState(fuelExport) == 'started' then
                pcall(function()
                    exports[fuelExport]:SetFuel(veh, data.fuel or 100.0)
                end)
            end

            doCarDamage(veh, data)

            pcall(function()
                TriggerEvent('vehiclekeys:client:SetOwner', QBCore.Functions.GetPlate(veh))
            end)

            SetVehicleEngineOn(veh, false, true, false)
            SetVehicleDoorsLocked(veh, 1) -- unlocked: it's being handed back to its owner

            p:resolve(true)
        end, data.plate)
    end, vector3(spot.x, spot.y, spot.z), true)

    return Citizen.Await(p)
end

-- Ask the server what's waiting at this lot, then place each car in a free spot.
local function claimSpawnsFor(lot)
    if claiming then return end
    claiming = true

    local res = ps.callback(resourceName .. ':server:claimImpoundSpawns', { lot = lot.id })
    local pending = (res and res.vehicles) or {}

    local now = GetGameTimer()
    for _, data in ipairs(pending) do
        -- Skip anything we just spawned but the server hasn't cleared yet.
        local last = spawnedRecently[data.plate]
        if not last or (now - last) > 15000 then
            local spot = findFreeSpot(lot)
            if not spot then
                ps.notify(('%s is full — move a vehicle to make room'):format(lot.label or lot.id), 'error')
                break
            end

            spawnedRecently[data.plate] = now
            local ok = spawnImpoundVehicle(data, spot)
            if ok then
                TriggerServerEvent(resourceName .. ':server:impoundSpawned', data.plate)
                ps.notify(('%s is ready — collected from impound'):format(data.plate), 'success')
            else
                spawnedRecently[data.plate] = nil
            end
        end
    end

    claiming = false
end

-- Nearest lot the player is standing at (within SpawnDistance), or nil.
local function lotNearPlayer()
    local pos = GetEntityCoords(PlayerPedId())
    local range = cfg().SpawnDistance or 60.0
    for _, lot in ipairs(lots()) do
        local r = lot.retrieve
        if r and #(pos - vector3(r.x, r.y, r.z)) <= range then
            return lot
        end
    end
    return nil
end

-- Idle-cheap proximity loop: only does real work when a lot is actually near.
CreateThread(function()
    while true do
        local wait = 3000
        local lot = lotNearPlayer()
        if lot then
            claimSpawnsFor(lot)
            wait = 5000
        end
        Wait(wait)
    end
end)

-- A vehicle was just released: if we're already standing at that lot, don't make
-- the officer wait for the next poll.
RegisterNetEvent(resourceName .. ':client:impoundSpawnAvailable', function(lotId)
    local lot = lotNearPlayer()
    if lot and lot.id == lotId then
        CreateThread(function() claimSpawnsFor(lot) end)
    end
end)