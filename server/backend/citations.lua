local resourceName = GetCurrentResourceName()

-- ═══════════════════════════════════════════════════════════════════════════
--  Citations and parking tickets
-- ═══════════════════════════════════════════════════════════════════════════
-- The MDT records what was written and whether it has been settled. It never
-- moves a citizen's money: payment happens wherever the money already lives,
-- and that resource marks the ticket paid through MarkCitationPaid. Money
-- collected flows the other way, into the issuing department's account.

local function cfg()
    return (Config and Config.Citations) or {}
end

local function overdueCfg()
    return cfg().Overdue or {}
end

--- Next citation number for a type, e.g. CIT-000148.
--- Derived from the table's own count rather than a counter column: there is
--- exactly one source of truth, and a restart can't hand out a duplicate.
---@param ticketType string
---@return string
local function nextCitationNumber(ticketType)
    local prefix = (cfg().NumberPrefix or {})[ticketType] or 'CIT'
    local row = MySQL.single.await(
        'SELECT citation_number FROM mdt_citations WHERE type = ? ORDER BY id DESC LIMIT 1',
        { ticketType }
    )

    local n = 0
    if row and row.citation_number then
        n = tonumber(row.citation_number:match('(%d+)$') or '0') or 0
    end
    return ('%s-%06d'):format(prefix, n + 1)
end

--- Resolve the charges a client asked for against the penal code.
---
--- The client sends CODES ONLY. Amounts, labels and eligibility are read from
--- mdt_penal_codes here — a modified client could otherwise write itself a
--- $0 ticket, or somebody else a $9,999,999 one, because the fine used to be
--- whatever arrived in the payload.
---
--- They are then stored as resolved, not joined at read time: amending the
--- penal code later must not rewrite what somebody was already ticketed for.
---@param charges table list of { code = string }
---@param ticketType string 'citation' | 'parking'
---@return string json, number fine, number points, string|nil err
local function summariseCharges(charges, ticketType)
    if type(charges) ~= 'table' or #charges == 0 then
        return '[]', 0, 0, 'No charges selected'
    end

    local max = tonumber(cfg().MaxCharges) or 5
    local wanted, seen = {}, {}
    for i = 1, math.min(#charges, max) do
        local c = charges[i]
        local code = type(c) == 'table' and c.code or c
        if type(code) == 'string' and code ~= '' and not seen[code] then
            seen[code] = true
            wanted[#wanted + 1] = code
        end
    end
    if #wanted == 0 then return '[]', 0, 0, 'No valid charge codes' end

    local placeholders = string.rep('?,', #wanted - 1) .. '?'
    local rows = MySQL.query.await(([[
        SELECT code, label, fine, in_citation, in_parking
        FROM mdt_penal_codes WHERE code IN (%s)
    ]]):format(placeholders), wanted) or {}

    local byCode = {}
    for i = 1, #rows do byCode[rows[i].code] = rows[i] end

    local clean, fine = {}, 0
    for i = 1, #wanted do
        local row = byCode[wanted[i]]
        if not row then
            return '[]', 0, 0, ('Unknown charge: %s'):format(wanted[i])
        end
        -- Eligibility is enforced here too. The form filters the list, but a
        -- filter in the UI is a convenience, never a rule.
        --
        -- Written out rather than `cond and a or b`: with booleans that idiom
        -- falls through to the wrong column whenever the first value is false.
        local allowed
        if ticketType == 'parking' then allowed = row.in_parking else allowed = row.in_citation end

        -- oxmysql hands tinyint(1) back as a BOOLEAN, so tonumber(true) is nil
        -- and every charge looked ineligible. Accept whatever the driver gives.
        local ok = allowed == true or allowed == 1 or allowed == '1'
        if not ok then
            return '[]', 0, 0, ('%s cannot be written on this ticket type'):format(row.code)
        end

        local f = math.max(0, math.floor(tonumber(row.fine) or 0))
        clean[#clean + 1] = { code = row.code, label = row.label, fine = f }
        fine = fine + f
    end

    -- Same ceiling the rest of the MDT uses for fines, so a stack of expensive
    -- charges can't be turned into an economy exploit.
    local cap = (Config.Fines and tonumber(Config.Fines.MaxAmount)) or 100000
    if fine > cap then
        return '[]', 0, 0, ('Total exceeds the maximum fine of $%d'):format(cap)
    end

    return json.encode(clean), fine, 0, nil
end

-- ── Carbon copies and notices ───────────────────────────────────────────────
-- Paper the two sides walk away with, and the message that makes sure the
-- recipient knows. Deliberately copies, not the claim: the citation lives in
-- the table, so losing or dropping the item changes nothing about what is owed.

--- @param target number server id
--- @param row table the citation as issued
local function notifyRecipient(target, number, isParking, fine)
    if not target or target <= 0 then return end
    TriggerClientEvent('ps-mdt:client:citationReceived', target, {
        number = number,
        parking = isParking,
        fine = fine,
    })
end

local function giveCopy(target, item, number, row)
    if not target or target <= 0 then return false end
    if GetResourceState('ox_inventory') ~= 'started' then
        MDT.error('ox_inventory is not running — no citation copies were handed out')
        return false
    end

    -- ox_inventory returns false when the item does not exist or the inventory
    -- is full. Swallowing that is how one copy quietly goes missing while the
    -- other arrives, which is exactly what happened to the officer's carbon.
    local ok, res = pcall(function()
        return exports.ox_inventory:AddItem(target, item, 1, {
            -- Only the number. Status, fine and charges are read fresh when the
            -- paper is opened, so an old slip can't contradict the record.
            citation = number,
            description = ('%s · $%s'):format(number, row.fine_total or 0),
        })
    end)

    if not ok then
        MDT.error(('Could not give %s: %s'):format(item, tostring(res)))
        return false
    end
    if res == false then
        MDT.error(('%s was refused — is it defined in ox_inventory/data/items.lua, and is the inventory full?')
            :format(item))
        return false
    end
    return true
end

--- Hand out both copies once a ticket is issued.
--- The officer always gets theirs — they wrote it, and their copy is what a
--- future payout scheme would be based on. The recipient gets theirs if we can
--- reach them; a parking ticket's owner may well be offline, and that is fine
--- because the citation itself is already on record.
---@param src number issuing officer
---@param number string citation number
---@param recipientCitizenId string|nil
local function issueCopies(src, number, recipientCitizenId, row)
    -- No carbon for a warning: nothing to collect on later, and the entry in
    -- the file is the point of writing one at all.
    if row.type ~= 'warning' then
        giveCopy(src, 'citation_carbon', number, row)
    end

    if not recipientCitizenId then return end

    -- MDT.getSourceFromIdentifier does not exist — the bridge calls it
    -- getSource. Written as `X and X(...) or nil`, the mistake was silent: the
    -- expression simply evaluated to nil, so the recipient looked offline and
    -- their copy was never handed out. A scan backs it up.
    local target = MDT.getSource and MDT.getSource(recipientCitizenId) or nil
    if not target then
        for _, pid in ipairs(GetPlayers()) do
            pid = tonumber(pid)
            if pid and MDT.getIdentifier(pid) == recipientCitizenId then
                target = pid
                break
            end
        end
    end
    if not target then
        -- Offline. No queue by design: the ticket is in their file and they
        -- will meet it at the next MDT contact or traffic stop. The item is a
        -- convenience, never the obligation.
        return
    end

    if MDT.isDebug and MDT.isDebug() then
        MDT.debug(('issueCopies: recipient %s -> src %s'):format(
            tostring(recipientCitizenId), tostring(target)))
    end
    giveCopy(target, 'citation_copy', number, row)
    -- Told either way: the paper is a convenience, the notice is what stops a
    -- ticket quietly ageing into a warrant.
    notifyRecipient(target, number, row.type == 'parking', row.fine_total)
end

-- Anti-spam. A citation writes a row, hands out two items and can escalate
-- into a warrant, so a client that can fire it in a loop is a way to fill the
-- table and somebody's inventory at the same time.
local lastIssue = {}

---@param src number
---@return boolean allowed
local function issueAllowed(src)
    local cd = (Config.Fines and tonumber(Config.Fines.CooldownMs)) or 30000
    local now = GetGameTimer()
    if lastIssue[src] and now - lastIssue[src] < cd then return false end
    lastIssue[src] = now
    return true
end

AddEventHandler('playerDropped', function()
    lastIssue[source] = nil
end)

--- Issue a ticket.
---@param src number issuing officer
---@param payload table
---@return table result
local function createCitation(src, payload)
    if cfg().Enabled == false then return { success = false, error = 'Citations are disabled' } end
    if type(payload) ~= 'table' then return { success = false, error = 'Invalid payload' } end

    if not issueAllowed(src) then
        return { success = false, error = 'You just issued a ticket — wait a moment' }
    end

    local ticketType = payload.type
    if ticketType ~= 'parking' and ticketType ~= 'warning' then ticketType = 'citation' end

    -- A parking ticket is written against a vehicle, so the plate is what makes
    -- it valid. A citation is written against a person.
    local plate = type(payload.plate) == 'string' and payload.plate:gsub('%s+', ''):upper() or nil
    if ticketType == 'parking' and (not plate or plate == '') then
        return { success = false, error = 'A parking ticket needs a plate' }
    end
    if (ticketType == 'citation' or ticketType == 'warning') and not payload.citizenid then
        return { success = false, error = 'A citation needs a recipient' }
    end

    -- A parking ticket is written against the CAR, so the person who answers
    -- for it is whoever the plate is registered to — resolved here rather than
    -- taken from the client, which has no business naming an owner. A citation
    -- is the other way round: the person is the subject and any vehicle is an
    -- addition to the description.
    if ticketType == 'parking' and plate then
        local owner = MySQL.single.await(
            'SELECT citizenid FROM player_vehicles WHERE plate = ?', { plate })
        if owner and owner.citizenid then
            payload.citizenid = owner.citizenid
            local prof = MySQL.single.await(
                'SELECT fullname FROM mdt_profiles WHERE citizenid = ?', { owner.citizenid })
            payload.recipientName = prof and prof.fullname or payload.recipientName
        elseif (cfg().AllowUnknownOwner == false) then
            return { success = false, error = 'That plate has no registered owner' }
        end
    end

    -- A warning draws on the same laws a citation does; only the money is
    -- dropped.
    local lookupType = ticketType == 'warning' and 'citation' or ticketType
    local chargesJson, fine, points, chargeErr = summariseCharges(payload.charges, lookupType)
    if chargeErr then return { success = false, error = chargeErr } end

    if ticketType == 'warning' then
        -- Zeroed here rather than trusted from the form: a warning that can
        -- carry a fine is just a citation with a friendlier name.
        fine = 0
        local decoded = json.decode(chargesJson)
        for i = 1, #decoded do decoded[i].fine = 0 end
        chargesJson = json.encode(decoded)
    end

    local officerId = MDT.getIdentifier(src)
    local dueDays = (cfg().DueDays or {})[ticketType] or 7
    local number = nextCitationNumber(ticketType)

    local id = MySQL.insert.await([[
        INSERT INTO mdt_citations
            (citation_number, type, citizenid, recipient_name, plate, vehicle, vehicle_color,
             officer_citizenid, officer_name, officer_callsign, officer_job,
             location, postal, speed_measured, speed_limit, notes,
             charges, fine_total, points_total, due_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? DAY))
    ]], {
        number, ticketType,
        payload.citizenid, payload.recipientName, plate, payload.vehicle, payload.vehicleColor,
        officerId,
        MDT.getPlayerName(src) or 'Unknown',
        MDT.getMetadata and MDT.getMetadata(src, 'callsign') or nil,
        -- The label, not the name: the paper names an agency, and 'police'
        -- is an identifier, not what a department is called.
        (function()
            local j = MDT.getJobData and MDT.getJobData(src)
            return (j and (j.label or j.name)) or (MDT.getJobName and MDT.getJobName(src)) or nil
        end)(),
        type(payload.location) == 'string' and payload.location:sub(1, 128) or nil,
        type(payload.postal) == 'string' and payload.postal:sub(1, 16) or nil,
        -- Clamped: a speed is a plausible number, not whatever a client sends.
        math.min(999, math.max(0, math.floor(tonumber(payload.speedMeasured) or 0))),
        math.min(999, math.max(0, math.floor(tonumber(payload.speedLimit) or 0))),
        type(payload.notes) == 'string' and payload.notes:sub(1, 500) or nil,
        chargesJson, fine, points,
        -- No due date on a warning: nothing is owed, so nothing can fall due.
        ticketType == 'warning' and 0 or dueDays,
    })

    if not id then return { success = false, error = 'Could not save the ticket' } end

    if MDT.auditLog then
        CreateThread(function()
            pcall(MDT.auditLog, src, 'citation_issued', 'citation', number, {
                type = ticketType,
                fine = fine,
                plate = plate,
                action_label = ('Issued %s %s'):format(
                    ticketType == 'parking' and 'parking ticket' or 'citation', number),
            })
        end)
    end

    -- Paper for both sides, deferred so a slow inventory can't hold up the
    -- officer's confirmation.
    CreateThread(function()
        pcall(issueCopies, src, number, payload.citizenid, { fine_total = fine, type = ticketType })
    end)

    return { success = true, id = id, number = number, fine = fine, points = points }
end

--- Mark a ticket settled. Called by whatever resource took the money — the MDT
--- has no opinion about how it was paid, only that it was.
---@param citationNumber string
---@param payerCitizenId string|nil
---@return boolean
function MarkCitationPaid(citationNumber, payerCitizenId)
    if type(citationNumber) ~= 'string' then return false end

    local row = MySQL.single.await(
        'SELECT id, status, fine_total, officer_job FROM mdt_citations WHERE citation_number = ?',
        { citationNumber })
    if not row then return false end
    -- Paying twice is not an error worth shouting about, but it must not
    -- deposit twice either.
    if row.status == 'paid' then return true end

    MySQL.update.await([[
        UPDATE mdt_citations
        SET status = 'paid', paid_at = CURRENT_TIMESTAMP, paid_by = ?
        WHERE id = ?
    ]], { payerCitizenId, row.id })

    -- The department collects. Same path impound fees already take, so servers
    -- only configure banking once.
    if DepositToDepartment and row.fine_total and row.fine_total > 0 then
        pcall(DepositToDepartment, row.officer_job, row.fine_total,
            ('Citation %s'):format(citationNumber))
    end

    return true
end

exports('MarkCitationPaid', MarkCitationPaid)

--- Everything owed by one person, newest first. Used by the profile tab.
---@param citizenid string
---@return table
local function citationsFor(citizenid)
    local rows = MySQL.query.await([[
        SELECT id, citation_number, type, plate, vehicle, officer_name, officer_callsign,
               location, charges, fine_total, points_total, status,
               DATE_FORMAT(issued_at, '%Y-%m-%d %H:%i') AS issued_at,
               DATE_FORMAT(due_at,    '%Y-%m-%d %H:%i') AS due_at,
               DATE_FORMAT(paid_at,   '%Y-%m-%d %H:%i') AS paid_at,
               DATE_FORMAT(signed_at, '%Y-%m-%d %H:%i') AS signed_at
        FROM mdt_citations
        WHERE citizenid = ?
        ORDER BY
            -- Unsettled first, then by age: what still needs doing is what an
            -- officer opening the profile is looking for.
            FIELD(status, 'overdue', 'open', 'paid', 'void'),
            issued_at DESC
    ]], { citizenid }) or {}

    for i = 1, #rows do
        local ok, decoded = pcall(json.decode, rows[i].charges)
        rows[i].charges = ok and decoded or {}
    end
    return rows
end

-- ── Callbacks ───────────────────────────────────────────────────────────────

lib.callback.register(resourceName .. ':server:createCitation', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end

    -- A Lua error in here used to travel back as nothing at all, which the form
    -- could only report as a timeout. The message is far more use than a shrug,
    -- and it lands in the server console as well.
    local ok, res = pcall(createCitation, src, payload)
    if not ok then
        MDT.error(('createCitation failed: %s'):format(tostring(res)))
        return { success = false, error = tostring(res):gsub('^.-:%d+:%s*', '') }
    end
    return res
end)

lib.callback.register(resourceName .. ':server:getCitations', function(source, citizenid)
    local src = source
    if not CheckAuth(src) then return {} end
    if type(citizenid) ~= 'string' then return {} end
    return citationsFor(citizenid)
end)

lib.callback.register(resourceName .. ':server:getCitation', function(source, citationNumber)
    local src = source
    if not CheckAuth(src) then return nil end
    local row = MySQL.single.await([[
        SELECT * FROM mdt_citations WHERE citation_number = ?
    ]], { citationNumber })
    if row then
        local ok, decoded = pcall(json.decode, row.charges)
        row.charges = ok and decoded or {}
    end
    return row
end)

lib.callback.register(resourceName .. ':server:voidCitation', function(source, citationNumber)
    local src = source
    if not CheckAuth(src) then return { success = false } end
    -- Voiding is deliberately not a delete: the record of a ticket having been
    -- written, and then withdrawn, is the part worth keeping.
    MySQL.update.await(
        "UPDATE mdt_citations SET status = 'void' WHERE citation_number = ? AND status <> 'paid'",
        { citationNumber })
    if MDT.auditLog then
        CreateThread(function()
            pcall(MDT.auditLog, src, 'citation_voided', 'citation', citationNumber, {
                action_label = 'Voided citation ' .. tostring(citationNumber),
            })
        end)
    end
    return { success = true }
end)

-- ── Overdue sweep ───────────────────────────────────────────────────────────
-- An unpaid fine cannot be answered with a larger fine, so the debt converts
-- into time. Warrants hang off a report in this schema, so the sweep files one
-- and attaches the warrant to it — which also gives the warrant a case that
-- explains why it exists.

local function monthsForFine(fine)
    local o = overdueCfg()
    local per = math.max(1, tonumber(o.DollarsPerMonth) or 250)
    local months = math.floor((tonumber(fine) or 0) / per)
    months = math.max(tonumber(o.MinMonths) or 1, months)
    return math.min(tonumber(o.MaxMonths) or 12, months)
end

local function escalate(row)
    local o = overdueCfg()
    local months = monthsForFine(row.fine_total)
    local title = ('%s %s'):format(o.ReportTitle or 'Failure to pay citation', row.citation_number)

    local reportId = MySQL.insert.await([[
        INSERT INTO mdt_reports (title, type, contentplaintext, author, authorplaintext, datecreated, dateupdated)
        VALUES (?, 'Warrant', ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    ]], {
        title,
        ('Citation %s was not settled by its due date. Outstanding: $%d.')
            :format(row.citation_number, row.fine_total or 0),
        row.officer_name or 'System',
        row.officer_name or 'System',
    })
    if not reportId then return end

    local class = ({ felonies = true, misdemeanors = true, infractions = true })[o.Class]
        and o.Class or 'infractions'

    MySQL.insert.await(([[
        INSERT INTO mdt_reports_warrants (reportid, citizenid, felonies, misdemeanors, infractions, expirydate)
        VALUES (?, ?, ?, ?, ?, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? MONTH))
        ON DUPLICATE KEY UPDATE %s = %s + VALUES(%s)
    ]]):format(class, class, class), {
        reportId, row.citizenid,
        class == 'felonies' and months or 0,
        class == 'misdemeanors' and months or 0,
        class == 'infractions' and months or 0,
        months,
    })

    MySQL.update.await(
        "UPDATE mdt_citations SET status = 'overdue', warrant_reportid = ? WHERE id = ?",
        { reportId, row.id })

    MDT.debug(('Citation %s overdue -> warrant (%d months)'):format(row.citation_number, months))
end

CreateThread(function()
    Wait(30000)
    while true do
        local o = overdueCfg()
        if cfg().Enabled ~= false and o.Enabled ~= false then
            local rows = MySQL.query.await([[
                SELECT id, citation_number, citizenid, fine_total, officer_name
                FROM mdt_citations
                WHERE status = 'open'
                  -- A warning carries no debt, so there is nothing to escalate.
                  AND type <> 'warning'
                  AND due_at IS NOT NULL
                  AND due_at < CURRENT_TIMESTAMP
                  AND warrant_reportid IS NULL
                  -- A ticket written against a plate with no known owner has
                  -- nobody to file a warrant against. It stays payable, it just
                  -- doesn't escalate into nothing.
                  AND citizenid IS NOT NULL
                -- Bounded. After a long outage there could be hundreds due at
                -- once; filing them all in one tick would write a report and a
                -- warrant per row on the server thread. The next pass picks up
                -- the rest a few minutes later, which is soon enough for a
                -- deadline that already passed.
                ORDER BY due_at ASC
                LIMIT 25
            ]]) or {}

            for i = 1, #rows do
                pcall(escalate, rows[i])
                -- Each escalation is two inserts and an update; yielding keeps
                -- a batch from holding the thread.
                Wait(50)
            end
        end
        Wait(math.max(1, tonumber(overdueCfg().CheckMinutes) or 30) * 60000)
    end
end)

--- Who are these players, on paper? Used by the recipient picker: the client
--- can see who is standing nearby, but names and profile pictures are the
--- server's to hand out.
lib.callback.register(resourceName .. ':server:describePlayers', function(source, serverIds)
    if not CheckAuth(source) then return {} end
    if type(serverIds) ~= 'table' then return {} end

    local out = {}
    for i = 1, math.min(#serverIds, 12) do
        local target = tonumber(serverIds[i])
        if target then
            local citizenid = MDT.getIdentifier(target)
            if citizenid then
                local row = MySQL.single.await(
                    'SELECT fullname, profilepicture FROM mdt_profiles WHERE citizenid = ?',
                    { citizenid })
                -- Three sources, in order of how the MDT itself would name
                -- them. getPlayerName returns the STEAM name on some
                -- frameworks, which is why charinfo comes before it.
                local name = row and row.fullname
                if not name or name == '' then
                    local ci = MDT.getCharInfo and MDT.getCharInfo(target)
                    if ci and ci.firstname then
                        name = ci.firstname .. ' ' .. (ci.lastname or '')
                    end
                end
                if not name or name == '' then name = MDT.getPlayerName(target) end

                out[tostring(target)] = {
                    citizenid = citizenid,
                    name = name and name ~= '' and name or ('ID ' .. target),
                    image = row and row.profilepicture or nil,
                }
            end
        end
    end
    return out
end)

-- Relay for the receiving half of a handover. The issuing officer knows who is
-- standing in front of them; only the server can tell that player to play it.
RegisterNetEvent('ps-mdt:server:ticketReceiveAnim', function(targetId, dict, clip, duration)
    local src = source
    if not CheckAuth(src) then return end
    targetId = tonumber(targetId)
    if not targetId or targetId <= 0 then return end

    -- Only somebody actually standing there can be handed a ticket, so the
    -- distance is re-checked here rather than trusted from the client.
    local a, b = GetPlayerPed(src), GetPlayerPed(targetId)
    if not a or not b or a == 0 or b == 0 then return end
    if #(GetEntityCoords(a) - GetEntityCoords(b)) > 8.0 then return end

    TriggerClientEvent('ps-mdt:client:ticketReceiveAnim', targetId, dict, clip, duration)
end)

--- Acknowledge receipt. Signing is not paying — it records that the ticket was
--- handed over and read, which is the moment an officer needs on the copy they
--- keep.
lib.callback.register(resourceName .. ':server:signCitation', function(source, number)
    local src = source
    local citizenid = MDT.getIdentifier(src)
    if not citizenid or type(number) ~= 'string' then return { success = false } end

    local row = MySQL.single.await(
        'SELECT id, citizenid, signed_at, officer_citizenid FROM mdt_citations WHERE citation_number = ?', { number })
    if not row then return { success = false, error = 'Unknown citation' } end
    -- Only the person it was written against can acknowledge it.
    if row.citizenid ~= citizenid then
        -- Say which, rather than a flat refusal: a recipient staring at a slip
        -- that will not sign has no way to tell why.
        return { success = false, error = 'This citation was written for somebody else' }
    end
    if row.signed_at then return { success = true } end

    MySQL.update.await(
        'UPDATE mdt_citations SET signed_at = CURRENT_TIMESTAMP, signed_by = ? WHERE id = ?',
        { citizenid, row.id })

    -- Tell the officer. They handed the paper over and then had no way of
    -- knowing whether it was acknowledged — which is half the reason the
    -- signature exists.
    if row.officer_citizenid then
        local officer = MDT.getSource and MDT.getSource(row.officer_citizenid)
        if not officer then
            for _, pid in ipairs(GetPlayers()) do
                pid = tonumber(pid)
                if pid and MDT.getIdentifier(pid) == row.officer_citizenid then
                    officer = pid
                    break
                end
            end
        end
        if officer then
            TriggerClientEvent('ps-mdt:client:citationSigned', officer, {
                number = number,
                name = MDT.getPlayerName(src) or nil,
            })
        end
    end

    return { success = true }
end)

--- Stored vehicle images for a set of plates. The picker shows the same picture
--- the Vehicles tab does, rather than a guessed file path — a server that has
--- set an image for a car should see it everywhere.
lib.callback.register(resourceName .. ':server:describeVehicles', function(source, plates)
    if not CheckAuth(source) then return {} end
    if type(plates) ~= 'table' or #plates == 0 then return {} end

    local clean = {}
    for i = 1, math.min(#plates, 12) do
        local p = tostring(plates[i]):gsub('%s+', ''):upper()
        if p ~= '' then clean[#clean + 1] = p end
    end
    if #clean == 0 then return {} end

    local placeholders = string.rep('?,', #clean - 1) .. '?'
    -- Only registered vehicles come back. An NPC car with no owner has nobody
    -- to answer for it, so ticketing it would write a record against nothing —
    -- the picker simply doesn't offer those.
    local rows = MySQL.query.await(([[
        SELECT pv.plate, pv.mdt_vehicle_image AS image, pv.citizenid, p.fullname
        FROM player_vehicles pv
        LEFT JOIN mdt_profiles p ON p.citizenid = pv.citizenid COLLATE utf8mb4_general_ci
        WHERE pv.plate IN (%s) AND pv.citizenid IS NOT NULL AND pv.citizenid <> ''
    ]]):format(placeholders), clean) or {}

    local out = {}
    for i = 1, #rows do
        out[rows[i].plate] = {
            image = (rows[i].image ~= '' and rows[i].image) or nil,
            citizenid = rows[i].citizenid,
            owner = rows[i].fullname,
        }
    end
    return out
end)

-- ── Paying a ticket ─────────────────────────────────────────────────────────
-- Settled in the civilian MDT, exactly like an impound fee. The citizen has the
-- ticket, so they should be able to pay it without finding an officer or a
-- third resource — and the MDT already owns both the record and the money path.

local function canPayCitations()
    local c = Config and Config.CivilianAccess
    return c and c.enabled == true and c.payCitations == true
end

lib.callback.register(resourceName .. ':server:payCitation', function(source, number)
    local src = source
    if not canPayCitations() then
        return { success = false, message = 'Paying citations is disabled' }
    end

    local citizenid = MDT.getIdentifier(src)
    if not citizenid or type(number) ~= 'string' then
        return { success = false, message = 'Unknown citation' }
    end

    local row = MySQL.single.await([[
        SELECT id, citizenid, fine_total, status, officer_job
        FROM mdt_citations WHERE citation_number = ?
    ]], { number })
    if not row then return { success = false, message = 'Unknown citation' } end
    -- Your own tickets only. Settling somebody else's is not generosity, it is
    -- a way to clear a stranger's record.
    if row.citizenid ~= citizenid then
        return { success = false, message = 'That is not your citation' }
    end
    if row.status == 'paid' then
        return { success = false, message = 'This ticket has just been paid' }
    end
    if row.status == 'void' then
        return { success = false, message = 'This ticket was withdrawn' }
    end

    local owed = tonumber(row.fine_total) or 0
    if owed <= 0 then
        return { success = false, message = 'A warning carries no fine' }
    end

    local account = (Config.Citations and Config.Citations.PayAccount) or 'bank'
    local removed = MDT.removeMoney(src, account, owed, 'mdt-citation-fine')
    if not removed then
        return { success = false, message = 'Not enough money in your ' .. account }
    end

    -- One path for marking paid, so the department is credited the same way no
    -- matter who settled it.
    MarkCitationPaid(number, citizenid)
    return { success = true, paid = owed }
end)

--- A citizen's own citations. Separate from getCitations, which is gated on
--- CheckAuth — that gate is right for an officer looking up somebody else and
--- wrong for a civilian looking at their own file, which is why the civilian
--- MDT came back empty.
---
--- No citizenid parameter on purpose: it is taken from the caller, so this can
--- only ever return your own.
lib.callback.register(resourceName .. ':server:getMyCitations', function(source)
    local citizenid = MDT.getIdentifier(source)
    if not citizenid then return {} end
    return citationsFor(citizenid)
end)

-- ═══════════════════════════════════════════════════════════════════════════
--  Contesting a citation
-- ═══════════════════════════════════════════════════════════════════════════
-- Refusing to sign now means something: the recipient disputes the ticket, the
-- deadline stops, and a court rules. Three accounts go into that decision —
-- the ticket as written, the citizen's reason, and the officer's statement —
-- because a judge holding only the form and a complaint is choosing between
-- two assertions.

local function contestCfg()
    return (cfg().Contest) or {}
end

--- Dispute a ticket. Only your own, only while it is still owed.
lib.callback.register(resourceName .. ':server:contestCitation', function(source, payload)
    local src = source
    if contestCfg().Enabled == false then
        return { success = false, error = 'Contesting is disabled' }
    end

    local citizenid = MDT.getIdentifier(src)
    local number = type(payload) == 'table' and payload.number or nil
    local reason = type(payload) == 'table' and payload.reason or nil
    if not citizenid or type(number) ~= 'string' then
        return { success = false, error = 'Unknown citation' }
    end

    local minLen = tonumber(contestCfg().MinReasonLength) or 20
    if type(reason) ~= 'string' or #reason < minLen then
        return { success = false, error = ('Give a reason of at least %d characters'):format(minLen) }
    end
    reason = reason:sub(1, tonumber(contestCfg().MaxReasonLength) or 1000)

    local row = MySQL.single.await([[
        SELECT id, citizenid, status, type, officer_citizenid, citation_number
        FROM mdt_citations WHERE citation_number = ?
    ]], { number })
    if not row then return { success = false, error = 'Unknown citation' } end
    if row.citizenid ~= citizenid then
        return { success = false, error = 'That citation was written for somebody else' }
    end
    -- Paying is acceptance. A warning has nothing to dispute.
    if row.status == 'paid' then return { success = false, error = 'You already paid this ticket' } end
    if row.status == 'void' then return { success = false, error = 'This ticket was already withdrawn' } end
    if row.status == 'contested' then return { success = false, error = 'You already contested this ticket' } end
    if row.type == 'warning' then return { success = false, error = 'A warning carries nothing to contest' } end

    local days = tonumber(contestCfg().DeadlineDays) or 7
    MySQL.update.await([[
        UPDATE mdt_citations
        SET status = 'contested',
            contested_at = CURRENT_TIMESTAMP,
            contest_reason = ?,
            contest_deadline = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? DAY)
        WHERE id = ?
    ]], { reason, days, row.id })

    -- The officer gets to put their side on record before the hearing. Their
    -- silence is itself something a judge can weigh, so this is an invitation
    -- rather than a requirement.
    if contestCfg().NotifyOfficer ~= false and row.officer_citizenid then
        local officer = MDT.getSource and MDT.getSource(row.officer_citizenid)
        if not officer then
            for _, pid in ipairs(GetPlayers()) do
                pid = tonumber(pid)
                if pid and MDT.getIdentifier(pid) == row.officer_citizenid then officer = pid break end
            end
        end
        if officer then
            TriggerClientEvent('ps-mdt:client:citationContested', officer, { number = number })
        end
    end

    if MDT.auditLog then
        CreateThread(function()
            pcall(MDT.auditLog, src, 'citation_contested', 'citation', number, {
                action_label = 'Contested citation ' .. number,
            })
        end)
    end

    return { success = true, deadlineDays = days }
end)

--- The officer's account of the stop, added after the fact.
lib.callback.register(resourceName .. ':server:citationStatement', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end

    local number = type(payload) == 'table' and payload.number or nil
    local text = type(payload) == 'table' and payload.statement or nil
    if type(number) ~= 'string' or type(text) ~= 'string' or text == '' then
        return { success = false, error = 'Nothing to file' }
    end

    local citizenid = MDT.getIdentifier(src)
    local row = MySQL.single.await(
        'SELECT id, officer_citizenid FROM mdt_citations WHERE citation_number = ?', { number })
    if not row then return { success = false, error = 'Unknown citation' } end
    -- Only the officer who wrote it. A colleague's recollection of a stop they
    -- were not at is not evidence.
    if row.officer_citizenid ~= citizenid then
        return { success = false, error = 'Only the issuing officer can file a statement' }
    end

    MySQL.update.await([[
        UPDATE mdt_citations SET officer_statement = ?, statement_at = CURRENT_TIMESTAMP WHERE id = ?
    ]], { text:sub(1, tonumber(contestCfg().MaxReasonLength) or 1000), row.id })

    return { success = true }
end)

--- Every contested ticket, for the DOJ. Returns the whole picture in one read:
--- the ticket as written, both accounts, and the timeline — so a judge is not
--- choosing between two assertions with the paperwork somewhere else.
lib.callback.register(resourceName .. ':server:getContested', function(source)
    if not CheckAuth(source) then return {} end

    -- An officer sees only the challenges against tickets THEY wrote: those are
    -- the ones they can answer, and a colleague's stop is not theirs to account
    -- for. The court sees all of them, because deciding is its job.
    local isCourt = MDT.getJobType and MDT.getJobType(source) == 'doj'
    local mine = (not isCourt) and MDT.getIdentifier(source) or nil

    local rows = MySQL.query.await([[
        SELECT id, citation_number, type, citizenid, recipient_name, plate, vehicle,
               officer_name, officer_callsign, officer_job, location,
               speed_measured, speed_limit, notes, charges,
               fine_total, original_fine, signed_at,
               contest_reason, officer_statement,
               DATE_FORMAT(issued_at,        '%Y-%m-%d %H:%i') AS issued_at,
               DATE_FORMAT(contested_at,     '%Y-%m-%d %H:%i') AS contested_at,
               DATE_FORMAT(statement_at,     '%Y-%m-%d %H:%i') AS statement_at,
               DATE_FORMAT(contest_deadline, '%Y-%m-%d %H:%i') AS contest_deadline,
               TIMESTAMPDIFF(HOUR, CURRENT_TIMESTAMP, contest_deadline) AS hours_left
        FROM mdt_citations
        WHERE status = 'contested'
          AND (? IS NULL OR officer_citizenid = ?)
        -- Closest to lapsing first: an unheard challenge is dismissed, so the
        -- one about to expire is the one the court needs to look at.
        ORDER BY contest_deadline ASC
    ]], { mine, mine }) or {}

    for i = 1, #rows do
        local ok, decoded = pcall(json.decode, rows[i].charges)
        rows[i].charges = ok and decoded or {}
    end
    return rows
end)

--- Rule on a challenge.
---@param payload table { number, verdict = 'upheld'|'dismissed'|'reduced', fine?, note? }
lib.callback.register(resourceName .. ':server:citationVerdict', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end

    local number = type(payload) == 'table' and payload.number or nil
    local verdict = type(payload) == 'table' and payload.verdict or nil
    if type(number) ~= 'string' or not ({ upheld = true, dismissed = true, reduced = true })[verdict] then
        return { success = false, error = 'Invalid verdict' }
    end

    local row = MySQL.single.await([[
        SELECT id, status, fine_total, original_fine FROM mdt_citations WHERE citation_number = ?
    ]], { number })
    if not row then return { success = false, error = 'Unknown citation' } end
    if row.status ~= 'contested' then return { success = false, error = 'This citation is not under challenge' } end

    local judge = MDT.getPlayerName(src) or 'Court'
    local note = type(payload.note) == 'string' and payload.note:sub(1, 1000) or nil

    if verdict == 'dismissed' then
        -- Thrown out: nothing owed, and the record says why rather than simply
        -- vanishing.
        MySQL.update.await([[
            UPDATE mdt_citations
            SET status = 'void', verdict = 'dismissed', verdict_by = ?, verdict_note = ?,
                verdict_at = CURRENT_TIMESTAMP
            WHERE id = ?
        ]], { judge, note, row.id })

    elseif verdict == 'reduced' then
        local newFine = math.max(0, math.floor(tonumber(payload.fine) or 0))
        local cap = tonumber(row.fine_total) or 0
        -- A court may lower a fine, not raise one. Anything else would turn
        -- disputing a ticket into a gamble.
        if newFine > cap then newFine = cap end
        local days = (cfg().DueDays or {}).citation or 7
        MySQL.update.await(([[
            UPDATE mdt_citations
            SET status = 'open', fine_total = ?,
                original_fine = COALESCE(original_fine, %d),
                verdict = 'reduced', verdict_by = ?, verdict_note = ?,
                verdict_at = CURRENT_TIMESTAMP,
                due_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? DAY)
            WHERE id = ?
        ]]):format(cap), { newFine, judge, note, days, row.id })

    else -- upheld
        -- Stands, and the clock starts again from today: somebody who waited on
        -- a hearing should not find the ticket already overdue.
        local days = (cfg().DueDays or {}).citation or 7
        MySQL.update.await([[
            UPDATE mdt_citations
            SET status = 'open', verdict = 'upheld', verdict_by = ?, verdict_note = ?,
                verdict_at = CURRENT_TIMESTAMP,
                due_at = DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? DAY)
            WHERE id = ?
        ]], { judge, note, days, row.id })
    end

    return { success = true }
end)

-- Challenges nobody heard. The deadline is the department's to meet, so a
-- lapsed one goes the citizen's way — the alternative is a fine that grows
-- while somebody waits for a hearing that never comes.
CreateThread(function()
    Wait(45000)
    while true do
        if cfg().Enabled ~= false and contestCfg().Enabled ~= false then
            local lapsed = MySQL.query.await([[
                SELECT id, citation_number FROM mdt_citations
                WHERE status = 'contested'
                  AND contest_deadline IS NOT NULL
                  AND contest_deadline < CURRENT_TIMESTAMP
                LIMIT 25
            ]]) or {}

            for i = 1, #lapsed do
                MySQL.update.await([[
                    UPDATE mdt_citations
                    SET status = 'void', verdict = 'dismissed', verdict_by = 'Court (no hearing)',
                        verdict_note = 'Dismissed: not heard before the deadline.',
                        verdict_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                ]], { lapsed[i].id })
                MDT.debug(('Contest lapsed -> dismissed: %s'):format(lapsed[i].citation_number))
                Wait(50)
            end
        end
        Wait(math.max(1, tonumber(overdueCfg().CheckMinutes) or 30) * 60000)
    end
end)
