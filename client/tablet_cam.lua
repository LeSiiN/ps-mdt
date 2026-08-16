--[[
    client/tablet_cam.lua
    Smooth camera transition from the gameplay camera to an in-vehicle tablet position.

    Uses a single manually interpolated camera instead of SetCamActiveWithInterp,
    because that native refuses to ease when the destination cam is attached to an
    entity - it just snaps. Everything is computed in vehicle local space, so the
    blend stays correct even while the car is driving and turning.

    Public API (resource-local global, also exported):
        TabletCam.Start(duration)   -> boolean
        TabletCam.Stop(duration)
        TabletCam.IsActive()        -> boolean
        TabletCam.Live              -> live tunable table (used by tablet_cam_tune.lua)
]]

TabletCam = TabletCam or {}

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local DEFAULTS = {
    Enabled        = true,
    Duration       = 1200,
    ExitDuration   = 900,
    DisableDriving = false,   -- ps-mdt already blocks its own control set
    HideRadar      = true,
    SeatBone       = 'seat_dside_f',
    SeatFallback   = vec3(-0.35, 0.20, 0.62),
    Base = {
        offset = vec3(0.05, 0.28, 0.05),
        rot    = vec3(-22.0, 0.0, -18.0),
        fov    = 45.0,
    },
    Overrides = {},
}

local CFG = {}

local function buildConfig()
    local user = (Config and Config.TabletCam) or {}
    for k, v in pairs(DEFAULTS) do
        if user[k] ~= nil then CFG[k] = user[k] else CFG[k] = v end
    end
    CFG.Base = {
        offset = (user.Base and user.Base.offset) or DEFAULTS.Base.offset,
        rot    = (user.Base and user.Base.rot)    or DEFAULTS.Base.rot,
        fov    = (user.Base and user.Base.fov)    or DEFAULTS.Base.fov,
    }
end

buildConfig()
CreateThread(function() Wait(0) buildConfig() end)

local function getModelConfig(veh)
    local o = CFG.Overrides and CFG.Overrides[GetEntityModel(veh)]
    if not o then
        return { offset = CFG.Base.offset, rot = CFG.Base.rot, fov = CFG.Base.fov }
    end
    return {
        offset = o.offset or CFG.Base.offset,
        rot    = o.rot    or CFG.Base.rot,
        fov    = o.fov    or CFG.Base.fov,
    }
end

-- ---------------------------------------------------------------------------
-- Math helpers
-- ---------------------------------------------------------------------------

-- ease in / out cubic - slow start, fast middle, soft landing
local function ease(t)
    if t < 0.5 then return 4.0 * t * t * t end
    local f = (2.0 * t) - 2.0
    return 0.5 * f * f * f + 1.0
end

local function wrap180(a)
    a = (a + 180.0) % 360.0
    if a < 0.0 then a = a + 360.0 end
    return a - 180.0
end

-- always takes the short way around, so the cam never spins the long way
local function lerpAngle(a, b, t)
    return a + wrap180(b - a) * t
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- 'idle' -> 'entering' -> 'active' -> 'leaving' -> 'idle'
local state        = 'idle'
local pendingCb    = nil

local tabletCam    = nil
local camRunning   = false
local prevViewMode = nil
local seatBase     = vec3(0.0, 0.0, 0.0)

local transStart   = 0
local transDur     = 0
local startOff     = vec3(0.0, 0.0, 0.0)   -- vehicle local space
local startRot     = vec3(0.0, 0.0, 0.0)   -- delta to vehicle rotation
local startFov     = 50.0

TabletCam.Live = {
    offset = vec3(0.0, 0.0, 0.0),
    rot    = vec3(0.0, 0.0, 0.0),
    fov    = 45.0,
    veh    = 0,
}

local DISABLED_CONTROLS = {
    59, 60, 61, 62, 63, 64,
    71, 72, 75, 76,
    266, 267, 268, 269,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function resolveSeatOffset(veh)
    local bone = GetEntityBoneIndexByName(veh, CFG.SeatBone or 'seat_dside_f')
    if bone ~= -1 then
        local world = GetWorldPositionOfEntityBone(veh, bone)
        return GetOffsetFromEntityGivenWorldCoords(veh, world.x, world.y, world.z)
    end
    return CFG.SeatFallback
end

-- Fires the completion callback exactly once, whatever path we exit through.
local function fire(ok, reason)
    local cb = pendingCb
    pendingCb = nil
    if cb then
        local success, err = pcall(cb, ok, reason)
        if not success then
            print(('^1[tablet-cam]^7 callback error: %s'):format(err))
        end
    end
end

-- Writes cam position / rotation for a given local offset and rotation delta.
-- Nothing is ever attached, so the game never fights us over the transform.
local function applyCam(veh, off, rotDelta, fov)
    local world = GetOffsetFromEntityInWorldCoords(veh, off.x, off.y, off.z)
    SetCamCoord(tabletCam, world.x, world.y, world.z)

    local r = GetEntityRotation(veh, 2)
    SetCamRot(tabletCam, r.x + rotDelta.x, r.y + rotDelta.y, r.z + rotDelta.z, 2)
    SetCamFov(tabletCam, fov)
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

function TabletCam.IsActive()
    return camRunning
end

--- Jumps straight to the current target values, ending any running blend.
--- Used by the tuner so edits are visible immediately instead of easing in.
function TabletCam.Snap()
    if state ~= 'entering' and state ~= 'active' then return end
    transStart = 0
    transDur   = 1
    if state == 'entering' then
        state = 'active'
        fire(true, 'done')
    end
end

function TabletCam.GetState()
    return state
end

--- Starts the move into the tablet position.
--- @param duration number|nil  blend time in ms
--- @param onComplete function|nil  called once as (ok:boolean, reason:string)
---        reason is 'done' | 'cancelled' | 'left_vehicle' | 'dead' | 'vehicle_gone' | 'resource_stop'
--- @return boolean  false means no camera was started - caller should carry on without it
function TabletCam.Start(duration, onComplete)
    -- Only a clean idle state may start. Blocks double keypresses, and blocks
    -- starting while the exit blend from a previous close is still running.
    if state ~= 'idle' then return false end
    if CFG.Enabled == false then return false end

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or not DoesEntityExist(veh) then return false end
    if IsEntityDead(ped) then return false end

    duration = duration or CFG.Duration or 1200
    if duration < 1 then duration = 1 end

    pendingCb = onComplete
    state     = 'entering'

    local model = getModelConfig(veh)
    seatBase = resolveSeatOffset(veh)

    TabletCam.Live.offset = model.offset
    TabletCam.Live.rot    = model.rot
    TabletCam.Live.fov    = model.fov
    TabletCam.Live.veh    = veh

    -- Capture where the player is looking right now, converted into the
    -- vehicle's local space so the start point drives along with the car.
    local gCoord = GetGameplayCamCoord()
    local gRot   = GetGameplayCamRot(2)
    local vRot   = GetEntityRotation(veh, 2)

    startOff = GetOffsetFromEntityGivenWorldCoords(veh, gCoord.x, gCoord.y, gCoord.z)
    startRot = vec3(wrap180(gRot.x - vRot.x), wrap180(gRot.y - vRot.y), wrap180(gRot.z - vRot.z))
    startFov = GetGameplayCamFov()

    transStart = GetGameTimer()
    transDur   = duration

    tabletCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', false)
    applyCam(veh, startOff, startRot, startFov)   -- frame 0 == exactly the gameplay cam
    SetCamActive(tabletCam, true)
    RenderScriptCams(true, false, 0, true, true)

    prevViewMode = GetFollowVehicleCamViewMode()
    if CFG.HideRadar ~= false then DisplayRadar(false) end
    camRunning = true

    CreateThread(function()
        while camRunning and tabletCam and DoesCamExist(tabletCam) do
            local p = PlayerPedId()

            local abort
            if not DoesEntityExist(veh) then
                abort = 'vehicle_gone'
            elseif IsEntityDead(p) then
                abort = 'dead'
            elseif not IsPedInVehicle(p, veh, false) then
                abort = 'left_vehicle'
            end

            if abort then
                TabletCam.Stop(400, abort)
                break
            end

            local live = TabletCam.Live
            local endOff = seatBase + live.offset

            local t = 1.0
            if transDur > 0 then
                t = (GetGameTimer() - transStart) / transDur
                if t > 1.0 then t = 1.0 elseif t < 0.0 then t = 0.0 end
            end

            if t >= 1.0 then
                applyCam(veh, endOff, live.rot, live.fov)
                if state == 'entering' then
                    state = 'active'
                    fire(true, 'done')
                end
            else
                local e = ease(t)
                applyCam(veh,
                    vec3(lerp(startOff.x, endOff.x, e),
                         lerp(startOff.y, endOff.y, e),
                         lerp(startOff.z, endOff.z, e)),
                    vec3(lerpAngle(startRot.x, live.rot.x, e),
                         lerpAngle(startRot.y, live.rot.y, e),
                         lerpAngle(startRot.z, live.rot.z, e)),
                    lerp(startFov, live.fov, e))
            end

            if CFG.DisableDriving then
                for i = 1, #DISABLED_CONTROLS do
                    DisableControlAction(0, DISABLED_CONTROLS[i], true)
                end
            end

            Wait(0)
        end
    end)

    return true
end

--- Aborts a running entry blend. No-op if the cam is already settled.
--- @return boolean whether anything was cancelled
function TabletCam.Cancel(duration)
    if state ~= 'entering' then return false end
    TabletCam.Stop(duration, 'cancelled')
    return true
end

--- Blends back to the gameplay camera.
--- @param reason string|nil  passed to a still pending completion callback
function TabletCam.Stop(duration, reason)
    if state == 'idle' or state == 'leaving' then return end
    duration   = duration or CFG.ExitDuration or 900
    camRunning = false
    state      = 'leaving'

    -- Anyone waiting on the entry blend is told it will not arrive
    fire(false, reason or 'cancelled')

    RenderScriptCams(false, true, duration, true, true)
    DisplayRadar(true)
    if prevViewMode then SetFollowVehicleCamViewMode(prevViewMode) end

    local cam = tabletCam
    tabletCam = nil
    TabletCam.Live.veh = 0

    -- Destroy only AFTER the blend back finished, otherwise the view snaps.
    -- The state stays 'leaving' until then, so a Start() during the blend is
    -- rejected instead of fighting the running transition.
    SetTimeout(duration + 100, function()
        if cam and DoesCamExist(cam) then DestroyCam(cam, false) end
        if state == 'leaving' then state = 'idle' end
    end)
end

-- ---------------------------------------------------------------------------
-- Events / exports / teardown
-- ---------------------------------------------------------------------------

RegisterNetEvent('ps-mdt:client:tabletcam:start', function(duration)
    TabletCam.Start(duration)
end)

RegisterNetEvent('ps-mdt:client:tabletcam:stop', function(duration)
    TabletCam.Stop(duration)
end)

exports('startTabletCam', function(duration) return TabletCam.Start(duration) end)
exports('stopTabletCam',  function(duration) TabletCam.Stop(duration) end)
exports('isTabletCamActive', function() return TabletCam.IsActive() end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if state == 'idle' then return end
    camRunning = false
    state      = 'idle'
    fire(false, 'resource_stop')
    RenderScriptCams(false, false, 0, true, true)
    if tabletCam and DoesCamExist(tabletCam) then DestroyCam(tabletCam, false) end
    DisplayRadar(true)
end)