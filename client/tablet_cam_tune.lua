--[[
    client/tablet_cam_tune.lua
    Dev-only live tuner for the in-vehicle tablet camera.

    Enable with:  set mdt_tabletcam_dev 1     (server.cfg)
    Then:         /mdtcam        toggle the camera
                  /mdtcamtune    enter tune mode

    Tune mode keys
        Arrow L/R      offset X (right / left)
        Arrow U/D      offset Y (forward / back)
        PageUp/Down    offset Z (up / down)
        ALT + Arrows   rotation yaw / pitch
        ALT + PgUp/Dn  rotation roll
        Z / X          FOV
        SHIFT          hold for 5x step size
        E              dump config block to console (F8)
        BACKSPACE      leave tune mode

    Ship without this file (or leave the convar at 0) in production.
]]

-- IMPORTANT: this must be a REPLICATED convar. `set` only exists on the server
-- and GetConvarInt returns 0 on every client, which silently kills the tuner.
local function devEnabled()
    return GetConvarInt('mdt_tabletcam_dev', 0) == 1
end

local function devWarn()
    print('^1[tablet-cam]^7 dev mode off. Put ^5setr mdt_tabletcam_dev 1^7 in server.cfg (setr, not set) and restart.')
end

local tuning = false

local STEP_POS = 0.005
local STEP_ROT = 0.25
local STEP_FOV = 0.20

-- control ids
local ARROW_UP, ARROW_DOWN, ARROW_LEFT, ARROW_RIGHT = 172, 173, 174, 175
local PAGE_UP, PAGE_DOWN = 10, 11
local LEFT_ALT, LEFT_SHIFT = 19, 21
local KEY_E, KEY_Z, KEY_X, KEY_BACKSPACE = 38, 20, 73, 177

local TUNE_CONTROLS = {
    ARROW_UP, ARROW_DOWN, ARROW_LEFT, ARROW_RIGHT,
    PAGE_UP, PAGE_DOWN, LEFT_ALT, LEFT_SHIFT,
    KEY_E, KEY_Z, KEY_X, KEY_BACKSPACE,
}

-- Reads the key no matter whether some other script disabled it this frame.
-- IsControlPressed alone returns false for disabled controls, and ps-mdt
-- disables a long list while the tablet is up.
local function pressed(control)
    return IsControlPressed(0, control) or IsDisabledControlPressed(0, control)
end

local function justPressed(control)
    return IsControlJustPressed(0, control) or IsDisabledControlJustPressed(0, control)
end

local function drawTxt(x, y, text, scale, r, g, b)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(r or 255, g or 255, b or 255, 225)
    SetTextOutline()
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawText(x, y)
end

local function dumpConfig()
    local live = TabletCam.Live
    local veh  = live.veh
    if veh == 0 or not DoesEntityExist(veh) then return end

    local name = string.lower(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))

    local block = string.format(
        "    [`%s`] = { offset = vec3(%.3f, %.3f, %.3f), rot = vec3(%.1f, %.1f, %.1f), fov = %.1f },",
        name,
        live.offset.x, live.offset.y, live.offset.z,
        live.rot.x, live.rot.y, live.rot.z,
        live.fov
    )

    print('^2[tablet-cam]^7 paste into Config.TabletCam.Overrides:')
    print('^5' .. block .. '^7')
end

local function tuneLoop()
    CreateThread(function()
        while tuning do
            if not TabletCam.IsActive() then
                tuning = false
                break
            end

            for i = 1, #TUNE_CONTROLS do
                DisableControlAction(0, TUNE_CONTROLS[i], true)
            end

            local live = TabletCam.Live
            local fast = pressed(LEFT_SHIFT) and 5.0 or 1.0
            local alt  = pressed(LEFT_ALT)

            local dx, dy, dz = 0.0, 0.0, 0.0
            local rp, rr, ry = 0.0, 0.0, 0.0

            if alt then
                if pressed(ARROW_UP)    then rp = rp + STEP_ROT * fast end
                if pressed(ARROW_DOWN)  then rp = rp - STEP_ROT * fast end
                if pressed(ARROW_LEFT)  then ry = ry + STEP_ROT * fast end
                if pressed(ARROW_RIGHT) then ry = ry - STEP_ROT * fast end
                if pressed(PAGE_UP)     then rr = rr + STEP_ROT * fast end
                if pressed(PAGE_DOWN)   then rr = rr - STEP_ROT * fast end
            else
                if pressed(ARROW_UP)    then dy = dy + STEP_POS * fast end
                if pressed(ARROW_DOWN)  then dy = dy - STEP_POS * fast end
                if pressed(ARROW_RIGHT) then dx = dx + STEP_POS * fast end
                if pressed(ARROW_LEFT)  then dx = dx - STEP_POS * fast end
                if pressed(PAGE_UP)     then dz = dz + STEP_POS * fast end
                if pressed(PAGE_DOWN)   then dz = dz - STEP_POS * fast end
            end

            if dx ~= 0.0 or dy ~= 0.0 or dz ~= 0.0 then
                live.offset = vec3(live.offset.x + dx, live.offset.y + dy, live.offset.z + dz)
            end
            if rp ~= 0.0 or rr ~= 0.0 or ry ~= 0.0 then
                live.rot = vec3(live.rot.x + rp, live.rot.y + rr, live.rot.z + ry)
            end

            if pressed(KEY_Z) then live.fov = math.min(120.0, live.fov + STEP_FOV * fast) end
            if pressed(KEY_X) then live.fov = math.max(10.0,  live.fov - STEP_FOV * fast) end

            if justPressed(KEY_E) then dumpConfig() end
            if justPressed(KEY_BACKSPACE) then
                tuning = false
                break
            end

            -- HUD
            DrawRect(0.155, 0.760, 0.280, 0.180, 0, 0, 0, 170)
            drawTxt(0.030, 0.685, '~b~TABLET CAM TUNER', 0.42)
            drawTxt(0.030, 0.715, string.format('offset  %.3f / %.3f / %.3f', live.offset.x, live.offset.y, live.offset.z), 0.35)
            drawTxt(0.030, 0.740, string.format('rot     %.1f / %.1f / %.1f', live.rot.x, live.rot.y, live.rot.z), 0.35)
            drawTxt(0.030, 0.765, string.format('fov     %.1f', live.fov), 0.35)
            drawTxt(0.030, 0.795, alt and '~y~mode: ROTATION (hold ALT)' or 'mode: POSITION  |  ALT = rotation', 0.32)
            drawTxt(0.030, 0.818, 'E = dump to console   BACKSPACE = exit', 0.32)

            Wait(0)
        end

        if not tuning then
            print('^3[tablet-cam]^7 tune mode off')
        end
    end)
end

RegisterCommand('mdtcam', function()
    --if not devEnabled() then return devWarn() end

    if TabletCam.IsActive() then
        TabletCam.Stop()
    else
        if not TabletCam.Start() then
            print('^1[tablet-cam]^7 cannot start - sit in a vehicle, and make sure the cam is idle (state: '
                .. tostring(TabletCam.GetState()) .. ')')
        end
    end
end, false)

RegisterCommand('mdtcamtune', function()
    --if not devEnabled() then return devWarn() end

    if not TabletCam.IsActive() then
        if not TabletCam.Start() then
            print('^1[tablet-cam]^7 cannot start - sit in a vehicle, and make sure the cam is idle (state: '
                .. tostring(TabletCam.GetState()) .. ')')
            return
        end
    end
    if tuning then return end

    -- Skip the entry blend, otherwise the first second of edits gets eased away
    TabletCam.Snap()

    tuning = true
    print('^2[tablet-cam]^7 tune mode on')
    print('^3[tablet-cam]^7 close the MDT first - while the NUI has focus the keys go to the browser, not the game')
    tuneLoop()
end, false)