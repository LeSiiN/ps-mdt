-- ============================================================================
--  preferences.lua (client)  —  mirror of NUI-stored player preferences
-- ----------------------------------------------------------------------------
--  Preferences live in the NUI's localStorage (Settings tab). Lua code can't
--  read localStorage, so the Settings page pushes a small bundle over one NUI
--  callback — on resource start (requested below), whenever the player saves,
--  and whenever the Settings component answers the request.
--
--  Consumers read through MdtPref(name, default). Until the first push
--  arrives the given default applies, mirroring the NUI's own defaults.
--  (patrolZonePref and autoStatusPref predate this bundle and keep their own
--  channels in tracking.lua / auto_status.lua.)
-- ============================================================================

local resourceName = tostring(GetCurrentResourceName())

local prefs = {}

AddEventHandler('onClientResourceStart', function(res)
    if res ~= resourceName then return end
    SendNUIMessage({ type = 'requestClientPrefs' })
end)

-- Preferences the SERVER has to know about, because the decision they affect
-- is made there. Everything else stays client-local.
local SERVER_PREFS = { 'plateCheckAlerts', 'plateCheckIgnoreImpounds', 'plateCheckCriticalOnly' }

local lastServerPush = nil

--- Forward the server-side subset, but only when it actually changed. The
--- NUI re-pushes the whole bundle on every save and on resource start, and
--- an unconditional relay would put an avoidable event on the wire each time.
local function syncServerPrefs()
    local payload, signature = {}, {}
    for _, name in ipairs(SERVER_PREFS) do
        local value = prefs[name]
        if value ~= nil then
            payload[name] = value
            signature[#signature + 1] = name .. '=' .. tostring(value)
        end
    end
    if #signature == 0 then return end

    local joined = table.concat(signature, ',')
    if joined == lastServerPush then return end
    lastServerPush = joined
    TriggerServerEvent('ps-mdt:server:setClientPrefs', payload)
end

RegisterNUICallback('clientPrefs', function(data, cb)
    if type(data) == 'table' then
        for k, v in pairs(data) do
            if type(k) == 'string' and (type(v) == 'boolean' or type(v) == 'number') then
                prefs[k] = v
            end
        end
        syncServerPrefs()
    end
    cb({})
end)

--- Read a mirrored preference; `default` applies until the NUI has pushed.
---@param name string
---@param default boolean|number
---@return boolean|number
function MdtPref(name, default)
    local v = prefs[name]
    if v == nil then return default end
    return v
end
