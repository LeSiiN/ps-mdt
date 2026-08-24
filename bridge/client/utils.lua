--[[
    ps-mdt / bridge / utils  (client)

    Replaces the remaining ps_lib modules: notify, callbacks, asset requests,
    keybinds and sound playback.

    Callbacks
    ---------
    MDT.callback(name, ...) is a thin wrapper over lib.callback.await. It keeps
    the ps_lib call signature (~290 call sites) while fixing the two things that
    actually hurt:

      * ps_lib keyed pending callbacks by NAME. Two concurrent calls to the same
        callback overwrote each other's promise and one caller hung forever.
        ox_lib keys per request, so concurrency is safe.
      * A callback that errored server side used to take the whole calling
        thread down with it. Here it is caught, logged and returned as nil.
]]

---@diagnostic disable-next-line: lowercase-global
MDT = MDT or {}

-- Notifications --------------------------------------------------------------

--- Shows a notification to the local player.
---@param text string
---@param notifyType? string 'inform' | 'success' | 'error' | 'warning'
---@param duration? number milliseconds, defaults to 5000
function MDT.notify(text, notifyType, duration)
    if not text then return end

    -- ps_lib used 'info', ox_lib calls it 'inform'.
    if notifyType == 'info' then notifyType = 'inform' end

    lib.notify({
        description = text,
        type        = notifyType or 'inform',
        duration    = duration or 5000,
    })
end

-- Callbacks ------------------------------------------------------------------

--- Calls a server callback and waits for the result.
---
--- Errors are caught rather than thrown. ox_lib rejects the promise in three
--- cases - the callback is not registered, the handler errored, or it exceeded
--- `ox:callbackTimeout` (5 minutes by default, lower it with
--- `setr ox:callbackTimeout 15000`) - and a rejected promise makes
--- `Citizen.Await` raise. Without the pcall that would kill the calling thread,
--- which in practice means an NUI callback that never calls `cb()` and a tab
--- that spins forever.
---@param name string
---@param ... any arguments passed to the server handler
---@return any ... every value the handler returned
function MDT.callback(name, ...)
    if type(name) ~= 'string' or name == '' then
        MDT.error('MDT.callback called without a callback name')
        return nil
    end

    local results = table.pack(pcall(lib.callback.await, name, false, ...))

    if not results[1] then
        MDT.error(('callback "%s" failed: %s'):format(name, tostring(results[2])))
        return nil
    end

    return table.unpack(results, 2, results.n)
end

-- Asset requests -------------------------------------------------------------

--- Loads a model and waits for it, with a timeout so a bad model cannot hang
--- the calling thread forever.
---
--- Callers pass a name (`'ps-mdt'`) as often as a hash, so normalise first:
--- the natives auto-hash string arguments, but doing it explicitly keeps
--- IsModelValid honest and lets the caller reuse the hash.
---@param model string|number
---@param timeout? number milliseconds, defaults to 15000
---@return boolean loaded
function MDT.requestModel(model, timeout)
    local hash = type(model) == 'string' and joaat(model) or model
    if type(hash) ~= 'number' then
        MDT.warn('requestModel: expected a model name or hash, got', type(model))
        return false
    end

    if HasModelLoaded(hash) then return true end
    if not IsModelValid(hash) then
        MDT.warn('requestModel: invalid model', model)
        return false
    end

    timeout = timeout or 15000
    local deadline = GetGameTimer() + timeout

    RequestModel(hash)
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then
            MDT.warn('requestModel timed out after ' .. timeout .. 'ms:', model)
            return false
        end
        Wait(0)
    end

    return true
end

--- Loads an animation dictionary and waits for it.
---@param dict string
---@param timeout? number milliseconds, defaults to 15000
---@return boolean loaded
function MDT.requestAnim(dict, timeout)
    if HasAnimDictLoaded(dict) then return true end
    if not DoesAnimDictExist(dict) then
        MDT.warn('requestAnim: dictionary does not exist:', dict)
        return false
    end

    timeout = timeout or 15000
    local deadline = GetGameTimer() + timeout

    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        if GetGameTimer() > deadline then
            MDT.warn('requestAnim timed out after ' .. timeout .. 'ms:', dict)
            return false
        end
        Wait(0)
    end

    return true
end

-- Keybinds -------------------------------------------------------------------

--- Maps a key to an already registered command.
--- ps_lib registered a second wrapper command per keybind; mapping the real
--- command directly means the key shows up under the right entry in the GTA
--- key settings and there is one less indirection to debug.
---@param key string e.g. 'F6'
---@param command string the command name, without the leading slash
---@param description? string shown in the GTA key bindings menu
function MDT.addKeybind(key, command, description)
    if not key or not command then
        MDT.warn('addKeybind: key and command are both required')
        return
    end

    RegisterKeyMapping(command, description or ('ps-mdt: ' .. command), 'keyboard', key)
end

-- Sound ----------------------------------------------------------------------

--- Plays a frontend sound. Same shape as ps_lib's PlaySound export.
---@param data { audioName: string|string[], audioRef: string, audioBank?: string }
function MDT.playSound(data)
    if type(data) ~= 'table' or not data.audioName then return end

    local names = type(data.audioName) == 'table' and data.audioName or { data.audioName }

    if data.audioBank then
        local deadline = GetGameTimer() + 500
        while not RequestScriptAudioBank(data.audioBank, false) do
            if GetGameTimer() > deadline then
                MDT.warn('playSound: audio bank failed to load:', data.audioBank)
                return
            end
            Wait(0)
        end
    end

    for i = 1, #names do
        local soundId = GetSoundId()
        PlaySoundFrontend(soundId, names[i], data.audioRef, false)
        ReleaseSoundId(soundId)
    end

    if data.audioBank then
        ReleaseNamedScriptAudioBank(data.audioBank)
    end
end
