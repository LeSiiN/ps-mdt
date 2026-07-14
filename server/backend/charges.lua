local resourceName = tostring(GetCurrentResourceName())

-- Phase 3: charges gain a real, editable `category` column (previously the
-- category was derived from charge_class). Self-healing migration + a one-time
-- backfill from the old class-based grouping so existing rows keep a sensible
-- category instead of being blank.
CreateThread(function()
    Wait(2500)
    if EnsureColumn then
        local added = EnsureColumn('mdt_penal_codes', 'category', "`category` varchar(100) NOT NULL DEFAULT ''")
        if added then
            pcall(MySQL.query.await, [[
                UPDATE mdt_penal_codes SET category = CASE
                    WHEN charge_class = 'felony' THEN 'Offenses Against Persons'
                    WHEN charge_class = 'misdemeanor' THEN 'Offenses Against Public Order'
                    WHEN charge_class = 'infraction' THEN 'Offenses Against Public Safety'
                    ELSE 'Uncategorized' END
                WHERE category = '' OR category IS NULL
            ]])
        end
    end
end)

ps.registerCallback('ps-mdt:getChargeList', function(source)
    -- Allow civilians to view charges (legislation) if civilian access is enabled
    local civAccess = Config.CivilianAccess
    if not CheckAuth(source) and not (civAccess and civAccess.enabled) then return {} end

    local rows = MySQL.query.await([[
        SELECT
            code,
            label,
            charge_class AS type,
            description,
            months AS time,
            fine,
            color,
            COALESCE(NULLIF(category, ''), CASE
                WHEN charge_class = 'felony' THEN 'Offenses Against Persons'
                WHEN charge_class = 'misdemeanor' THEN 'Offenses Against Public Order'
                WHEN charge_class = 'infraction' THEN 'Offenses Against Public Safety'
                ELSE 'Uncategorized'
            END) AS category
        FROM mdt_penal_codes
        ORDER BY category, charge_class, label
    ]], {})
    ps.debug('[getChargeList] rows', rows and #rows or 0)
    if Config and Config.Debug and rows and rows[1] then
        ps.debug('[getChargeList] sample', rows[1])
    end
    return rows
end)

-- Process a fine - deduct money from citizen's bank account
-- Ported from ps-mdt v1 (mdt:server:removeMoney)
local fineCooldowns = {}
ps.registerCallback(resourceName .. ':server:processFine', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end

    payload = payload or {}
    local citizenId = payload.citizenid
    local fine = tonumber(payload.fine)
    local reportId = payload.reportId

    if not citizenId or not fine or fine ~= fine or fine <= 0 then
        return { success = false, message = 'Missing citizen ID or invalid fine amount' }
    end

    fine = math.floor(fine)

    local jfConfig = GetJailFinesConfig and GetJailFinesConfig() or {}
    local maxFine = jfConfig.maxFineAmount or (Config and Config.Fines and Config.Fines.MaxAmount) or 100000
    if fine > maxFine then
        return { success = false, message = 'Fine amount exceeds maximum of $' .. maxFine }
    end

    local now = os.time() * 1000
    local cooldownMs = (Config and Config.Fines and Config.Fines.CooldownMs) or 30000
    if fineCooldowns[src] and (now - fineCooldowns[src]) < cooldownMs then
        return { success = false, message = 'Fine processing on cooldown' }
    end

    -- Try to get online player first
    local Player = ps.getPlayerByIdentifier(citizenId)
    if not Player then
        return { success = false, message = 'Player must be online to process fine' }
    end

    -- Remove money from bank
    local removed = ps.removeMoney(Player.source or Player.PlayerData.source, 'bank', fine, 'mdt-fine')
    if removed then
        -- ...and into the department that issued it. Fines used to simply evaporate.
        DepositToDepartment(ps.getJobName(src), fine, 'Fine issued')

        ps.notify(Player.source or Player.PlayerData.source, '$' .. fine .. ' fine deducted from your bank account', 'error')

        -- Anti-spam cooldown
        fineCooldowns[src] = os.time() * 1000

        if ps.auditLog then
            local officerName = ps.getPlayerName(src) or 'Unknown Officer'
            ps.auditLog(src, 'fine_processed', 'fine', reportId and tostring(reportId) or nil, {
                citizenid = citizenId,
                fine = fine,
                officer = officerName,
            })
        end

        return { success = true, message = 'Fine of $' .. fine .. ' processed' }
    else
        return { success = false, message = 'Failed to remove money - insufficient funds?' }
    end
end)

ps.registerCallback(resourceName .. ':server:updateCharge', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'charges_edit') then
        return { success = false, message = 'You do not have permission to edit charges' }
    end

    payload = payload or {}
    if not payload.code then
        return { success = false, message = 'Missing charge code' }
    end

    local penalUpdates = {}
    local penalValues = {}
    if payload.fine ~= nil then
        penalUpdates[#penalUpdates + 1] = 'fine = ?'
        penalValues[#penalValues + 1] = math.max(0, tonumber(payload.fine) or 0)
    end
    if payload.time ~= nil then
        penalUpdates[#penalUpdates + 1] = 'months = ?'
        penalValues[#penalValues + 1] = math.max(0, tonumber(payload.time) or 0)
    end
    if payload.label ~= nil and type(payload.label) == 'string' and payload.label ~= '' then
        penalUpdates[#penalUpdates + 1] = 'label = ?'
        penalValues[#penalValues + 1] = payload.label
    end
    if payload.description ~= nil and type(payload.description) == 'string' then
        penalUpdates[#penalUpdates + 1] = 'description = ?'
        penalValues[#penalValues + 1] = payload.description
    end
    if payload.category ~= nil and type(payload.category) == 'string' then
        penalUpdates[#penalUpdates + 1] = 'category = ?'
        penalValues[#penalValues + 1] = payload.category
    end
    if payload.color ~= nil and type(payload.color) == 'string' and payload.color ~= '' then
        penalUpdates[#penalUpdates + 1] = 'color = ?'
        penalValues[#penalValues + 1] = payload.color
    end
    -- charge_class is an enum; only accept valid values.
    local validClass = { felony = true, misdemeanor = true, infraction = true }
    local newType = payload.type or payload.charge_class
    if newType ~= nil and validClass[newType] then
        penalUpdates[#penalUpdates + 1] = 'charge_class = ?'
        penalValues[#penalValues + 1] = newType
    end
    -- Optional code (primary key) rename. Reports reference charges by LABEL
    -- (FK on label, cascading), so renaming the code is safe and doesn't touch
    -- report data. Reject a rename that collides with an existing code.
    local renameCode = nil
    if payload.newCode ~= nil and type(payload.newCode) == 'string'
        and payload.newCode ~= '' and payload.newCode ~= payload.code then
        local clash = MySQL.single.await('SELECT code FROM mdt_penal_codes WHERE code = ?', { payload.newCode })
        if clash then
            return { success = false, message = 'A charge with that code already exists' }
        end
        renameCode = payload.newCode
        penalUpdates[#penalUpdates + 1] = 'code = ?'
        penalValues[#penalValues + 1] = renameCode
    end

    if #penalUpdates == 0 then
        return { success = true }
    end

    penalValues[#penalValues + 1] = payload.code
    local penalUpdated = MySQL.update.await(([[
        UPDATE mdt_penal_codes
        SET %s
        WHERE code = ?
    ]]):format(table.concat(penalUpdates, ', ')), penalValues)

    if penalUpdated and penalUpdated > 0 and ps.auditLog then
        ps.auditLog(src, 'charge_updated', 'charge', renameCode or payload.code, {
            label = payload.label,
            fine = payload.fine,
            time = payload.time,
            description = payload.description,
            category = payload.category,
            renamedFrom = renameCode and payload.code or nil,
        })
    end
    return { success = penalUpdated and penalUpdated > 0, code = renameCode or payload.code }
end)

-- ---------------------------------------------------------------------------
-- Phase 3: charge CRUD (create / delete) + category listing
-- ---------------------------------------------------------------------------

local validChargeClass = { felony = true, misdemeanor = true, infraction = true }

ps.registerCallback(resourceName .. ':server:createCharge', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'charges_edit') then
        return { success = false, message = 'You do not have permission to manage charges' }
    end

    payload = payload or {}
    local code = type(payload.code) == 'string' and payload.code:gsub('^%s+', ''):gsub('%s+$', '') or ''
    local label = type(payload.label) == 'string' and payload.label:gsub('^%s+', ''):gsub('%s+$', '') or ''
    local class = payload.type or payload.charge_class

    if code == '' or label == '' then
        return { success = false, message = 'Code and label are required' }
    end
    if not validChargeClass[class] then
        return { success = false, message = 'Invalid charge class' }
    end

    local clash = MySQL.single.await('SELECT code FROM mdt_penal_codes WHERE code = ?', { code })
    if clash then
        return { success = false, message = 'A charge with that code already exists' }
    end

    local ok = MySQL.insert.await([[
        INSERT INTO mdt_penal_codes (code, label, charge_class, months, fine, color, description, category)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        code,
        label,
        class,
        math.max(0, tonumber(payload.time) or tonumber(payload.months) or 0),
        math.max(0, tonumber(payload.fine) or 0),
        type(payload.color) == 'string' and payload.color ~= '' and payload.color or '#6b7280',
        type(payload.description) == 'string' and payload.description or '',
        type(payload.category) == 'string' and payload.category or '',
    })

    if ok and ps.auditLog then
        ps.auditLog(src, 'charge_created', 'charge', code, { label = label, class = class })
    end
    return { success = ok ~= nil, code = code }
end)

ps.registerCallback(resourceName .. ':server:deleteCharge', function(source, payload)
    local src = source
    if not CheckAuth(src) then return { success = false, message = 'Unauthorized' } end
    if not CheckPermission(src, 'charges_edit') then
        return { success = false, message = 'You do not have permission to manage charges' }
    end

    payload = payload or {}
    if not payload.code then
        return { success = false, message = 'Missing charge code' }
    end

    local charge = MySQL.single.await('SELECT code, label FROM mdt_penal_codes WHERE code = ?', { payload.code })
    if not charge then
        return { success = false, message = 'Charge not found' }
    end

    -- Data integrity: reports reference charges by label with ON DELETE CASCADE,
    -- so deleting an in-use charge would strip it from existing reports. Block it
    -- unless the caller explicitly forces the deletion.
    local usage = MySQL.single.await(
        'SELECT COUNT(*) AS n FROM mdt_reports_charges WHERE charge = ?', { charge.label }
    )
    local inUse = (usage and tonumber(usage.n) or 0)
    if inUse > 0 and not payload.force then
        return {
            success = false,
            inUse = inUse,
            message = ('This charge is used in %d report%s. Confirm to delete it everywhere.'):format(
                inUse, inUse == 1 and '' or 's'),
        }
    end

    local deleted = MySQL.update.await('DELETE FROM mdt_penal_codes WHERE code = ?', { payload.code })
    if deleted and deleted > 0 and ps.auditLog then
        ps.auditLog(src, 'charge_deleted', 'charge', payload.code, {
            label = charge.label, forcedInUse = inUse > 0 or nil,
        })
    end
    return { success = deleted and deleted > 0 }
end)

ps.registerCallback(resourceName .. ':server:getChargeCategories', function(source)
    local civAccess = Config.CivilianAccess
    if not CheckAuth(source) and not (civAccess and civAccess.enabled) then return {} end
    local rows = MySQL.query.await([[
        SELECT DISTINCT category FROM mdt_penal_codes
        WHERE category IS NOT NULL AND category != ''
        ORDER BY category
    ]], {})
    local out = {}
    for _, r in ipairs(rows or {}) do out[#out + 1] = r.category end
    return out
end)