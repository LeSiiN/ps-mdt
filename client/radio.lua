-- ── Radio bridge for the MDT's push-to-talk button ──────────────────────────
-- The MDT holds full NUI focus, so the game never sees a PTT keypress. Rather
-- than trying to work out which key the player's radio is bound to, the UI owns
-- a hold-to-talk button and tells us when it is held. All this file does is
-- translate that into whatever the running voice resource expects.

-- ── Resolve the active voice system + its trigger (cached) ───────────────────
local resolved -- nil = not yet resolved, false = none, table = config

local function commandExists(name)
    for _, c in ipairs(GetRegisteredCommands() or {}) do
        if c.name == name then return true end
    end
    return false
end

local function resolveSystem()
    if resolved ~= nil then return resolved end
    local cfg = Config.Radio
    if not cfg or not cfg.Enabled then resolved = false return resolved end

    local systemKey = cfg.VoiceSystem
    if systemKey == 'auto' then
        systemKey = nil
        for _, entry in ipairs(cfg.AutoDetect or {}) do
            if GetResourceState(entry.resource) == 'started' then
                systemKey = entry.system
                break
            end
        end
    end

    local sys = systemKey and cfg.Systems and cfg.Systems[systemKey]
    if not sys then resolved = false return resolved end

    -- Copy so we can fill in the fork-correct command without mutating config.
    local trigger = {
        system = systemKey,
        type = sys.type,
        start = sys.start,
        stop = sys.stop,
        resource = sys.resource,
        fn = sys.fn,
    }

    -- For command-type systems, pick the actually-registered command (handles
    -- forks that renamed it) and derive the matching stop command.
    if trigger.type == 'command' and sys.startCandidates then
        for _, cand in ipairs(sys.startCandidates) do
            if commandExists(cand) then
                trigger.start = cand
                trigger.stop = '-' .. cand:sub(2)
                break
            end
        end
    end

    resolved = trigger
    return resolved
end

-- ── Tell the NUI whether to show the button at all ───────────────────────────
function SendRadioConfig()
    local cfg = Config.Radio
    if not cfg or not cfg.Enabled then
        SendNUI('radioConfig', { enabled = false })
        return
    end
    -- No voice resource running means the button would do nothing, so hide it
    -- rather than offer a control that silently fails.
    SendNUI('radioConfig', { enabled = resolveSystem() and true or false })
end

-- ── Drive the active voice system ────────────────────────────────────────────
local radioTalking = false

local function setRadioTalking(state)
    state = state == true
    if state == radioTalking then return end -- de-dupe repeated events

    local trigger = resolveSystem()
    if not trigger then return end

    radioTalking = state
    if trigger.type == 'command' then
        local cmd = state and trigger.start or trigger.stop
        if cmd and cmd ~= '' then ExecuteCommand(cmd) end
    elseif trigger.type == 'export' then
        if trigger.resource and trigger.fn and GetResourceState(trigger.resource) == 'started' then
            pcall(function() exports[trigger.resource][trigger.fn](state) end)
        end
    end
end

-- Exposed so the MDT close path can force-stop a hanging transmission.
function StopMdtRadio()
    setRadioTalking(false)
end

RegisterNUICallback('radioPTT', function(data, cb)
    local talking = type(data) == 'table' and data.talking == true
    -- Allow release even after close; only block a fresh press when closed.
    if talking and not MDTOpen then cb({ ok = false }) return end
    setRadioTalking(talking)
    cb({ ok = true })
end)

-- A held button whose release never arrives is the one way to get stuck
-- transmitting, so drop the mic if the MDT is no longer open.
CreateThread(function()
    while true do
        Wait(1000)
        if radioTalking and not MDTOpen then
            setRadioTalking(false)
        end
    end
end)

-- If the voice resource restarts, re-resolve and refresh the button.
AddEventHandler('onClientResourceStart', function(res)
    if res == 'pma-voice' or res == 'saltychat' or res == 'yaca-voice' then
        resolved = nil
        if MDTOpen then SendRadioConfig() end
    end
end)