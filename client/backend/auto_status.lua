-- ============================================================================
--  auto_status.lua (client)  —  arrival watcher for automatic dispatch statuses
-- ----------------------------------------------------------------------------
--  Two jobs:
--    1. AutoStatusClientEngage/Disengage — the single funnel every attach and
--       detach path in dashboard.lua calls into. Looks up the call's coords
--       from the recent-dispatch list and informs the server. All the actual
--       decisions (overridable? already engaged? which status?) live server-
--       side, so a modified client can't do anything a status picker couldn't.
--    2. The arrival watcher: while the server says "you're en route to X at
--       (x, y)", poll the ped's 2D distance and report arrival once inside
--       Config.OfficerStatus.Auto.OnSceneRadius. Runs independently of the
--       NUI — arrival must trigger while the officer is driving, MDT closed.
-- ============================================================================

local resourceName = tostring(GetCurrentResourceName())

local auto = (Config.OfficerStatus and Config.OfficerStatus.Auto) or {}
local radius  = tonumber(auto.OnSceneRadius) or 75.0
local checkMs = tonumber(auto.ArrivalCheckMs) or 2500

-- Only one watch at a time (one engagement per officer, enforced server-side).
-- The token invalidates a running loop the moment a new watch starts or the
-- current one is stopped, so stale threads can never report an old call.
local watch = nil        -- { id, x, y }
local watchToken = 0

-- Called from every attach path in dashboard.lua (self-attach, manual-call
-- attach, dispatcher assign). Pure fire-and-forget: NO blocking list lookup
-- here — ps_lib callbacks are name-keyed and a concurrent GetRecentDispatch
-- (e.g. the NUI's own list refresh during an attach) would deadlock one
-- caller into a 10s NUI timeout. The server resolves the call's code and
-- coords itself from its cached dispatch list (GetDispatchInfoById); coords
-- are only passed through when the caller already has them (dispatcher
-- assigns), as the more precise fast path.
function AutoStatusClientEngage(id, coords)
    if auto.Enabled ~= true or not id then return end
    local x = coords and (tonumber(coords.x) or tonumber(coords[1]))
    local y = coords and (tonumber(coords.y) or tonumber(coords[2]))
    TriggerServerEvent(resourceName .. ':server:autoStatusEngage', tostring(id),
        (x and y) and { x = x, y = y } or nil)
end

function AutoStatusClientDisengage(id)
    if auto.Enabled ~= true or not id then return end
    TriggerServerEvent(resourceName .. ':server:autoStatusDisengage', tostring(id))
end

-- ─── "Automatic Status Notifications" preference ─────────────────────────────
-- Stored in the NUI's localStorage (MDT preferences tab) and mirrored here,
-- same request/callback pattern as the patrol zone notifications in
-- tracking.lua. Defaults to enabled until the NUI reports otherwise.
local autoStatusNotifyEnabled = true

AddEventHandler('onClientResourceStart', function(res)
    if res ~= resourceName then return end
    SendNUIMessage({ type = 'requestAutoStatusPref' })
end)

RegisterNUICallback('autoStatusPref', function(data, cb)
    if type(data) == 'table' and type(data.enabled) == 'boolean' then
        autoStatusNotifyEnabled = data.enabled
    end
    cb({})
end)

-- One notify per automatic transition ("Status updated: En Route | 10-66").
-- The server always sends; this preference only controls whether it's shown.
RegisterNetEvent(resourceName .. ':client:autoStatusNotify', function(data)
    if not autoStatusNotifyEnabled then return end
    local text = type(data) == 'table' and type(data.text) == 'string' and data.text or nil
    if text and text ~= '' then ps.notify(text, 'inform') end
end)

-- Server-driven watch control: a table starts (or replaces) the watcher,
-- anything falsy stops it. Only the server starts watches, and only after it
-- actually engaged the automation — so no watch runs for an officer whose
-- status was left alone (e.g. on break).
RegisterNetEvent(resourceName .. ':client:autoStatusWatch', function(data)
    watchToken = watchToken + 1
    if type(data) ~= 'table' or not data.id or not data.x or not data.y then
        watch = nil
        return
    end
    watch = { id = tostring(data.id), x = data.x + 0.0, y = data.y + 0.0 }

    local token = watchToken
    CreateThread(function()
        while watch and watchToken == token do
            local ped = PlayerPedId()
            if ped and ped ~= 0 then
                local pos = GetEntityCoords(ped)
                local dx, dy = pos.x - watch.x, pos.y - watch.y
                if (dx * dx + dy * dy) <= (radius * radius) then
                    TriggerServerEvent(resourceName .. ':server:autoStatusArrived', watch.id)
                    watch = nil
                    return
                end
            end
            Wait(checkMs)
        end
    end)
end)