-- ─────────────────────────────────────────────────────────────────────────────
-- Impound
--
-- Vehicles are impounded by plate: player_vehicles.state goes to 2 and a row is
-- written to mdt_impound. Unlike the old version, releasing does NOT delete the
-- row — it flips status to 'released', so every vehicle keeps a full impound
-- history.
--
-- Releasing works from anywhere and simply puts the vehicle back into the
-- owner's garage (state 1) — they retrieve it there like any other car. No
-- spawning, no lot logistics.
-- ─────────────────────────────────────────────────────────────────────────────

local resourceName = tostring(GetCurrentResourceName())

local function impoundCfg()
    return (Config and Config.Impound) or {}
end

local function getLot(lotId)
    for _, lot in ipairs(impoundCfg().Lots or {}) do
        if lot.id == lotId then return lot end
    end
    return nil
end

local function defaultLotId()
    local lots = impoundCfg().Lots or {}
    return lots[1] and lots[1].id or nil
end

-- oxmysql hands TINYINT(1) back as a boolean, not the number 1. Comparing against
-- 1 silently inverted both fee checks: releases were blocked despite payment, and
-- the "already paid" guard never fired, so owners could be charged repeatedly.
local function isTruthy(v)
    return v == true or v == 1 or v == '1'
end

-- ── Owner e-mails ────────────────────────────────────────────────────────────
-- The owner is almost never standing next to the car when it gets impounded, and
-- may well be offline. An on-screen notification they never see is worse than
-- useless, so they get an e-mail instead — it waits for them.

local function mailOwner(citizenid, subject, body)
    if not citizenid then return end
    if not impoundCfg().NotifyOwner then return end
    if not SendCitizenMail then return end

    SendCitizenMail(
        citizenid,
        impoundCfg().MailSender or 'Vehicle Impound Unit',
        subject,
        body
    )
end

-- ── Hold periods ─────────────────────────────────────────────────────────────
-- How long the vehicle stays put before it may be released at all. Independent of
-- the fee: paying up doesn't shorten a hold, and a hold expiring doesn't waive the
-- fee. Only an officer with the override permission can cut a hold short.

local function getDuration(id)
    for _, d in ipairs(impoundCfg().Durations or {}) do
        if d.id == id then return d end
    end
    return nil
end

local function defaultDuration()
    return getDuration(impoundCfg().DefaultDuration or 'immediate')
        or (impoundCfg().Durations or {})[1]
end

--- Turn a configured duration into what actually gets stored.
--- @return string holdType, number|nil holdUntil, string|nil holdLabel
local function resolveHold(id)
    local d = getDuration(id) or defaultDuration()
    if not d then return 'immediate', nil, nil end

    if d.days == nil then
        return 'indefinite', nil, d.label
    end
    if (d.days or 0) <= 0 then
        return 'immediate', nil, d.label
    end
    return 'timed', os.time() + (d.days * 86400), d.label
end

--- Is this vehicle allowed out yet?
--- @return boolean releasable, string|nil reasonItIsNot
local function holdStatus(row)
    local t = row.hold_type or 'immediate'
    if t == 'indefinite' then
        return false, 'This vehicle is held until an officer authorises its release'
    end
    if t == 'timed' then
        local until_ = tonumber(row.hold_until) or 0
        if os.time() < until_ then
            local left = until_ - os.time()
            local days = math.floor(left / 86400)
            local hours = math.floor((left % 86400) / 3600)
            local when = days > 0
                and ('%d day(s), %d hour(s)'):format(days, hours)
                or ('%d hour(s)'):format(math.max(1, hours))
            return false, ('This vehicle is held for another %s'):format(when)
        end
    end
    return true, nil
end

-- Attach the hold state to a row on read, so the UI doesn't have to work it out.
local function decorateHold(r)
    local releasable, why = holdStatus(r)
    r.hold_releasable = releasable
    r.hold_reason = why
    if r.hold_type == 'timed' and r.hold_until then
        r.hold_seconds_left = math.max(0, (tonumber(r.hold_until) or 0) - os.time())
    else
        r.hold_seconds_left = 0
    end
end

-- ── Storage fee ──────────────────────────────────────────────────────────────
-- Derived from the impound date rather than accumulated by a timer: that makes it
-- restart-proof, impossible to drift, and correct even for rows written before
-- storage fees existed.
local function storageInfo(impoundedAt)
    local cfg = (impoundCfg().Storage) or {}
    local perDay  = cfg.PerDay or 0
    local maxDays = cfg.MaxDays or 0
    if perDay <= 0 or maxDays <= 0 or not impoundedAt then
        return 0, 0
    end

    local days = math.floor((os.time() - impoundedAt) / 86400)
    if days < 0 then days = 0 end
    local billable = math.min(days, maxDays)
    return billable * perDay, billable
end

-- Total owed = the impound fee plus however much storage has accrued.
local function totalOwed(row)
    local storage = storageInfo(row.time)
    return (row.fee or 0) + storage, storage
end

-- Recovering a vehicle closes its BOLO. 'resolved' is the status the rest of the
-- MDT uses (the enum has no 'recovered'), and the denormalised flag on
-- player_vehicles has to be cleared too or the vehicle list keeps showing a BOLO.
-- Returns true when a BOLO was actually closed.
local function clearVehicleBolo(plate)
    local closed = false
    pcall(function()
        local affected = MySQL.update.await([[
            UPDATE mdt_bolos SET status = 'resolved'
            WHERE type = 'vehicle' AND subject_id = ? AND status = 'active'
        ]], { plate })
        if affected and affected > 0 then
            closed = true
            MySQL.update.await(
                'UPDATE player_vehicles SET mdt_vehicle_boloactive = 0 WHERE plate = ?', { plate })
        end
    end)
    return closed
end

local function cleanPlate(plate)
    if type(plate) ~= 'string' then return nil end
    plate = plate:gsub('%s+', ''):upper()
    return plate ~= '' and plate or nil
end

local function officerInfo(src)
    local cid = ps.getIdentifier and ps.getIdentifier(src) or nil
    local name
    local ok, res = pcall(function()
        return (ps.getCharInfo('firstname', src) or '') .. ' ' .. (ps.getCharInfo('lastname', src) or '')
    end)
    if ok and res then name = res:gsub('^%s+', ''):gsub('%s+$', '') end
    if name == '' then name = nil end
    return cid, (name or ps.getPlayerName(src) or 'Unknown')
end

-- Fetch the active impound row for a vehicle id (or nil).
local function activeImpound(vehicleId)
    return MySQL.single.await([[
        SELECT * FROM mdt_impound
        WHERE vehicleid = ? AND status = 'active'
        ORDER BY id DESC LIMIT 1
    ]], { vehicleId })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Impound a vehicle
-- ─────────────────────────────────────────────────────────────────────────────
-- The impound itself. Shared by the MDT callback and the on-site flow, so both
-- write exactly the same record and enforce exactly the same rules.
local function doImpound(src, payload)
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'vehicle_impound') then
        return { success = false, message = 'Insufficient permissions' }
    end

    payload = payload or {}
    local plate = cleanPlate(payload.plate)
    if not plate then return { success = false, message = 'Missing plate number' } end

    local cfg = impoundCfg()
    local fee = math.floor(tonumber(payload.fee) or cfg.DefaultFee or 0)
    if fee < 0 then fee = 0 end
    local maxFee = cfg.MaxFee or 50000
    if fee > maxFee then
        return { success = false, message = ('Fee exceeds the maximum of $%d'):format(maxFee) }
    end

    local reason = type(payload.reason) == 'string' and payload.reason:sub(1, 100) or nil
    if not reason or reason == '' then
        return { success = false, message = 'An impound reason is required' }
    end
    local notes = type(payload.notes) == 'string' and payload.notes:sub(1, 500) or nil
    if notes == '' then notes = nil end

    local photo = type(payload.photo) == 'string' and payload.photo:sub(1, 255) or nil
    if photo == '' then photo = nil end

    local holdType, holdUntil, holdLabel = resolveHold(payload.duration)

    local lotId = payload.lot and tostring(payload.lot) or defaultLotId()
    if not getLot(lotId) then
        return { success = false, message = 'Unknown impound lot' }
    end

    local linkedReport = tonumber(payload.reportId)

    local vehicle = MySQL.single.await(
        'SELECT id, citizenid, plate, state FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if not vehicle then
        return { success = false, message = 'Vehicle not found' }
    end

    -- From the MDT a vehicle can only be impounded while it sits in a garage.
    -- If it's out in the world it has to be impounded on site, otherwise the DB
    -- would say "impounded" while the car is still driving around.
    if not payload.onSite and vehicle.state ~= 1 then
        return {
            success = false,
            message = 'Vehicle is not in a garage — impound it on site',
        }
    end
    if activeImpound(vehicle.id) then
        return { success = false, message = 'Vehicle is already impounded' }
    end

    local cid, officerName = officerInfo(src)

    MySQL.update.await('UPDATE player_vehicles SET state = 2 WHERE plate = ?', { plate })
    MySQL.insert.await([[
        INSERT INTO mdt_impound
            (vehicleid, status, plate, reason, notes, photo, lot, linkedreport, fee, fee_paid,
             hold_type, hold_until, hold_label,
             officer_citizenid, officer_name, time)
        VALUES (?, 'active', ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
    ]], {
        vehicle.id, plate, reason, notes, photo, lotId, linkedReport, fee,
        holdType, holdUntil, holdLabel,
        cid, officerName, os.time(),
    })

    -- Recovering the car closes any active BOLO on it.
    local boloClosed = clearVehicleBolo(plate)

    -- Tell the owner. They had no way of knowing before this.
    local lotForMail = getLot(lotId)
    local storageCfg = impoundCfg().Storage or {}
    local body = ('Your vehicle %s has been impounded.'):format(plate)
    body = body .. ('\n\nReason: %s'):format(reason)
    body = body .. ('\nHeld at: %s'):format((lotForMail and lotForMail.label) or lotId)
    if fee > 0 then
        body = body .. ('\nRelease fee: $%d'):format(fee)
        if (storageCfg.PerDay or 0) > 0 then
            body = body .. ('\nStorage: $%d per day, up to %d days')
                :format(storageCfg.PerDay, storageCfg.MaxDays or 0)
        end
    else
        body = body .. '\nRelease fee: none'
    end
    if holdType == 'indefinite' then
        body = body .. '\n\nHold: the vehicle will not be released until law enforcement authorises it.'
    elseif holdType == 'timed' and holdUntil then
        body = body .. ('\n\nHold: the vehicle cannot be released before %s.')
            :format(os.date('%Y-%m-%d %H:%M', holdUntil))
    end
    body = body .. '\n\nSpeak to an officer to arrange release. The longer it stays with us, the more it will cost you.'
    mailOwner(vehicle.citizenid, ('Vehicle impounded — %s'):format(plate), body)

    if ps.auditLog then
        local lot = getLot(lotId)
        ps.auditLog(src, 'vehicle_impounded', 'vehicle', plate, {
            plate        = plate,
            reason       = reason,
            fee          = fee,
            lot          = lotId,
            reportId     = linkedReport,
            onSite       = payload.onSite == true,
            boloClosed   = boloClosed,
            hold         = holdLabel,
            action_label = ('Impounded %s at %s — %s (fee $%d, held: %s)'):format(
                plate, (lot and lot.label) or lotId, reason, fee, holdLabel or 'immediate'),
        })
    end

    local msg = ('%s impounded'):format(plate)
    if boloClosed then msg = msg .. ' — BOLO resolved' end
    return { success = true, message = msg, boloClosed = boloClosed }
end

ps.registerCallback(resourceName .. ':server:impoundVehicle', function(source, payload)
    return doImpound(source, payload)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Collect the release fee (bank/cash via the bridge's removeMoney).
-- ─────────────────────────────────────────────────────────────────────────────
ps.registerCallback(resourceName .. ':server:payImpoundFee', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'vehicle_impound_release') then
        return { success = false, message = 'Insufficient permissions' }
    end

    payload = payload or {}
    local plate = cleanPlate(payload.plate)
    if not plate then return { success = false, message = 'Missing plate number' } end

    local vehicle = MySQL.single.await(
        'SELECT id, citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if not vehicle then return { success = false, message = 'Vehicle not found' } end

    local row = activeImpound(vehicle.id)
    if not row then return { success = false, message = 'Vehicle is not impounded' } end
    if isTruthy(row.fee_paid) then return { success = false, message = 'Fee is already paid' } end

    -- What's actually owed is the impound fee plus whatever storage has accrued.
    local owed, storage = totalOwed(row)
    if owed <= 0 then
        MySQL.update.await('UPDATE mdt_impound SET fee_paid = 1 WHERE id = ?', { row.id })
        return { success = true, message = 'No fee due' }
    end

    -- The owner pays. They must be online for money to be taken.
    local owner = vehicle.citizenid and ps.getPlayerByIdentifier(vehicle.citizenid) or nil
    if not owner then
        return { success = false, message = 'Vehicle owner must be online to pay the fee' }
    end
    local ownerSrc = owner.PlayerData and owner.PlayerData.source or owner.source
    if not ownerSrc then
        return { success = false, message = 'Vehicle owner must be online to pay the fee' }
    end

    -- Claim the payment BEFORE taking money. The conditional update is the lock:
    -- two officers pressing Collect at once can only ever produce one charge.
    local claimed = MySQL.update.await(
        'UPDATE mdt_impound SET fee_paid = 1 WHERE id = ? AND fee_paid = 0', { row.id })
    if not claimed or claimed < 1 then
        return { success = false, message = 'Fee is already paid' }
    end

    local account = impoundCfg().FeeAccount or 'bank'
    local removed = ps.removeMoney(ownerSrc, account, owed, 'mdt-impound-fee')
    if not removed then
        MySQL.update.await('UPDATE mdt_impound SET fee_paid = 0 WHERE id = ?', { row.id })
        return { success = false, message = 'Owner could not cover the fee' }
    end

    -- Money leaving an account warrants immediate feedback, so the on-screen note
    -- stays; the e-mail is the receipt they can actually go back and read.
    ps.notify(ownerSrc, ('$%d impound fee charged for %s'):format(owed, plate), 'error')

    local receipt = ('$%d has been charged for the release of %s.'):format(owed, plate)
    if storage > 0 then
        receipt = receipt .. ('\n\nImpound fee: $%d\nStorage: $%d\nTotal: $%d')
            :format(row.fee or 0, storage, owed)
    end
    receipt = receipt .. '\n\nYour vehicle can now be released.'
    mailOwner(vehicle.citizenid, ('Impound fee paid — %s'):format(plate), receipt)

    if ps.auditLog then
        ps.auditLog(src, 'vehicle_impound_fee_paid', 'vehicle', plate, {
            plate        = plate,
            fee          = row.fee,
            storage      = storage,
            total        = owed,
            action_label = storage > 0
                and ('Collected $%d for %s ($%d fee + $%d storage)'):format(owed, plate, row.fee, storage)
                or  ('Collected the $%d impound fee for %s'):format(owed, plate),
        })
    end

    return { success = true, message = ('$%d collected'):format(owed) }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Release a vehicle: administrative, works from anywhere. The car is queued to
-- be spawned into a free spot at its lot.
-- ─────────────────────────────────────────────────────────────────────────────
ps.registerCallback(resourceName .. ':server:releaseImpound', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'vehicle_impound_release') then
        return { success = false, message = 'Insufficient permissions' }
    end

    payload = payload or {}
    local plate = cleanPlate(payload.plate)
    if not plate then return { success = false, message = 'Missing plate number' } end

    local vehicle = MySQL.single.await([[
        SELECT id, plate, vehicle, fuel, engine, body, citizenid
        FROM player_vehicles WHERE plate = ? LIMIT 1
    ]], { plate })
    if not vehicle then return { success = false, message = 'Vehicle not found' } end

    local row = activeImpound(vehicle.id)
    if not row then return { success = false, message = 'Vehicle is not impounded' } end

    -- Fee gate (configurable).
    local owed = totalOwed(row)
    if impoundCfg().RequireFeePaid and owed > 0 and not isTruthy(row.fee_paid) then
        return { success = false, message = ('Outstanding fee of $%d must be paid first'):format(owed) }
    end

    -- Hold gate. Cutting a hold short is a deliberate override: it needs its own
    -- permission and a written reason, and it is logged as an override rather than
    -- quietly passed off as a routine release.
    local releasable, holdWhy = holdStatus(row)
    local override = payload.override == true
    local overrideReason = type(payload.overrideReason) == 'string'
        and payload.overrideReason:sub(1, 300) or nil
    if overrideReason == '' then overrideReason = nil end

    if not releasable then
        if not override then
            return { success = false, message = holdWhy, held = true }
        end
        if not CheckPermission(src, 'vehicle_impound_override') then
            return { success = false, message = 'You are not authorised to override an impound hold' }
        end
        if not overrideReason then
            return { success = false, message = 'An override needs a reason' }
        end
    else
        -- Nothing to override; treat it as the routine release it is.
        override = false
        overrideReason = nil
    end

    local lotId = row.lot or defaultLotId()
    local lot = getLot(lotId)
    if not lot then return { success = false, message = 'Unknown impound lot' } end

    local cid, officerName = officerInfo(src)

    -- Straight back into the owner's garage (state 1). The impound row is kept
    -- for history rather than deleted.
    MySQL.update.await('UPDATE player_vehicles SET state = 1 WHERE plate = ?', { plate })
    MySQL.update.await([[
        UPDATE mdt_impound
        SET status = 'released', released_at = ?, released_by_citizenid = ?, released_by_name = ?,
            override_reason = ?
        WHERE id = ?
    ]], { os.time(), cid, officerName, overrideReason, row.id })

    -- Let the owner know it's waiting for them. By e-mail, so it also reaches them
    -- if they were offline when it was released.
    mailOwner(vehicle.citizenid,
        ('Vehicle released — %s'):format(plate),
        ('Your vehicle %s has been released from the impound lot.\n\nIt is back in your garage.')
            :format(plate))

    if ps.auditLog then
        ps.auditLog(src, override and 'vehicle_impound_override' or 'vehicle_released', 'vehicle', plate, {
            plate           = plate,
            lot             = lotId,
            override        = override,
            override_reason = overrideReason,
            hold            = row.hold_label,
            action_label = override
                and ('OVERRODE the hold on %s and released it — %s'):format(plate, overrideReason)
                or ('Released %s from %s'):format(plate, (lot and lot.label) or lotId),
        })
    end

    return {
        success = true,
        message = ('%s released — returned to the owner\'s garage'):format(plate),
    }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- On-site impound
--
-- The officer runs /impound next to a car. Everything the client claims is
-- re-checked here against the real entity: a client that lies about a net id, a
-- plate or the distance gets nothing.
-- ─────────────────────────────────────────────────────────────────────────────

-- Cleanup payouts, per officer. Kept in memory: a shift is a session, and losing
-- the counters on restart only ever costs the server money it never owed.
-- CleanupState[citizenid] = { last = os.time(), count = n }
local CleanupState = {}

local function onSiteCfg()
    return (impoundCfg().OnSite) or {}
end

-- Pay an officer. ps.addMoney doesn't exist on the bridge, so go through the
-- framework player object — the same object charges.lua already gets back from
-- ps.getPlayerByIdentifier, which is proven to work here.
local function payOfficer(src, account, amount, reason)
    if amount <= 0 then return true end

    local cid = ps.getIdentifier and ps.getIdentifier(src) or nil
    local Player = cid and ps.getPlayerByIdentifier(cid) or nil

    if Player and Player.Functions and Player.Functions.AddMoney then
        local ok = pcall(Player.Functions.AddMoney, account, amount, reason)
        if ok then return true end
    end

    -- Fall back to the core export if the bridge handed us something unexpected.
    local ok = pcall(function()
        local core = GetResourceState('qbx_core') == 'started'
            and exports['qbx_core']:GetCoreObject()
            or exports['qb-core']:GetCoreObject()
        local P = core.Functions.GetPlayer(src)
        if not P or not P.Functions or not P.Functions.AddMoney then
            error('no usable player object')
        end
        P.Functions.AddMoney(account, amount, reason)
    end)

    if not ok then
        ps.warn(('[impound] could not pay $%d to source %s'):format(amount, tostring(src)))
    end
    return ok
end

-- Resolve a client-supplied net id to a real vehicle the officer is standing at.
-- Returns entity, errorMessage.
local function resolveVehicle(src, netId)
    netId = tonumber(netId)
    if not netId then return nil, 'No vehicle selected' end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil, 'That vehicle no longer exists'
    end
    if GetEntityType(entity) ~= 2 then -- 2 = vehicle
        return nil, 'That is not a vehicle'
    end

    -- The officer has to actually be next to it.
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil, 'Player not found' end
    local maxDist = onSiteCfg().MaxDistance or 6.0
    local dist = #(GetEntityCoords(ped) - GetEntityCoords(entity))
    if dist > (maxDist + 2.0) then -- small grace for movement during the round-trip
        return nil, 'You are too far from the vehicle'
    end

    return entity, nil
end

-- The vehicle isn't deleted the instant the record is written: it stays put for the
-- moment it takes the client to fade it out. This watchdog is the safety net for a
-- client that crashes, alt-F4s or never reports back — the world can never keep a
-- car that the database calls impounded.
local REMOVAL_GRACE = 30 -- seconds
local function scheduleRemoval(netId, seconds)
    netId = tonumber(netId)
    if not netId then return end

    CreateThread(function()
        Wait((seconds or 60) * 1000)
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
    end)
end

-- The client finished fading the vehicle out: take it out of the world for good.
RegisterNetEvent(resourceName .. ':server:removeVehicle', function(netId)
    local src = source
    if not CheckAuth(src) then return end
    netId = tonumber(netId)
    if not netId then return end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        DeleteEntity(entity)
    end
end)

-- Is a real player sitting in this vehicle? NPC occupants are fine; players are not.
local function hasPlayerOccupant(entity)
    for _, pid in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(pid)
        if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) == entity then
            return true
        end
    end
    return false
end

-- Step 1: the client asks what it's looking at. Tells the UI whether this is an
-- owned vehicle (full impound form) or unowned traffic (quick removal).
ps.registerCallback(resourceName .. ':server:inspectOnSiteVehicle', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'vehicle_impound') then
        return { success = false, message = 'Insufficient permissions' }
    end

    payload = payload or {}
    local entity, err = resolveVehicle(src, payload.netId)
    if not entity then return { success = false, message = err } end

    if hasPlayerOccupant(entity) then
        return { success = false, message = 'There is somebody in that vehicle' }
    end

    local plate = cleanPlate(payload.plate)
    local owned = plate and MySQL.single.await(
        'SELECT id, plate, vehicle, state FROM player_vehicles WHERE plate = ? LIMIT 1', { plate }) or nil

    if not owned then
        -- Unowned traffic: no owner, no garage, no fee to collect. It just goes.
        return {
            success = true,
            owned   = false,
            plate   = plate,
            model   = payload.model,
        }
    end

    if activeImpound(owned.id) then
        return { success = false, message = 'That vehicle is already impounded' }
    end

    return {
        success = true,
        owned   = true,
        plate   = owned.plate,
        model   = owned.vehicle,
    }
end)

-- Step 2a: owned vehicle — impound it properly, then remove it from the world.
ps.registerCallback(resourceName .. ':server:impoundOnSite', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'vehicle_impound') then
        return { success = false, message = 'Insufficient permissions' }
    end

    payload = payload or {}
    local entity, err = resolveVehicle(src, payload.netId)
    if not entity then return { success = false, message = err } end
    if hasPlayerOccupant(entity) then
        return { success = false, message = 'There is somebody in that vehicle' }
    end

    -- Same impound path as the MDT; onSite lifts the "must be garaged" rule.
    payload.onSite = true
    local result = doImpound(src, payload)
    if not result or not result.success then
        return result or { success = false, message = 'Impound failed' }
    end

    -- Give the client a moment to fade it out; this is the backstop if it never does.
    scheduleRemoval(payload.netId, REMOVAL_GRACE)

    return result
end)

-- Step 2b: unowned traffic — remove it and pay the officer for clearing the road.
ps.registerCallback(resourceName .. ':server:cleanupVehicle', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'vehicle_impound') then
        return { success = false, message = 'Insufficient permissions' }
    end

    payload = payload or {}
    local entity, err = resolveVehicle(src, payload.netId)
    if not entity then return { success = false, message = err } end
    if hasPlayerOccupant(entity) then
        return { success = false, message = 'There is somebody in that vehicle' }
    end

    -- Re-check ownership server-side: an owned car must never go through here,
    -- no matter what the client claims.
    local plate = cleanPlate(payload.plate)
    if plate then
        local owned = MySQL.single.await(
            'SELECT id FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
        if owned then
            return { success = false, message = 'That vehicle has an owner — impound it instead' }
        end
    end

    local cfg = onSiteCfg().Cleanup or {}
    local cid = ps.getIdentifier and ps.getIdentifier(src) or nil
    if not cid then return { success = false, message = 'Player not found' } end

    local state = CleanupState[cid] or { last = 0, count = 0 }
    local now = os.time()

    local cooldown = cfg.Cooldown or 0
    if cooldown > 0 and (now - state.last) < cooldown then
        local wait = cooldown - (now - state.last)
        return { success = false, message = ('Wait %d more second(s) before the next tow'):format(wait) }
    end

    local maxPerShift = cfg.MaxPerShift or 0
    local capped = maxPerShift > 0 and state.count >= maxPerShift

    -- The car goes either way — the cap only stops the payout, so an officer can
    -- still clear the streets after hitting the limit.
    scheduleRemoval(payload.netId, REMOVAL_GRACE)

    state.last = now
    state.count = state.count + 1
    CleanupState[cid] = state

    local reward = 0
    if not capped then
        local minR = cfg.RewardMin or 0
        local maxR = cfg.RewardMax or minR
        if maxR < minR then maxR = minR end
        reward = math.random(minR, maxR)
        if reward > 0 and not payOfficer(src, cfg.Account or 'cash', reward, 'mdt-street-cleanup') then
            reward = 0 -- couldn't pay: don't claim we did
        end
    end

    if ps.auditLog then
        ps.auditLog(src, 'vehicle_cleanup', 'vehicle', plate or 'unknown', {
            plate        = plate,
            reward       = reward,
            capped       = capped,
            action_label = capped
                and ('Removed an abandoned vehicle (%s) — shift payout limit reached'):format(plate or 'no plate')
                or  ('Removed an abandoned vehicle (%s) — earned $%d'):format(plate or 'no plate', reward),
        })
    end

    return {
        success = true,
        reward  = reward,
        capped  = capped,
        message = capped
            and 'Towed away — shift payout limit reached'
            or  ('Towed away — earned $%d'):format(reward),
    }
end)

-- Counters are per session; drop them when the officer leaves.
AddEventHandler('playerDropped', function()
    local src = source
    local cid = ps.getIdentifier and ps.getIdentifier(src) or nil
    if cid then CleanupState[cid] = nil end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Read APIs for the MDT
-- ─────────────────────────────────────────────────────────────────────────────

-- The impound lot work list: every active impound.
ps.registerCallback(resourceName .. ':server:getImpoundLot', function(source)
    local src = source
    if not CheckAuth(src) then return { vehicles = {} } end

    local rows = MySQL.query.await([[
        SELECT
            i.id, i.plate, i.reason, i.notes, i.photo, i.lot, i.fee, i.fee_paid,
            i.hold_type, i.hold_until, i.hold_label,
            i.officer_name, i.time, i.linkedreport,
            pv.vehicle AS model,
            pv.citizenid AS owner_citizenid,
            CONCAT(
                JSON_UNQUOTE(JSON_EXTRACT(p.charinfo, '$.firstname')), ' ',
                JSON_UNQUOTE(JSON_EXTRACT(p.charinfo, '$.lastname'))
            ) AS owner_name
        FROM mdt_impound i
        JOIN player_vehicles pv ON pv.id = i.vehicleid
        LEFT JOIN players p ON p.citizenid = pv.citizenid
        WHERE i.status = 'active'
        ORDER BY i.time DESC
    ]]) or {}

    -- Storage and hold state are derived, so they're attached on read.
    for _, r in ipairs(rows) do
        local storage, days = storageInfo(r.time)
        r.storage = storage
        r.days_held = days
        r.total = (r.fee or 0) + storage
        decorateHold(r)
    end

    return { vehicles = rows }
end)

-- Full impound history for one vehicle (active + past).
ps.registerCallback(resourceName .. ':server:getImpoundHistory', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { entries = {} } end

    payload = payload or {}
    local plate = cleanPlate(payload.plate)
    if not plate then return { entries = {} } end

    local rows = MySQL.query.await([[
        SELECT id, status, reason, notes, photo, lot, fee, fee_paid, linkedreport,
               hold_type, hold_until, hold_label, override_reason,
               officer_name, time, released_at, released_by_name
        FROM mdt_impound
        WHERE plate = ?
        ORDER BY time DESC
        LIMIT 25
    ]], { plate }) or {}

    for _, r in ipairs(rows) do
        if r.status == 'active' then
            local storage, days = storageInfo(r.time)
            r.storage = storage
            r.days_held = days
            r.total = (r.fee or 0) + storage
            decorateHold(r)
        else
            r.storage = 0
            r.total = r.fee or 0
        end
    end

    return { entries = rows }
end)

-- Reasons + lots for the impound modal.
ps.registerCallback(resourceName .. ':server:getImpoundConfig', function(source)
    if not CheckAuth(source) then return {} end
    local cfg = impoundCfg()
    local lots = {}
    for _, lot in ipairs(cfg.Lots or {}) do
        lots[#lots + 1] = { id = lot.id, label = lot.label }
    end
    return {
        reasons        = cfg.Reasons or {},
        lots           = lots,
        defaultFee     = cfg.DefaultFee or 0,
        maxFee         = cfg.MaxFee or 50000,
        requireFeePaid = cfg.RequireFeePaid == true,
        storage        = {
            perDay  = (cfg.Storage or {}).PerDay or 0,
            maxDays = (cfg.Storage or {}).MaxDays or 0,
        },
        durations       = cfg.Durations or {},
        defaultDuration = cfg.DefaultDuration or 'immediate',
    }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Self-healing: a vehicle can be set to state 2 by another resource (a garage
-- script, an older impound). Those would show as "Impounded" in the MDT with no
-- record at all. On start we adopt them so the lot view is never lying.
-- ─────────────────────────────────────────────────────────────────────────────
CreateThread(function()
    Wait(2000)
    local orphans = MySQL.query.await([[
        SELECT pv.id, pv.plate
        FROM player_vehicles pv
        LEFT JOIN mdt_impound i
            ON i.vehicleid = pv.id AND i.status = 'active'
        WHERE pv.state = 2 AND i.id IS NULL
    ]]) or {}

    if #orphans == 0 then return end

    for _, v in ipairs(orphans) do
        MySQL.insert.await([[
            INSERT INTO mdt_impound
                (vehicleid, status, plate, reason, lot, fee, fee_paid, officer_name, time)
            VALUES (?, 'active', ?, ?, ?, 0, 0, ?, ?)
        ]], { v.id, v.plate, 'Impounded outside the MDT', defaultLotId(), 'System', os.time() })
    end

    ps.debug(('[impound] adopted %d vehicle(s) that were impounded outside the MDT'):format(#orphans))
end)