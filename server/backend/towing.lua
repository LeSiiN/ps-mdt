-- ═══════════════════════════════════════════════════════════════════════════
--  Tow jobs  (server/backend/towing.lua)
-- ═══════════════════════════════════════════════════════════════════════════
-- An impounded vehicle used to fade out where it stood. Now it becomes a job:
-- a tow company collects it and drives it to a lot, and only then is it in.
--
-- Deliberately independent of any towing script. Completion is judged by where
-- the vehicle ended up, not by how it was moved — every server runs a different
-- tow resource, and depending on one would exclude most of them.

local resourceName = GetCurrentResourceName()

local function towCfg()
    return (Config and Config.Towing) or {}
end

local function towEnabled()
    return towCfg().Enabled ~= false
end

--- Jobs that may receive tow work.
local function isTowJob(job)
    for _, j in ipairs(towCfg().Jobs or {}) do
        if j == job then return true end
    end
    return false
end

--- Drop-off points, by lot id.
local function dropOffFor(lot)
    for _, d in ipairs(towCfg().DropOffs or {}) do
        if d.lot == lot then return d end
    end
    return (towCfg().DropOffs or {})[1]
end

-- ── Who is available ────────────────────────────────────────────────────────
-- Only companies with somebody ON DUTY are offered. A job posted to an empty
-- company is a vehicle nobody collects, and the officer waiting for it has no
-- way to tell the difference.

-- Drivers who marked themselves unavailable. In memory only: it is a "not
-- right now", not a setting, and it should lapse when they reconnect.
local unavailable = {}

lib.callback.register(resourceName .. ':server:getTowCompanies', function(source)
    if not CheckAuth(source) then return {} end
    if not towEnabled() then return {} end

    local officerPed = GetPlayerPed(source)
    local here = officerPed ~= 0 and GetEntityCoords(officerPed) or nil

    -- Who is already out on a run. A company whose drivers are all busy can
    -- still be picked in principle, but the officer should see that first.
    local busy = {}
    local rows = MySQL.query.await(
        "SELECT driver_citizenid FROM mdt_tow_jobs WHERE status = 'taken'") or {}
    for i = 1, #rows do busy[rows[i].driver_citizenid] = true end

    local info = {}
    for _, pid in ipairs(GetPlayers()) do
        pid = tonumber(pid)
        local job = pid and MDT.getJobName(pid)
        if job and isTowJob(job) and MDT.getJobDuty(pid) then
            local cid = MDT.getIdentifier(pid)
            local e = info[job] or { onDuty = 0, free = 0, nearest = nil }

            e.onDuty = e.onDuty + 1
            if not busy[cid] and not unavailable[cid] then e.free = e.free + 1 end

            -- Distance to the CLOSEST driver, so the officer can send the job
            -- to whoever is actually nearby rather than the other side of the
            -- map.
            if here then
                local ped = GetPlayerPed(pid)
                if ped and ped ~= 0 then
                    local d = #(GetEntityCoords(ped) - here)
                    if not e.nearest or d < e.nearest then e.nearest = d end
                end
            end
            info[job] = e
        end
    end

    local out = {}
    for _, j in ipairs(towCfg().Jobs or {}) do
        local e = info[j]
        if e then
            out[#out + 1] = {
                job = j,
                onDuty = e.onDuty,
                free = e.free,
                distance = e.nearest and math.floor(e.nearest) or nil,
            }
        end
    end

    -- Closest first: the officer's next decision is which one to pick, and the
    -- nearest free driver is almost always the right answer.
    table.sort(out, function(a, b)
        if (a.free > 0) ~= (b.free > 0) then return a.free > 0 end
        return (a.distance or 99999) < (b.distance or 99999)
    end)
    return out
end)

--- A driver stepping out of the queue for a while. Not off duty — just not
--- available for tows right now.
lib.callback.register(resourceName .. ':server:setTowAvailable', function(source, available)
    local citizenid = MDT.getIdentifier(source)
    if not citizenid then return { success = false } end

    if available then
        unavailable[citizenid] = nil
    else
        unavailable[citizenid] = true
        -- Whatever they were holding goes back so somebody else can take it.
        MySQL.update.await([[
            UPDATE mdt_tow_jobs
            SET status = 'open', driver_citizenid = NULL, driver_name = NULL, taken_at = NULL
            WHERE driver_citizenid = ? AND status = 'taken'
        ]], { citizenid })
    end
    return { success = true, available = available and true or false }
end)

lib.callback.register(resourceName .. ':server:getTowAvailable', function(source)
    local citizenid = MDT.getIdentifier(source)
    return { available = not (citizenid and unavailable[citizenid]) }
end)

AddEventHandler('playerDropped', function()
    local citizenid = MDT.getIdentifier(source)
    if citizenid then unavailable[citizenid] = nil end
end)

-- ── Posting a job ───────────────────────────────────────────────────────────

--- Called by the impound flow once the paperwork is done.
---@param src number officer
---@param data table { impound_id, plate, model, lot, coords, location, job }
---@return number|nil jobId
function CreateTowJob(src, data)
    if not towEnabled() then return nil end
    if type(data) ~= 'table' or type(data.plate) ~= 'string' then return nil end

    local drop = dropOffFor(data.lot)
    local id = MySQL.insert.await([[
        INSERT INTO mdt_tow_jobs
            (impound_id, plate, model, lot, coords, location, pay, job_name,
             officer_citizenid, officer_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        data.impound_id,
        data.plate:upper(),
        data.model,
        drop and drop.lot or data.lot,
        data.coords,
        data.location,
        math.max(0, math.floor(tonumber(towCfg().Pay) or 0)),
        data.job,
        MDT.getIdentifier(src),
        data.officerName or MDT.getPlayerName(src),
    })
    if not id then return nil end

    -- A proper dispatch alert, same as any other call. The list holds
    -- everything needed to do the job, so a driver who was elsewhere when it
    -- fired has lost nothing.
    if towCfg().DispatchAlert ~= false and data.job then
        for _, pid in ipairs(GetPlayers()) do
            pid = tonumber(pid)
            local cid = pid and MDT.getIdentifier(pid)
            if pid and MDT.getJobName(pid) == data.job and MDT.getJobDuty(pid)
               and not (cid and unavailable[cid]) then
                TriggerClientEvent('ps-mdt:client:towJobPosted', pid, {
                    id = id,
                    job = data.job,
                    plate = data.plate,
                    model = data.model,
                    location = data.location,
                    coords = data.coordsTable,
                    officer = data.officerName,
                    pay = math.max(0, math.floor(tonumber(towCfg().Pay) or 0)),
                })
            end
        end
    end

    return id
end

-- ── The driver's list ───────────────────────────────────────────────────────

lib.callback.register(resourceName .. ':server:getTowJobs', function(source)
    local src = source
    if not towEnabled() then return { jobs = {}, mine = nil } end

    local job = MDT.getJobName(src)
    if not isTowJob(job) then return { jobs = {}, mine = nil } end

    local citizenid = MDT.getIdentifier(src)

    -- One at a time. Without this, the first driver online takes everything and
    -- nobody else gets to work.
    local mine = MySQL.single.await([[
        SELECT id, plate, model, lot, coords, location, pay,
               DATE_FORMAT(taken_at, '%Y-%m-%d %H:%i') AS taken_at
        FROM mdt_tow_jobs
        WHERE driver_citizenid = ? AND status = 'taken'
        LIMIT 1
    ]], { citizenid })

    local jobs = MySQL.query.await([[
        SELECT id, plate, model, lot, coords, location, pay, officer_name,
               DATE_FORMAT(created_at, '%Y-%m-%d %H:%i') AS created_at
        FROM mdt_tow_jobs
        WHERE status = 'open' AND (job_name IS NULL OR job_name = ?)
        ORDER BY created_at ASC
        LIMIT 25
    ]], { job }) or {}

    -- Lot ids mean nothing to a driver; the label is what is written on the
    -- gate.
    local function label(row)
        if not row then return end
        for _, d in ipairs(towCfg().DropOffs or {}) do
            if d.lot == row.lot then row.lotLabel = d.label break end
        end
        row.lotLabel = row.lotLabel or row.lot
    end
    for i = 1, #jobs do label(jobs[i]) end
    label(mine)

    return { jobs = jobs, mine = mine }
end)

lib.callback.register(resourceName .. ':server:takeTowJob', function(source, jobId)
    local src = source
    if not towEnabled() then return { success = false, error = 'Towing is disabled' } end

    local job = MDT.getJobName(src)
    if not isTowJob(job) then return { success = false, error = 'Not a towing job' } end
    if not MDT.getJobDuty(src) then return { success = false, error = 'You are off duty' } end

    local citizenid = MDT.getIdentifier(src)
    if unavailable[citizenid] then
        return { success = false, error = 'You marked yourself unavailable' }
    end

    local already = MySQL.scalar.await(
        'SELECT id FROM mdt_tow_jobs WHERE driver_citizenid = ? AND status = ? LIMIT 1',
        { citizenid, 'taken' })
    if already then
        return { success = false, error = 'Finish the job you already have' }
    end

    -- Conditional update rather than check-then-write: two drivers pressing at
    -- once would otherwise both be told they got it.
    local affected = MySQL.update.await([[
        UPDATE mdt_tow_jobs
        SET status = 'taken', driver_citizenid = ?, driver_name = ?, taken_at = CURRENT_TIMESTAMP
        WHERE id = ? AND status = 'open'
    ]], { citizenid, MDT.getPlayerName(src), tonumber(jobId) })

    if affected ~= 1 then
        return { success = false, error = 'Somebody else took that one' }
    end
    return { success = true }
end)

lib.callback.register(resourceName .. ':server:dropTowJob', function(source, jobId)
    local citizenid = MDT.getIdentifier(source)
    MySQL.update.await([[
        UPDATE mdt_tow_jobs
        SET status = 'open', driver_citizenid = NULL, driver_name = NULL, taken_at = NULL
        WHERE id = ? AND driver_citizenid = ? AND status = 'taken'
    ]], { tonumber(jobId), citizenid })
    return { success = true }
end)

-- ── Delivery ────────────────────────────────────────────────────────────────
-- Judged by where the vehicle ended up. Any towing script works, and so does
-- none — a server without one simply drives it there.

lib.callback.register(resourceName .. ':server:deliverTowJob', function(source, payload)
    local src = source
    if not towEnabled() then return { success = false, error = 'Towing is disabled' } end

    local citizenid = MDT.getIdentifier(src)
    local row = MySQL.single.await([[
        SELECT id, impound_id, plate, lot, pay, status, job_name
        FROM mdt_tow_jobs WHERE id = ? AND driver_citizenid = ?
    ]], { tonumber(payload and payload.jobId), citizenid })

    if not row then return { success = false, error = 'Not your job' } end
    if row.status ~= 'taken' then return { success = false, error = 'That job is already closed' } end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return { success = false, error = 'Could not find you' } end

    local drop
    for _, d in ipairs(towCfg().DropOffs or {}) do
        if d.lot == row.lot then drop = d break end
    end
    if not drop then return { success = false, error = 'No drop-off configured for that lot' } end

    -- The VEHICLE has to be there, not the driver. Checking the driver meant
    -- that walking to the lot and pressing Deliver paid out while the car sat
    -- where it was towed from.
    local entity, plate = nil, row.plate:gsub('%s+', ''):upper()
    for _, veh in ipairs(GetAllVehicles()) do
        local p = GetVehicleNumberPlateText(veh)
        if p and p:gsub('%s+', ''):upper() == plate then entity = veh break end
    end
    if not entity then
        return { success = false, error = 'That vehicle is nowhere to be found' }
    end

    local radius = tonumber(drop.radius) or 25.0
    if #(GetEntityCoords(entity) - drop.coords) > radius then
        return { success = false, error = ('Bring the vehicle to %s first'):format(drop.label or row.lot) }
    end

    -- And the driver with it, so nobody finishes a job off the back of a car
    -- somebody else happened to park correctly.
    if #(GetEntityCoords(ped) - drop.coords) > radius then
        return { success = false, error = 'Be at the lot with it' }
    end

    if towCfg().RequireTruck then
        local truck = GetVehiclePedIsIn(ped, false)
        if truck == 0 or GetVehicleClass(truck) ~= 9 then
            return { success = false, error = 'Deliver it with a tow truck' }
        end
    end

    -- In the lot now, so it comes off the street. Without this it stayed parked
    -- at the impound forever.
    if DoesEntityExist(entity) then DeleteEntity(entity) end

    MySQL.update.await(
        'UPDATE mdt_tow_jobs SET status = ?, done_at = CURRENT_TIMESTAMP WHERE id = ?',
        { 'done', row.id })

    -- Only now is the vehicle actually in the lot. Until delivery it was
    -- pending: on the record, but not yet somewhere it could be released from.
    if row.impound_id then
        MySQL.update.await(
            'UPDATE mdt_impound SET status = ? WHERE id = ?', { 'active', row.impound_id })
    end

    local pay = math.max(0, math.floor(tonumber(row.pay) or 0))
    local share = tonumber(towCfg().DriverShare) or 0.75
    local driverCut = math.floor(pay * share)
    local companyCut = pay - driverCut

    if driverCut > 0 then
        MDT.addMoney(src, 'bank', driverCut, 'tow-job')
    end
    if companyCut > 0 and row.job_name then
        pcall(DepositToDepartment, row.job_name, companyCut, ('Tow job %s'):format(row.plate))
    end

    return { success = true, paid = driverCut, plate = row.plate }
end)

--- Hooks for servers whose towing script wants to close the job itself.
--- Optional: without them the driver presses Deliver, which checks the same
--- things.
RegisterNetEvent('ps-mdt:tow:delivered', function(plate)
    local src = source
    if not towEnabled() or type(plate) ~= 'string' then return end
    local citizenid = MDT.getIdentifier(src)
    local row = MySQL.single.await([[
        SELECT id, impound_id FROM mdt_tow_jobs
        WHERE plate = ? AND driver_citizenid = ? AND status = 'taken' LIMIT 1
    ]], { plate:upper(), citizenid })
    if not row then return end

    MySQL.update.await(
        'UPDATE mdt_tow_jobs SET status = ?, done_at = CURRENT_TIMESTAMP WHERE id = ?',
        { 'done', row.id })
    if row.impound_id then
        MySQL.update.await('UPDATE mdt_impound SET status = ? WHERE id = ?', { 'active', row.impound_id })
    end
end)

-- ── Jobs nobody finished ────────────────────────────────────────────────────
-- A driver who logs out mid-job, or takes one and never arrives, would
-- otherwise leave a vehicle waiting forever and a queue nobody else can work.

CreateThread(function()
    Wait(60000)
    while true do
        if towEnabled() then
            local unclaimed = tonumber(towCfg().ExpireUnclaimed) or 20
            local taken = tonumber(towCfg().ExpireTaken) or 30

            MySQL.update.await(([[
                UPDATE mdt_tow_jobs
                SET status = 'cancelled'
                WHERE status = 'open'
                  AND created_at < DATE_SUB(CURRENT_TIMESTAMP, INTERVAL %d MINUTE)
            ]]):format(unclaimed))

            MySQL.update.await(([[
                UPDATE mdt_tow_jobs
                SET status = 'open', driver_citizenid = NULL, driver_name = NULL, taken_at = NULL
                WHERE status = 'taken'
                  AND taken_at < DATE_SUB(CURRENT_TIMESTAMP, INTERVAL %d MINUTE)
            ]]):format(taken))
        end
        Wait(300000)
    end
end)

--- Called by the impound flow when an officer removes a vehicle themselves.
function CancelTowJob(impoundId)
    if not impoundId then return end
    MySQL.update.await(
        'UPDATE mdt_tow_jobs SET status = ? WHERE impound_id = ? AND status IN (?, ?)',
        { 'cancelled', impoundId, 'open', 'taken' })
end
