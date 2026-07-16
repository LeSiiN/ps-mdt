-- ============================================================================
--  officer_status.lua  —  MDT officer availability status (client side)
-- ----------------------------------------------------------------------------
--  Responsibilities:
--    * Forwards the static status config (ids/labels/colors from
--      Config.OfficerStatus) to the NUI once on Map mount.
--    * Forwards the local officer's own status changes to the server.
--    * Relays real-time status broadcasts from the server straight into the
--      NUI via SendNUIMessage, mirroring the syncPatrols pattern already used
--      for patrol updates — no polling involved, the Map tab updates the
--      instant any officer in the same domain changes their status.
--
--  This file is intentionally separate from tracking.lua: it owns nothing
--  tracking.lua already owns (no shared state), so it can be dropped or
--  swapped out without touching patrol/vehicle tracking at all.
-- ============================================================================

local resourceName = tostring(GetCurrentResourceName())

-- ─── NUI → Server ───────────────────────────────────────────────────────────

RegisterNUICallback("getOfficerStatusConfig", function(_, cb)
    local result = ps.callback(resourceName .. ":server:getOfficerStatusConfig")
    cb(result or { statuses = {}, default = "active" })
end)

RegisterNUICallback("getOfficerStatusBreakdown", function(_, cb)
    if not MDTOpen then cb({ total = 0, statuses = {} }) return end
    local result = ps.callback(resourceName .. ":server:getOfficerStatusBreakdown")
    cb(result or { total = 0, statuses = {} })
end)

RegisterNUICallback("setOfficerStatus", function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    if type(data) ~= "table" or type(data.status) ~= "string" then
        cb({ success = false }) return
    end
    local note = type(data.note) == "string" and data.note or nil
    TriggerServerEvent(resourceName .. ":server:setOfficerStatus", data.status, note)
    cb({ success = true })
end)

-- ─── Server → NUI ───────────────────────────────────────────────────────────
-- Pushed by officer_status.lua on the server every time ANY officer in this
-- player's domain (police vs ems) changes status. The NUI patches just that
-- one officer's row/marker instead of re-fetching the whole tracking list.

RegisterNetEvent(resourceName .. ":client:syncOfficerStatus", function(payload)
    SendNUIMessage({ type = "syncOfficerStatus", data = payload })
end)

-- ─── /mdtstatus command ─────────────────────────────────────────────────────────
-- Fires the exact same server event as the Map tab's status picker, so all
-- validation (auth, valid id, cooldown), persistence, broadcasting, audit
-- logging AND the manual-override disengage of the dispatch automation apply
-- identically. The server stays authoritative; a non-officer triggering the
-- command is silently rejected there, same as any spoofed NUI call.
-- Deliberately NO RegisterKeyMapping (that would dump one entry per status
-- into everyone's GTA key-binding settings) — players bind the command with
-- args themselves via the F8 console, e.g.: bind keyboard F5 "status enroute"

local statusCmd = (Config.Commands and Config.Commands.Status) or nil
if statusCmd and statusCmd.enabled then
    local list       = (Config.OfficerStatus and Config.OfficerStatus.list) or {}
    local cooldownMs = (Config.OfficerStatus and Config.OfficerStatus.ChangeCooldownMs) or 1500

    -- Accept the id ('enroute') and, as a convenience, a single-word label
    -- ('busy', 'training') — ids stay the documented form.
    local byKey = {}
    for _, s in ipairs(list) do
        byKey[s.id:lower()] = s
        byKey[s.label:lower()] = s
    end

    local function validIdsText()
        local ids = {}
        for _, s in ipairs(list) do ids[#ids + 1] = s.id end
        return table.concat(ids, ', ')
    end

    -- Mirrors the server's per-player cooldown so a mashed keybind gets a
    -- clear message instead of being silently dropped server-side.
    local lastSent = 0
    local function requestStatus(entry, note)
        local now = GetGameTimer()
        if (now - lastSent) < cooldownMs then
            ps.notify('Please wait a moment before changing status again', 'error')
            return
        end
        lastSent = now
        TriggerServerEvent(resourceName .. ':server:setOfficerStatus', entry.id, note)
        ps.notify(('Status set to %s%s'):format(entry.label, note and (' — ' .. note) or ''), 'success')
    end

    RegisterCommand(statusCmd.command, function(_, args)
        local key = args[1] and args[1]:lower() or nil
        if not key then
            ps.notify(('Usage: /%s <%s> [note]'):format(statusCmd.command, validIdsText()), 'inform')
            return
        end
        local entry = byKey[key]
        if not entry then
            ps.notify(('Unknown status "%s". Valid: %s'):format(key, validIdsText()), 'error')
            return
        end
        -- Everything after the status becomes the optional note ("Traffic Stop").
        local note = #args > 1 and table.concat(args, ' ', 2) or nil
        requestStatus(entry, note)
    end, false)

    TriggerEvent('chat:addSuggestion', '/' .. statusCmd.command, 'Set your MDT availability status', {
        { name = 'status', help = validIdsText() },
        { name = 'note',   help = 'Optional note, e.g. Traffic Stop' },
    })
end
