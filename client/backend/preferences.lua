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

RegisterNUICallback('clientPrefs', function(data, cb)
    if type(data) == 'table' then
        for k, v in pairs(data) do
            if type(k) == 'string' and (type(v) == 'boolean' or type(v) == 'number') then
                prefs[k] = v
            end
        end
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
