MDTOpen = false -- Track MDT state
local resourceName = tostring(GetCurrentResourceName())

-- Control management
local controlsDisabled = false
local controlCheckInterval = 0

-- Open/close state guards
local mdtOpening = false   -- camera is moving in, UI not shown yet
local mdtClosing = false   -- exit blend running, input is swallowed

-- Cache globals for performance
local DisableControlAction = DisableControlAction
local Wait = Wait
local CreateThread = CreateThread
local IsPedSwimming = IsPedSwimming
local SetNuiFocus = SetNuiFocus
local SetNuiFocusKeepInput = SetNuiFocusKeepInput
local SendNUI = SendNUI
local RegisterNUICallback = RegisterNUICallback

-- Permissions check ------------------------------------------

-- Check Job Authorization (returns true, false, or { isCivilian = true })
function CheckAuth()
    local result = ps.callback(resourceName..':server:checkAuth')
    if type(result) == 'table' and result.isCivilian then
        return result
    end
    return result
end

-- Controls --------------------------------------------------

-- Controls to disable
local restrictedControls = {
    -- Camera controls
    {0, 0},   -- Next Camera
    {0, 1},   -- Look Left/Right
    {0, 2},   -- Look Up/Down
    {0, 26},  -- Look Behind

    -- Weapon controls
    {0, 16},  -- Next Weapon
    {0, 17},  -- Previous Weapon
    {0, 24},  -- Attack
    {0, 25},  -- Aim
    {0, 37},  -- Weapon Wheel
    {0, 140}, -- Melee Attack

    -- Movement controls
    {0, 21},  -- Sprint
    {0, 22},  -- Jump
    {0, 36},  -- Duck/Sneak
    {0, 44},  -- Cover
    {0, 55},  -- Dive

    -- Vehicle controls
    {0, 75},  -- Exit Vehicle
    {0, 76},  -- Handbrake
    {0, 81},  -- Next Radio
    {0, 82},  -- Previous Radio
    {0, 85},  -- Radio Wheel
    {0, 86},  -- Horn
    {0, 91},  -- Passenger Aim
    {0, 92},  -- Passenger Attack
    {0, 99},  -- Vehicle Weapon Select
    {0, 106}, -- Vehicle Override
    {0, 120}, -- Vehicle Duck

    -- Aircraft controls
    {0, 114}, -- Aircraft Attack
    {0, 115}, -- Aircraft Weapon
    {0, 121}, -- Aircraft Camera
    {0, 122}, -- Aircraft Override
    {0, 135}, -- Submarine Override

    -- UI controls
    {0, 47},  -- Detonate
    {0, 200}, -- Pause Menu
    {0, 245}, -- Chat
}

-- Control disabling loop
-- Doubles as a cheap watchdog: while the MDT is up we poll for death every
-- ~500ms so a player who dies mid-session does not get stuck in the tablet.
local nextDeathCheck = 0

CreateThread(function()
    while true do
        if controlsDisabled then
            controlCheckInterval = 0
            for i = 1, #restrictedControls do
                local control = restrictedControls[i]
                DisableControlAction(control[1], control[2], true)
            end

            -- Camera phase handles death itself and aborts, so only poll once
            -- the UI is actually up
            if MDTOpen and not mdtOpening then
                local now = GetGameTimer()
                if now >= nextDeathCheck then
                    nextDeathCheck = now + 500
                    if ps.isDead() then
                        CloseMDT()
                    end
                end
            end
        else
            controlCheckInterval = 150
        end
        Wait(controlCheckInterval)
    end
end)

-- Control state management
local function toggleControls(state)
    controlsDisabled = state
end

-- Guards ------------------------------------------------------

-- Single source of truth for "may this player open / keep open the MDT".
-- Called twice on the vehicle path: once before the camera moves, once when it
-- arrives, because a lot can change during a 1.2s animation.
local function canUseMDT(isCivilian)
    local ped = PlayerPedId()

    -- Don't allow if player is dead
    if ps.isDead() then
        return false, 'You cannot open the MDT right now'
    end

    -- Don't allow if swimming
    if IsPedSwimming(ped) then
        return false, 'You cannot open the MDT right now'
    end

    if not isCivilian then
        -- Don't allow if armed (skip for civilians)
        if IsPedArmed(ped, 1) or IsPedArmed(ped, 2) or IsPedArmed(ped, 4) then
            return false, 'You cannot open the MDT right now'
        end

        -- Don't allow if viewing a camera
        if exports[resourceName]:isViewingCamera() then
            return false, 'You cannot open the MDT while viewing a camera'
        end
    end

    return true
end

-- MDT Display ------------------------------------------------

-- Prop, animation and sound. Starts together with the camera move so the
-- officer visibly pulls the tablet out while the view slides over to it.
local function playOpenFx(isCivilian)
    if isCivilian then return end
    PlayMDTSound('open')
    -- Tablet prop + animation (CreateObject / AttachEntity / TaskPlayAnim) is
    -- the most expensive native cluster on open; it yields internally so it
    -- lands on its own frame(s).
    PlayTabletAnimation()
end

local function stopOpenFx()
    StopTabletAnimation()
end

-- Everything that actually puts the MDT on screen. On the vehicle path this
-- only runs once the camera has finished its move.
local function finishOpenMDT(authResult, isCivilian)
    -- MDTOpen is already true at this point (set when the sequence started).
    -- This function only brings the UI up.
    MDTOpen = true
    nextDeathCheck = GetGameTimer() + 500

    SendNUI('setVisible', {
        visible   = true,
        debugMode = Config.Debug,
        dateTime  = Config.DateTime,
    })

    if isCivilian then
        -- Civilian mode: send auth with civilian flag
        local playerData = ps.getPlayerData()
        SendNUI('updateAuth', {
            authorized = true,
            playerData = playerData,
            isLEO      = false,
            onDuty     = true,
            isCivilian = true,
            jobType    = 'civilian',
        })
    else
        NUIUpdateAuth()
        TriggerServerEvent('ps-mdt:server:trackLogin')
    end

    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    toggleControls(true)

    -- Deferred: map state and radio config are not needed on the first frame
    CreateThread(function()
        Wait(0)
        if not MDTOpen then return end -- player toggled it back off already

        -- Map state is only needed once the Map tab is actually opened
        SendMapCitizenId()
        SendMapUiState()

        -- Tell the NUI which key to listen for so PTT works while the MDT is
        -- focused (resolves the player's real radio keybind when possible)
        if SendRadioConfig then SendRadioConfig() end
    end)
end

-- Open MDT
function OpenMDT()
    -- Case 1: exit blend still running. Starting a new camera move into a
    -- running one looks broken, so the input is swallowed entirely.
    if mdtClosing then return end

    -- Case 2: camera is moving in and the player presses again -> abort.
    -- The cancel callback below owns the cleanup, nothing to do here.
    if mdtOpening then
        TabletCam.Cancel()
        return
    end

    -- Case 3: already open -> normal close path
    if MDTOpen then
        CloseMDT()
        return
    end

    -- Check auth
    local authResult = CheckAuth()
    local isCivilian = type(authResult) == 'table' and authResult.isCivilian
    if not authResult and not isCivilian then return end

    local allowed, reason = canUseMDT(isCivilian)
    if not allowed then
        ps.notify(reason, 'error')
        return
    end

    -- MDTOpen goes true HERE, not after the camera arrives. Anything that
    -- keeps state while the tablet is out - the animation loop above all -
    -- polls this flag, and would exit instantly if it stayed false during the
    -- camera move. mdtOpening is what tells us the UI is not up yet.
    MDTOpen    = true
    mdtOpening = true

    -- Case 4: on foot, camera disabled in config, or camera busy. Start()
    -- returns false in all of those, so this stays one branch instead of four.
    local started = TabletCam.Start(nil, function(ok, camReason)
        mdtOpening = false

        if not ok then
            -- cancelled, left the vehicle, died, vehicle despawned, resource stop
            MDTOpen = false
            stopOpenFx()
            toggleControls(false)
            ps.debug('MDT open aborted during camera move: ' .. tostring(camReason))
            return
        end

        -- Re-check: the animation is long enough to draw a weapon or start swimming
        local stillAllowed, stillReason = canUseMDT(isCivilian)
        if not stillAllowed then
            MDTOpen = false
            TabletCam.Stop()
            stopOpenFx()
            toggleControls(false)
            ps.notify(stillReason, 'error')
            return
        end

        finishOpenMDT(authResult, isCivilian)
    end)

    playOpenFx(isCivilian)

    if started then
        toggleControls(true)   -- lock input for the duration of the move
    else
        mdtOpening = false
        finishOpenMDT(authResult, isCivilian)
    end
end

-- Close MDT
local closeControlsPending = false

function CloseMDT(keepAnimation)
    -- Close requested while the camera is still moving in
    if mdtOpening then
        TabletCam.Cancel()
        return
    end

    if not MDTOpen then return end

    MDTOpen    = false
    mdtClosing = true

    if StopMdtRadio then StopMdtRadio() end

    if not keepAnimation then
        StopTabletAnimation()
    end

    SendNUI('setVisible', { visible = false })
    SetNuiFocus(false, false)

    local exitDuration = 900
    TabletCam.Stop(exitDuration)

    -- Prevent ESC pause menu conflict - only spawn one delayed thread at a time
    if not closeControlsPending then
        closeControlsPending = true
        CreateThread(function()
            Wait(100)
            toggleControls(false) -- Re-enable controls
            closeControlsPending = false
        end)
    end

    -- Input stays blocked until the camera is fully back, otherwise a fast
    -- re-press starts an entry blend into the running exit blend
    SetTimeout(exitDuration + 150, function()
        mdtClosing = false
    end)

    ps.debug('MDT closed via CloseMDT function')
    TriggerServerEvent('ps-mdt:server:trackLogout')
end

-- Nui ------------------------------------------------------

RegisterNUICallback('setTopBarHover', function(_, cb)
    cb({})
end)

-- Copy text to clipboard (FiveM NUI blocks the browser Clipboard API)
RegisterNUICallback('copyToClipboard', function(data, cb)
    if data and data.text then
        lib.setClipboard(tostring(data.text))
    end
    cb({})
end)

-- Keybinds -------------------------------------------------

-- Key to open MDT
if not Config.Keys.OpenMDT.enabled then
    ps.debug('MDT Open Keybind Disabled')
else
    ps.debug('MDT Open Keybind Enabled: ' .. Config.Keys.OpenMDT.key)
    local message = 'Open MDT'
    ps.addKeybind(Config.Keys.OpenMDT.key, Config.Commands.Open.command, message)
end