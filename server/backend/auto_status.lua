-- ============================================================================
--  auto_status.lua  —  automatic officer status from the dispatch lifecycle
-- ----------------------------------------------------------------------------
--  Attach to a call        -> EnRouteStatus   (e.g. 'enroute')
--  Arrive at call coords   -> OnSceneStatus   (e.g. 'onscene')
--  Detach / call dismissed -> RevertStatus    (e.g. 'active')
--
--  Design rules (the fallbacks):
--    * The automation only ever REPLACES statuses listed in Auto.Overridable.
--      An officer on a deliberate away-state (break/training/unavailable) is
--      never touched — assigning them leaves their status as-is and the
--      automation stays hands-off for that call.
--    * A manual status change while engaged disengages the automation for
--      that officer (officer_status.lua calls AutoStatusManualOverride).
--      The manual choice is never overwritten afterwards.
--    * Reverting only happens if the officer's status is still the one the
--      automation set (enroute/onscene). Anything else is left alone.
--    * One engagement per officer: being assigned to a second call moves the
--      engagement (status flips back to en route for the new call).
--    * Disconnect clears the engagement but keeps the status, mirroring
--      officer_status.lua's playerDropped philosophy.
--    * Failsafe sweep: provider calls can expire without any close event ever
--      reaching the MDT. Engagements older than MaxEngagementMinutes revert.
--
--  All writes go through AutoSetOfficerStatus (officer_status.lua), so memory,
--  DB, domain broadcast and audit log behave exactly like a manual change.
-- ============================================================================

local resourceName = tostring(GetCurrentResourceName())

local auto = (Config.OfficerStatus and Config.OfficerStatus.Auto) or {}
local enabled = auto.Enabled == true

-- ─── Config validation ───────────────────────────────────────────────────────
-- A typo'd status id would make every transition a silent no-op; disable the
-- whole feature loudly instead so it's obvious from the console.
local knownIds = {}
for _, s in ipairs((Config.OfficerStatus and Config.OfficerStatus.list) or {}) do
    knownIds[s.id] = true
end
local EN_ROUTE = auto.EnRouteStatus or 'enroute'
local ON_SCENE = auto.OnSceneStatus or 'onscene'
local REVERT   = auto.RevertStatus  or 'active'
if enabled and not (knownIds[EN_ROUTE] and knownIds[ON_SCENE] and knownIds[REVERT]) then
    print('^1[MDT]^7 Config.OfficerStatus.Auto references a status id that is not in '
        .. 'Config.OfficerStatus.list — automatic dispatch statuses are DISABLED.')
    enabled = false
end

local overridable = {}
for _, id in ipairs(auto.Overridable or {}) do overridable[id] = true end
-- The automation's own statuses must always be replaceable by itself,
-- otherwise a re-assignment while on scene could never flip back to en route.
overridable[EN_ROUTE] = true
overridable[ON_SCENE] = true

local onSceneRadius = tonumber(auto.OnSceneRadius) or 75.0
local maxEngageMs   = (tonumber(auto.MaxEngagementMinutes) or 0) * 60 * 1000

-- Status labels for the note. The Map popup renders the note INSTEAD of the
-- status label when one is set, so the note carries both: "En Route ● 10-17".
local statusLabels = {}
for _, s in ipairs((Config.OfficerStatus and Config.OfficerStatus.list) or {}) do
    statusLabels[s.id] = s.label
end

-- "En Route | 10-17" / "On Scene | 10-17"; nil when the call has no code —
-- then the plain status label shows by itself, same as a manual change.
local function callNote(statusId, code)
    if not code then return nil end
    return ('%s | %s'):format(statusLabels[statusId] or statusId, code)
end

-- Optional notify to the affected officer on every automatic transition.
-- Always sent — the CLIENT decides whether to show it, based on the
-- "Automatic Status Notifications" toggle in the MDT preferences tab
-- (same pattern as the patrol zone notifications).
local function notifyClient(src, statusId, code, suffix)
    if not src then return end
    local label = statusLabels[statusId] or statusId
    local text = code and ('%s | %s'):format(label, code) or label
    if suffix then text = ('%s — %s'):format(text, suffix) end
    TriggerClientEvent(resourceName .. ':client:autoStatusNotify', src, { text = 'Status updated: ' .. text })
end

-- The code travels from the client (provider calls only exist there); keep it
-- boring before it ends up in notes/audit: single line, trimmed, short.
local function sanitizeCode(code)
    if type(code) ~= 'string' then return nil end
    code = code:gsub('[%c\r\n]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if code == '' then return nil end
    return code:sub(1, 24)
end

local function dbg(...)
    if Config.Debug then print('[MDT:autostatus]', ...) end
end

-- ─── State ───────────────────────────────────────────────────────────────────
-- One engagement per officer. src is refreshed on every event from that player
-- so it survives reconnects (playerDropped clears the entry anyway).
-- [citizenid] = { dispatchId, coords = {x, y} | nil, src, phase, engagedAt }
local engagements = {}

local function citizenidOf(src)
    return ps.getIdentifier and ps.getIdentifier(src) or nil
end

-- Stop the arrival watcher on the officer's client (safe if none is running).
local function stopWatch(src)
    if src then TriggerClientEvent(resourceName .. ':client:autoStatusWatch', src, false) end
end

-- Revert an engagement's officer back to REVERT — but only if their current
-- status is still one the automation set. A status changed by anything else
-- in the meantime is respected and left untouched.
local function revertAndClear(citizenid, reasonLabel)
    local eng = engagements[citizenid]
    if not eng then return end
    engagements[citizenid] = nil
    stopWatch(eng.src)

    local current = GetOfficerStatusId and GetOfficerStatusId(citizenid) or nil
    if current == EN_ROUTE or current == ON_SCENE then
        AutoSetOfficerStatus(eng.src, REVERT, nil, reasonLabel)
        notifyClient(eng.src, REVERT, nil, reasonLabel)
    end
end

-- ─── Manual override (called by officer_status.lua) ─────────────────────────
-- The officer picked a status themselves: hands off. Clear the engagement and
-- stop the arrival watcher WITHOUT reverting anything.
function AutoStatusManualOverride(citizenid)
    local eng = citizenid and engagements[citizenid]
    if not eng then return end
    engagements[citizenid] = nil
    stopWatch(eng.src)
    dbg('manual override, disengaged', citizenid)
end

-- ─── Call closed (called by dashboard.lua's dismissDispatch) ─────────────────
function AutoStatusCallClosed(dispatchId)
    if not enabled then return end
    dispatchId = tostring(dispatchId)
    for citizenid, eng in pairs(engagements) do
        if eng.dispatchId == dispatchId then
            revertAndClear(citizenid, 'call closed')
        end
    end
end

-- ─── Attach / detach (fired by the assigned officer's client) ────────────────
-- Every attach path in the MDT — self-attach on provider calls, self-attach on
-- manual calls, and dispatcher drag-assign — ends up running on the assigned
-- player's client (see dashboard.lua), so a single client-side funnel covers
-- them all. coords may be nil (call without a location): the officer still
-- goes en route, there's just no arrival detection — detach/close/manual
-- remain as the ways back.
RegisterNetEvent(resourceName .. ':server:autoStatusEngage', function(dispatchId, coords)
    if not enabled then return end
    local src = source
    if not CheckAuth(src) then return end
    dispatchId = dispatchId and tostring(dispatchId) or nil
    if not dispatchId then return end
    local citizenid = citizenidOf(src)
    if not citizenid then return end

    -- Respect deliberate away-states: if the current status isn't overridable,
    -- the automation stays completely hands-off for this call.
    local current = GetOfficerStatusId(citizenid)
    if not overridable[current] then
        dbg(('not engaging %s: status "%s" is not overridable'):format(citizenid, current))
        return
    end

    -- Client-passed coords are just the fast path (dispatcher assigns carry
    -- them); code and any missing coords are resolved server-side from the
    -- cached dispatch list, which covers provider AND MDT-created calls.
    -- The 10-code therefore never comes from the client at all.
    local x = coords and tonumber(coords.x)
    local y = coords and tonumber(coords.y)
    local info = GetDispatchInfoById and GetDispatchInfoById(dispatchId) or nil
    local code = sanitizeCode(info and info.code)
    if not (x and y) and info and info.coords then
        x = tonumber(info.coords.x)
        y = tonumber(info.coords.y)
    end

    -- Re-assignment moves the engagement; make sure an old watcher dies first.
    if engagements[citizenid] then stopWatch(engagements[citizenid].src) end
    engagements[citizenid] = {
        dispatchId = dispatchId,
        coords     = (x and y) and { x = x, y = y } or nil,
        code       = code,
        src        = src,
        phase      = 'enroute',
        engagedAt  = GetGameTimer(),
    }

    AutoSetOfficerStatus(src, EN_ROUTE, callNote(EN_ROUTE, code), 'assigned to call')
    notifyClient(src, EN_ROUTE, code)

    if x and y then
        TriggerClientEvent(resourceName .. ':client:autoStatusWatch', src, {
            id = dispatchId, x = x, y = y,
        })
    end
end)

RegisterNetEvent(resourceName .. ':server:autoStatusDisengage', function(dispatchId)
    if not enabled then return end
    local src = source
    if not CheckAuth(src) then return end
    local citizenid = citizenidOf(src)
    local eng = citizenid and engagements[citizenid]
    -- Only react to a detach from the call we're actually tracking — detaching
    -- from some other call must not revert the current engagement.
    if not eng or eng.dispatchId ~= tostring(dispatchId) then return end
    eng.src = src
    revertAndClear(citizenid, 'detached from call')
end)

-- ─── Arrival ─────────────────────────────────────────────────────────────────
-- The client watcher reports proximity; the server double-checks the distance
-- against the coords stored at engage time (generous tolerance — the ped is
-- moving and the client check already passed), so a spoofed event can't flip
-- an officer on the other side of the map to On Scene.
RegisterNetEvent(resourceName .. ':server:autoStatusArrived', function(dispatchId)
    if not enabled then return end
    local src = source
    if not CheckAuth(src) then return end
    local citizenid = citizenidOf(src)
    local eng = citizenid and engagements[citizenid]
    if not eng or eng.dispatchId ~= tostring(dispatchId) or eng.phase ~= 'enroute' then return end

    if eng.coords then
        local ped = GetPlayerPed(src)
        local pos = ped and ped ~= 0 and GetEntityCoords(ped) or nil
        if pos then
            local dx, dy = pos.x - eng.coords.x, pos.y - eng.coords.y
            if (dx * dx + dy * dy) > (onSceneRadius * 2) ^ 2 then
                dbg(('arrival from %s rejected: too far from call'):format(citizenid))
                return
            end
        end
    end

    eng.phase = 'onscene'
    eng.src = src
    AutoSetOfficerStatus(src, ON_SCENE, callNote(ON_SCENE, eng.code), 'arrived on scene')
    notifyClient(src, ON_SCENE, eng.code)
end)

-- ─── Failsafe sweep ──────────────────────────────────────────────────────────
if enabled and maxEngageMs > 0 then
    CreateThread(function()
        while true do
            Wait(60000)
            local now = GetGameTimer()
            for citizenid, eng in pairs(engagements) do
                if (now - eng.engagedAt) > maxEngageMs then
                    dbg('engagement expired for', citizenid)
                    revertAndClear(citizenid, 'call expired')
                end
            end
        end
    end)
end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────
AddEventHandler('playerDropped', function()
    local src = source
    -- Match by src, not identifier — the player object may already be gone.
    -- Keep the status (same philosophy as officer_status.lua: a crash or
    -- quick reconnect shouldn't silently flip anyone to Available), just
    -- forget the engagement so nothing fires against a stale src.
    for citizenid, eng in pairs(engagements) do
        if eng.src == src then
            engagements[citizenid] = nil
            break
        end
    end
end)