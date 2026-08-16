-- ============================================================================
--  phone_tracking.lua  —  court-authorised phone location tracking
-- ----------------------------------------------------------------------------
--  Locating somebody's phone is surveillance, so it is built like a warrant
--  rather than like a lookup: an officer submits a number with a justification,
--  a judge approves or denies it, and only an approved track ever reports a
--  position.
--
--  Approval and execution are separate steps. A judge granting the request
--  does not switch anything on — it hands the officer a warrant they still
--  have to execute, so the track starts when they are actually in a position
--  to act on it. That warrant does not keep: it lapses if it goes unused,
--  because an approval read in the morning should not authorise surveillance
--  that evening.
--
--  Three deliberate limits, all of them in Config.PhoneTracking:
--    * the fix is scattered within an accuracy radius, so it is a rough
--      location and the map can draw the uncertainty rather than a false point
--    * pings are periodic, not live — the default is three of them a minute
--      apart, enough to read a direction of travel and no more
--    * the track expires on its own, so nobody has to remember to stop it
--
--  The number is resolved to a citizen at REQUEST time, never at approval:
--  a judge has to see whose phone they are authorising, not a bare number.
-- ============================================================================

local resourceName = tostring(GetCurrentResourceName())

local function cfg()
    return (Config and Config.PhoneTracking) or {}
end

local function enabled()
    return cfg().Enabled ~= false
end

--- Officer name with callsign, matching how doj.lua labels reviewers.
--- Defined here rather than shared because the one in doj.lua is local to that
--- file — calling it from here is what produced a nil-value error.
---@param src number
---@return string
local function getDisplayName(src)
    local callsign = ps.getMetadata(src, 'callsign')
    local name = ps.getPlayerName(src) or 'Unknown'
    if callsign and callsign ~= '' then
        return callsign .. ' ' .. name
    end
    return name
end

-- QBCore is NOT a global inside server/backend — it has to be pulled from the
-- export, the same way tracking.lua does it. Assuming otherwise is what made
-- every ping fail silently: sourceForCitizen returned nil, no fix was ever
-- recorded, and GetActivePhoneTracks (which only returns tracks that HAVE a
-- fix) handed the map an empty list.
local _qbCore
local function getQBCore()
    if _qbCore then return _qbCore end
    if exports['qb-core'] then
        _qbCore = exports['qb-core']:GetCoreObject()
    end
    return _qbCore
end

---@param citizenid string|nil
---@return number|nil src
local function sourceForCitizen(citizenid)
    if not citizenid or citizenid == '' then return nil end

    local QBCore = getQBCore()
    if QBCore and QBCore.Functions and QBCore.Functions.GetPlayerByCitizenId then
        local ok, player = pcall(QBCore.Functions.GetPlayerByCitizenId, citizenid)
        if ok and player and player.PlayerData then return player.PlayerData.source end
    end

    -- Fallback for cores whose lookup helper is missing or renamed: walk the
    -- player list once. A handful of tracks a minute makes this affordable.
    if QBCore and QBCore.Functions and QBCore.Functions.GetQBPlayers then
        local okAll, players = pcall(QBCore.Functions.GetQBPlayers)
        if okAll and type(players) == 'table' then
            for _, player in pairs(players) do
                local data = player and player.PlayerData
                if data and data.citizenid == citizenid then return data.source end
            end
        end
    end

    return nil
end

-- ── Self-healing schema ──────────────────────────────────────────────────────
-- Same pattern as the rest of the resource: create the tables if the SQL was
-- never run, so a fresh install works without a manual migration step.
CreateThread(function()
    Wait(2500)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `mdt_phone_tracks` (
          `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
          `number` varchar(32) NOT NULL,
          `citizenid` varchar(50) DEFAULT NULL,
          `citizen_name` varchar(100) DEFAULT NULL,
          `requesting_officer` varchar(50) NOT NULL,
          `officer_name` varchar(100) NOT NULL,
          `reason` text NOT NULL,
          `linked_report_id` int(10) unsigned DEFAULT NULL,
          `status` enum('pending','approved','active','completed','denied','cancelled','lapsed') NOT NULL DEFAULT 'pending',
          `reviewer_citizenid` varchar(50) DEFAULT NULL,
          `reviewer_name` varchar(100) DEFAULT NULL,
          `review_reason` text DEFAULT NULL,
          `reviewed_at` timestamp NULL DEFAULT NULL,
          `approval_expires_at` timestamp NULL DEFAULT NULL,
          `started_at` timestamp NULL DEFAULT NULL,
          `expires_at` timestamp NULL DEFAULT NULL,
          `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
          PRIMARY KEY (`id`),
          KEY `status` (`status`),
          KEY `citizenid` (`citizenid`),
          KEY `requesting_officer` (`requesting_officer`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `mdt_phone_track_pings` (
          `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
          `track_id` int(10) unsigned NOT NULL,
          `x` float NOT NULL,
          `y` float NOT NULL,
          `z` float NOT NULL,
          `accuracy` int(10) NOT NULL DEFAULT 150,
          `online` tinyint(1) NOT NULL DEFAULT 1,
          `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
          PRIMARY KEY (`id`),
          KEY `track_id` (`track_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])

    -- Installs from before approval and execution were separated.
    local cols = MySQL.query.await([[
        SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'mdt_phone_tracks'
          AND COLUMN_NAME = 'approval_expires_at'
    ]])
    if not cols or #cols == 0 then
        MySQL.query.await([[
            ALTER TABLE `mdt_phone_tracks`
            MODIFY COLUMN `status` enum('pending','approved','active','completed','denied','cancelled','lapsed') NOT NULL DEFAULT 'pending',
            ADD COLUMN `approval_expires_at` timestamp NULL DEFAULT NULL AFTER `reviewed_at`
        ]])
    end

    -- A restart leaves running tracks behind with no scheduler. Those are dead
    -- either way, so close them. Approvals are deliberately NOT touched: their
    -- window is a database timestamp, so an officer who was granted a warrant
    -- just before the restart still has the rest of it.
    MySQL.update.await([[
        UPDATE mdt_phone_tracks SET status = 'completed' WHERE status = 'active'
    ]])

    -- Surveillance records should not accumulate indefinitely.
    local days = tonumber(cfg().RetentionDays) or 14
    if days > 0 then
        MySQL.query.await([[
            DELETE p FROM mdt_phone_track_pings p
            INNER JOIN mdt_phone_tracks t ON t.id = p.track_id
            WHERE t.created_at < DATE_SUB(NOW(), INTERVAL ? DAY)
        ]], { days })
        MySQL.query.await([[
            DELETE FROM mdt_phone_tracks WHERE created_at < DATE_SUB(NOW(), INTERVAL ? DAY)
        ]], { days })
    end
end)

-- ── Live state ───────────────────────────────────────────────────────────────
-- [trackId] = { id, number, citizenid, citizen_name, expiresAt, ping }
-- `ping` holds ONLY the most recent fix: the newest reading replaces the old
-- one on the map. Every ping is still written to the database, so the history
-- exists for audit even though the map shows one marker.
local activeTracks = {}

local function activeCount()
    local n = 0
    for _ in pairs(activeTracks) do n = n + 1 end
    return n
end

--- Scatter a position within the accuracy radius.
--- Square-rooted so the offset is uniform across the disc rather than clustered
--- in the middle, which would make the fix better than it claims to be.
---@param coords vector3
---@param radius number
---@return table
local function scatter(coords, radius)
    local angle = math.random() * math.pi * 2
    local dist  = math.sqrt(math.random()) * radius
    return {
        x = coords.x + math.cos(angle) * dist,
        y = coords.y + math.sin(angle) * dist,
        z = coords.z,
    }
end

--- Take one reading for a track. Offline phones simply do not report.
---@param track table
local function pingTrack(track)
    local src = sourceForCitizen(track.citizenid)
    if not src then
        -- No signal. The previous fix stays on the map as the last known
        -- position rather than the marker vanishing mid-track.
        track.online = false
        return
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then track.online = false return end

    local coords = GetEntityCoords(ped)
    local accuracy = tonumber(cfg().Accuracy) or 150
    local fix = scatter(coords, accuracy)

    track.online = true
    track.ping = {
        x = fix.x,
        y = fix.y,
        z = fix.z,
        accuracy = accuracy,
        at = os.time(),
    }

    MySQL.insert('INSERT INTO mdt_phone_track_pings (track_id, x, y, z, accuracy, online) VALUES (?, ?, ?, ?, ?, 1)',
        { track.id, fix.x, fix.y, fix.z, accuracy })
end

local function endTrack(trackId, status)
    local track = activeTracks[trackId]
    activeTracks[trackId] = nil
    if not track then return end
    MySQL.update('UPDATE mdt_phone_tracks SET status = ? WHERE id = ?', { status or 'expired', trackId })
end

--- Start the ping schedule for an approved track.
---@param row table  the mdt_phone_tracks row
local function beginTracking(row)
    local duration = tonumber(cfg().Duration) or 180
    local interval = tonumber(cfg().PingInterval) or 60
    if interval < 5 then interval = 5 end

    local track = {
        id           = row.id,
        number       = row.number,
        citizenid    = row.citizenid,
        citizen_name = row.citizen_name,
        officer_name = row.officer_name,
        reason       = row.reason,
        expiresAt    = os.time() + duration,
        online       = false,
        ping         = nil,
    }
    activeTracks[row.id] = track

    MySQL.update([[
        UPDATE mdt_phone_tracks
        SET status = 'active', started_at = NOW(), expires_at = DATE_ADD(NOW(), INTERVAL ? SECOND)
        WHERE id = ?
    ]], { duration, row.id })

    CreateThread(function()
        -- First fix immediately, so approval produces something visible at once.
        pingTrack(track)
        while activeTracks[row.id] do
            Wait(interval * 1000)
            if not activeTracks[row.id] then return end
            if os.time() >= track.expiresAt then
                endTrack(row.id, 'completed')
                return
            end
            pingTrack(track)
        end
    end)
end

-- ── Public read API (used by the map payload) ────────────────────────────────
--- Active tracks with their most recent fix, for officers on the map.
---@return table
function GetActivePhoneTracks()
    local out = {}
    local now = os.time()
    for id, track in pairs(activeTracks) do
        if track.ping then
            out[#out + 1] = {
                id           = id,
                number       = track.number,
                citizen_name = track.citizen_name,
                citizenid    = track.citizenid,
                officer_name = track.officer_name,
                coords       = { x = track.ping.x, y = track.ping.y, z = track.ping.z },
                accuracy     = track.ping.accuracy,
                online       = track.online == true,
                pingedAt     = track.ping.at,
                expiresIn    = math.max(0, track.expiresAt - now),
            }
        end
    end
    return out
end

-- ── Callbacks ────────────────────────────────────────────────────────────────

--- Resolve a number without creating anything, so the officer sees who they are
--- about to request surveillance on before they submit.
ps.registerCallback(resourceName .. ':server:lookupPhoneNumber', function(source, number)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not enabled() then return { success = false, error = 'Phone tracking is disabled' } end
    if not CheckPermission(src, 'phone_track_request') then
        return { success = false, error = 'You are not authorised to request phone tracking' }
    end

    local citizenid, name = PhoneOwnerOf(number)
    if not citizenid then
        return { success = false, error = 'No registered subscriber for that number' }
    end
    return { success = true, citizenid = citizenid, name = name }
end)

ps.registerCallback(resourceName .. ':server:requestPhoneTrack', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not enabled() then return { success = false, error = 'Phone tracking is disabled' } end
    if not CheckPermission(src, 'phone_track_request') then
        return { success = false, error = 'You are not authorised to request phone tracking' }
    end

    payload = payload or {}
    local number = payload.number and tostring(payload.number) or ''
    local reason = payload.reason and tostring(payload.reason) or ''

    if number == '' then return { success = false, error = 'Missing phone number' } end
    if reason == '' then return { success = false, error = 'A justification is required' } end

    local citizenid, name = PhoneOwnerOf(number)
    if not citizenid then
        return { success = false, error = 'No registered subscriber for that number' }
    end

    -- One open request per number: a queue of duplicates in front of a judge is
    -- noise, and approving two of them would start two tracks on one phone.
    local existing = MySQL.single.await([[
        SELECT id FROM mdt_phone_tracks
        WHERE number = ? AND status IN ('pending','approved') LIMIT 1
    ]], { number })
    if existing then
        return { success = false, error = 'There is already an open request for that number' }
    end

    local officerCitizenid = ps.getIdentifier(src)
    local officerName = getDisplayName(src)
    local autoApprove = cfg().RequireApproval == false

    local id = MySQL.insert.await([[
        INSERT INTO mdt_phone_tracks
        (number, citizenid, citizen_name, requesting_officer, officer_name, reason, linked_report_id, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        number, citizenid, name, officerCitizenid, officerName, reason,
        payload.linked_report_id and tonumber(payload.linked_report_id) or nil,
        autoApprove and 'approved' or 'pending',
    })

    if not id then return { success = false, error = 'Failed to create request' } end

    if ps.auditLog then
        ps.auditLog(src, 'phone_track_requested', 'phone_track', id, {
            number = number, citizenid = citizenid, auto_approved = autoApprove,
        })
    end

    -- With approval switched off the request is granted immediately, but the
    -- officer still executes it — the warrant is skipped, not the trigger.
    if autoApprove then
        local validFor = tonumber(cfg().ApprovalValidFor) or 7200
        MySQL.update.await([[
            UPDATE mdt_phone_tracks
            SET reviewed_at = NOW(), approval_expires_at = DATE_ADD(NOW(), INTERVAL ? SECOND)
            WHERE id = ?
        ]], { validFor, id })
    end

    return { success = true, id = id, citizenid = citizenid, name = name, pending = not autoApprove }
end)

ps.registerCallback(resourceName .. ':server:reviewPhoneTrack', function(source, track_id, decision, reason)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'phone_track_review') then
        return { success = false, error = 'You are not authorised to review tracking requests' }
    end

    track_id = tonumber(track_id)
    if not track_id then return { success = false, error = 'Invalid request id' } end
    if decision ~= 'approved' and decision ~= 'denied' then
        return { success = false, error = 'Invalid decision' }
    end

    local row = MySQL.single.await('SELECT * FROM mdt_phone_tracks WHERE id = ? AND status = ?', { track_id, 'pending' })
    if not row then return { success = false, error = 'Request not found or already reviewed' } end

    local reviewerCitizenid = ps.getIdentifier(src)
    local reviewerName = getDisplayName(src)

    -- Approval grants a warrant with a shelf life; it does not switch anything
    -- on. The officer executes it themselves, and only within this window.
    local validFor = tonumber(cfg().ApprovalValidFor) or 7200

    MySQL.update.await([[
        UPDATE mdt_phone_tracks
        SET status = ?, reviewer_citizenid = ?, reviewer_name = ?, review_reason = ?, reviewed_at = NOW(),
            approval_expires_at = CASE WHEN ? = 'approved' THEN DATE_ADD(NOW(), INTERVAL ? SECOND) ELSE NULL END
        WHERE id = ?
    ]], { decision, reviewerCitizenid, reviewerName, reason or '', decision, validFor, track_id })

    if ps.auditLog then
        ps.auditLog(src, 'phone_track_' .. decision, 'phone_track', track_id, {
            number = row.number, citizenid = row.citizenid, reason = reason or '',
        })
    end

    return { success = true, validFor = decision == 'approved' and validFor or nil }
end)

--- Cancel a running or pending track early. The requesting officer may pull
--- their own; a reviewer may pull anyone's.
ps.registerCallback(resourceName .. ':server:cancelPhoneTrack', function(source, track_id)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end

    track_id = tonumber(track_id)
    if not track_id then return { success = false, error = 'Invalid request id' } end

    local row = MySQL.single.await([[
        SELECT * FROM mdt_phone_tracks WHERE id = ? AND status IN ('pending','approved','active')
    ]], { track_id })
    if not row then return { success = false, error = 'Track not found or already closed' } end

    local mine = row.requesting_officer == ps.getIdentifier(src)
    if not mine and not CheckPermission(src, 'phone_track_review') then
        return { success = false, error = 'You cannot cancel another officer\'s request' }
    end

    if activeTracks[track_id] then
        endTrack(track_id, 'cancelled')
    else
        MySQL.update.await('UPDATE mdt_phone_tracks SET status = ? WHERE id = ?', { 'cancelled', track_id })
    end

    if ps.auditLog then
        ps.auditLog(src, 'phone_track_cancelled', 'phone_track', track_id, { number = row.number })
    end

    return { success = true }
end)

--- Execute an approved warrant. This is the trigger the officer pulls, and the
--- only place a track ever starts.
ps.registerCallback(resourceName .. ':server:startPhoneTrack', function(source, track_id)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not enabled() then return { success = false, error = 'Phone tracking is disabled' } end
    if not CheckPermission(src, 'phone_track_request') then
        return { success = false, error = 'You are not authorised to run phone tracking' }
    end

    track_id = tonumber(track_id)
    if not track_id then return { success = false, error = 'Invalid request id' } end

    local row = MySQL.single.await('SELECT * FROM mdt_phone_tracks WHERE id = ? AND status = ?', { track_id, 'approved' })
    if not row then return { success = false, error = 'No approved warrant for that request' } end

    -- Only the officer who asked for it. A warrant is granted to a person on
    -- the strength of their justification, not to the department at large.
    if row.requesting_officer ~= ps.getIdentifier(src) then
        return { success = false, error = 'This warrant was granted to another officer' }
    end

    -- The window is enforced here rather than trusted from the sweeper below,
    -- so a track can never start on a warrant that expired seconds ago.
    local left = MySQL.scalar.await(
        'SELECT TIMESTAMPDIFF(SECOND, NOW(), approval_expires_at) FROM mdt_phone_tracks WHERE id = ?', { track_id })
    if left == nil or tonumber(left) == nil or tonumber(left) <= 0 then
        MySQL.update.await('UPDATE mdt_phone_tracks SET status = ? WHERE id = ?', { 'lapsed', track_id })
        return { success = false, error = 'The approval has expired — submit a new request' }
    end

    if activeTracks[track_id] then return { success = false, error = 'That track is already running' } end

    -- Probe before committing. A handset that is off answers nothing, and
    -- burning a two-hour warrant on three minutes of silence is the worst
    -- possible outcome — so the attempt is aborted and the warrant stays
    -- approved for another go later in its window.
    if not sourceForCitizen(row.citizenid) then
        return {
            success = false,
            aborted = true,
            error = 'No handset responding on that number. The device is powered off or outside coverage — your warrant is still valid, try again.',
        }
    end

    -- The cap is about how many phones are being watched right now, which is
    -- why it is checked at execution and not at approval.
    local max = tonumber(cfg().MaxActive) or 3
    if activeCount() >= max then
        return { success = false, error = ('Too many tracks are already running (%d)'):format(max) }
    end

    beginTracking(row)

    if ps.auditLog then
        ps.auditLog(src, 'phone_track_started', 'phone_track', track_id, {
            number = row.number, citizenid = row.citizenid,
        })
    end

    return { success = true, duration = tonumber(cfg().Duration) or 180 }
end)

-- ── Unused approvals lapse ───────────────────────────────────────────────────
-- A granted warrant that is never executed has to stop being a granted warrant,
-- otherwise it sits in the officer's list looking usable forever.
CreateThread(function()
    while true do
        Wait(60000)
        MySQL.update([[
            UPDATE mdt_phone_tracks SET status = 'lapsed'
            WHERE status = 'approved' AND approval_expires_at IS NOT NULL AND approval_expires_at <= NOW()
        ]])
    end
end)

--- Pending requests, for the judge's review queue.
ps.registerCallback(resourceName .. ':server:getPhoneTrackRequests', function(source)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'phone_track_review') then
        return { success = false, error = 'Unauthorized' }
    end

    local pending = MySQL.query.await([[
        SELECT * FROM mdt_phone_tracks WHERE status = 'pending' ORDER BY created_at ASC
    ]]) or {}
    local recent = MySQL.query.await([[
        SELECT * FROM mdt_phone_tracks WHERE status <> 'pending'
        ORDER BY COALESCE(reviewed_at, created_at) DESC LIMIT 25
    ]]) or {}

    return { success = true, pending = pending, recent = recent }
end)

--- Everything the requesting side needs: this officer's own requests plus the
--- tracks currently running.
ps.registerCallback(resourceName .. ':server:getPhoneTracks', function(source)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'phone_track_request') then
        return { success = false, error = 'Unauthorized' }
    end

    -- approval_seconds_left is what the UI needs to show a countdown on the
    -- execute button; computing it in SQL keeps it honest against the DB clock
    -- rather than against whenever the client last refreshed.
    local mine = MySQL.query.await([[
        SELECT *,
               CASE WHEN status = 'approved' AND approval_expires_at IS NOT NULL
                    THEN GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(), approval_expires_at))
                    ELSE NULL END AS approval_seconds_left
        FROM mdt_phone_tracks WHERE requesting_officer = ?
        ORDER BY created_at DESC LIMIT 25
    ]], { ps.getIdentifier(src) }) or {}

    return { success = true, mine = mine, active = GetActivePhoneTracks() }
end)