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
ps.registerCallback(resourceName .. ':server:impoundVehicle', function(source, payload)
    local src = source
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
    if activeImpound(vehicle.id) then
        return { success = false, message = 'Vehicle is already impounded' }
    end

    local cid, officerName = officerInfo(src)

    MySQL.update.await('UPDATE player_vehicles SET state = 2 WHERE plate = ?', { plate })
    MySQL.insert.await([[
        INSERT INTO mdt_impound
            (vehicleid, status, plate, reason, notes, lot, linkedreport, fee, fee_paid,
             officer_citizenid, officer_name, time)
        VALUES (?, 'active', ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
    ]], { vehicle.id, plate, reason, notes, lotId, linkedReport, fee, cid, officerName, os.time() })

    if ps.auditLog then
        local lot = getLot(lotId)
        ps.auditLog(src, 'vehicle_impounded', 'vehicle', plate, {
            plate        = plate,
            reason       = reason,
            fee          = fee,
            lot          = lotId,
            reportId     = linkedReport,
            action_label = ('Impounded %s at %s — %s (fee $%d)'):format(
                plate, (lot and lot.label) or lotId, reason, fee),
        })
    end

    return { success = true, message = ('%s impounded'):format(plate) }
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
    if row.fee_paid == 1 then return { success = false, message = 'Fee is already paid' } end
    if (row.fee or 0) <= 0 then
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

    local account = impoundCfg().FeeAccount or 'bank'
    local removed = ps.removeMoney(ownerSrc, account, row.fee, 'mdt-impound-fee')
    if not removed then
        return { success = false, message = 'Owner could not cover the fee' }
    end

    MySQL.update.await('UPDATE mdt_impound SET fee_paid = 1 WHERE id = ?', { row.id })
    ps.notify(ownerSrc, ('$%d impound fee charged for %s'):format(row.fee, plate), 'error')

    if ps.auditLog then
        ps.auditLog(src, 'vehicle_impound_fee_paid', 'vehicle', plate, {
            plate        = plate,
            fee          = row.fee,
            action_label = ('Collected the $%d impound fee for %s'):format(row.fee, plate),
        })
    end

    return { success = true, message = ('$%d fee collected'):format(row.fee) }
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
    if impoundCfg().RequireFeePaid and (row.fee or 0) > 0 and row.fee_paid ~= 1 then
        return { success = false, message = ('Outstanding fee of $%d must be paid first'):format(row.fee) }
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
        SET status = 'released', released_at = ?, released_by_citizenid = ?, released_by_name = ?
        WHERE id = ?
    ]], { os.time(), cid, officerName, row.id })

    -- Let the owner know it's waiting for them.
    if vehicle.citizenid then
        local owner = ps.getPlayerByIdentifier(vehicle.citizenid)
        local ownerSrc = owner and (owner.PlayerData and owner.PlayerData.source or owner.source) or nil
        if ownerSrc then
            ps.notify(ownerSrc,
                ('Your vehicle %s has been released — it is back in your garage'):format(plate),
                'success')
        end
    end

    if ps.auditLog then
        ps.auditLog(src, 'vehicle_released', 'vehicle', plate, {
            plate        = plate,
            lot          = lotId,
            action_label = ('Released %s from %s'):format(plate, lot.label or lotId),
        })
    end

    return {
        success = true,
        message = ('%s released — returned to the owner\'s garage'):format(plate),
    }
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
            i.id, i.plate, i.reason, i.notes, i.lot, i.fee, i.fee_paid,
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
        SELECT id, status, reason, notes, lot, fee, fee_paid, linkedreport,
               officer_name, time, released_at, released_by_name
        FROM mdt_impound
        WHERE plate = ?
        ORDER BY time DESC
        LIMIT 25
    ]], { plate }) or {}

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