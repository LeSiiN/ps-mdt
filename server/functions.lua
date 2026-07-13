function GetActiveUnits()
    return ps.getJobCount("police")
end

--- Normalise a free-text search query for consistent, predictable LIKE matching
--- across every search callback. Trims, collapses internal whitespace to single
--- spaces, lowercases, and escapes LIKE wildcards (% _ \) so user input is
--- treated literally (no accidental "match everything" / expensive scans).
---
--- Returns three values:
---   norm       - the cleaned, lowercased term (nil if the query is empty)
---   likePat    - '%term%' ready to bind to a LIKE placeholder
---   plateLike  - like likePat but with ALL spaces removed, so "AB 123",
---                "ab123" and "a b123" all match the same plate
---
--- Columns in this schema use a *_ci collation, so LIKE is already
--- case-insensitive; lowercasing keeps our own handling deterministic and lines
--- up with any LOWER()-wrapped columns.
---@param query any
---@return string|nil norm, string|nil likePat, string|nil plateLike
function NormalizeSearch(query)
    if query == nil then return nil end
    local s = tostring(query)
    s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    s = s:lower()
    -- escape LIKE wildcards so they match literally
    local escaped = s:gsub('([%%_\\])', '\\%1')
    local likePat = '%' .. escaped .. '%'
    local plateLike = '%' .. escaped:gsub(' ', '') .. '%'
    return s, likePat, plateLike
end

--- Returns a callsign only if it is safe to write to mdt_profiles for this
--- citizen. The callsign column has a UNIQUE index, so assigning a value that
--- another profile already owns throws a "Duplicate entry" error and aborts
--- whatever transaction is running (e.g. the login session upsert). This
--- normalises blank/sentinel values to nil and returns nil when the callsign is
--- already taken by a different citizen, so the caller keeps the existing value
--- (via COALESCE) or inserts NULL instead of crashing.
---@param callsign string|nil
---@param citizenid string|nil
---@return string|nil
function GetAssignableCallsign(callsign, citizenid)
    if callsign == 'NO CALLSIGN' or callsign == '' then callsign = nil end
    if not callsign then return nil end

    local taken = MySQL.scalar.await(
        'SELECT 1 FROM mdt_profiles WHERE callsign = ? AND citizenid != ? LIMIT 1',
        { callsign, citizenid or '' }
    )
    if taken then
        ps.warn(('Callsign "%s" is already in use - not assigning it to %s'):format(tostring(callsign), tostring(citizenid)))
        return nil
    end

    return callsign
end

--- Check if a job is a police/LEO job based on Config.PoliceJobs and Config.PoliceJobType
---@param jobName string|nil -- The job name to check (e.g. 'lspd', 'bcso')
---@param jobType string|nil -- The job type to check (e.g. 'leo')
---@return boolean
function IsPoliceJob(jobName, jobType)
    if jobType and Config and Config.PoliceJobType and tostring(jobType) == tostring(Config.PoliceJobType) then
        return true
    end
    if jobName and Config and Config.PoliceJobs then
        local check = tostring(jobName)
        for _, job in ipairs(Config.PoliceJobs) do
            if tostring(job) == check then
                return true
            end
        end
    end
    return false
end

--- Check if a job is a medical/EMS job based on Config.MedicalJobs and Config.MedicalJobType
---@param jobName string|nil
---@param jobType string|nil
---@return boolean
function IsEmsJob(jobName, jobType)
    if jobType and Config and Config.MedicalJobType and tostring(jobType) == tostring(Config.MedicalJobType) then
        return true
    end
    if jobName and Config and Config.MedicalJobs then
        local check = tostring(jobName)
        for _, job in ipairs(Config.MedicalJobs) do
            if tostring(job) == check then
                return true
            end
        end
    end
    return false
end

--- The MDT "domain" a job belongs to. Police and DOJ share the 'police' domain
--- (so their calendar / map data stays together); EMS is its own 'ems' domain.
---@param jobName string|nil
---@param jobType string|nil
---@return "police"|"ems"
function GetDomainForJob(jobName, jobType)
    if IsEmsJob(jobName, jobType) then return 'ems' end
    return 'police'
end

--- The MDT domain for an online player source.
---@param src number
---@return "police"|"ems"
--- Self-healing schema helper: add a column if it doesn't already exist.
--- Lets backends introduce a new column (e.g. a domain marker) without shipping
--- a manual migration. No-op if the column is already present.
---@param tableName string
---@param columnName string
---@param definition string -- full column definition, e.g. "`job_type` varchar(10) NOT NULL DEFAULT 'police'"
---@return boolean added
function EnsureColumn(tableName, columnName, definition)
    local exists = MySQL.single.await([[
        SELECT 1 AS x FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], { tableName, columnName })
    if exists then return false end
    local ok = pcall(MySQL.query.await, ('ALTER TABLE `%s` ADD COLUMN %s'):format(tableName, definition))
    if ok and Config and Config.Debug then
        print(('[ps-mdt] added column %s.%s'):format(tableName, columnName))
    end
    return ok
end

function GetMdtDomain(src)
    local jobName = ps.getJobName and ps.getJobName(src) or nil
    local jobType = ps.getJobType and ps.getJobType(src) or nil
    return GetDomainForJob(jobName, jobType)
end


--- Ensure an MDT profile exists for a citizen. Resolves name from online player or DB if offline.
---@param citizenid string -- The citizen ID to ensure a profile for
---@return boolean -- true if profile exists or was created, false on failure
function EnsureProfileExists(citizenid)
    if not citizenid then return false end

    local exists = MySQL.scalar.await('SELECT COUNT(*) FROM mdt_profiles WHERE citizenid = ?', { citizenid })
    if exists and exists > 0 then
        return true
    end

    -- Try online player first
    local playerData = ps.getPlayerByIdentifier(citizenid)
    if playerData then
        playerData = playerData.PlayerData
        local charinfo = playerData.charinfo
        local fullname = charinfo.firstname .. ' ' .. charinfo.lastname
        local callsign = playerData.metadata and playerData.metadata.callsign or nil
        callsign = GetAssignableCallsign(callsign, citizenid)

        local success = MySQL.insert.await([[
            INSERT INTO mdt_profiles (citizenid, fullname, callsign)
            VALUES(?, ?, ?)
        ]], { citizenid, fullname, callsign })

        if success then
            ps.debug('Auto-created MDT profile for: ' .. citizenid)
            return true
        end
        ps.warn('Failed to create MDT profile for: ' .. citizenid)
        return false
    end

    -- Fallback: resolve from players table (offline player)
    local row = MySQL.single.await('SELECT charinfo, metadata FROM players WHERE citizenid = ? LIMIT 1', { citizenid })
    if not row then
        ps.warn('No player data found for citizenid: ' .. citizenid)
        return false
    end

    local charinfo = row.charinfo and json.decode(row.charinfo) or {}
    local metadata = row.metadata and json.decode(row.metadata) or {}
    local fullname = ((charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    local callsign = metadata.callsign
    callsign = GetAssignableCallsign(callsign, citizenid)

    local success = MySQL.insert.await([[
        INSERT INTO mdt_profiles (citizenid, fullname, callsign)
        VALUES(?, ?, ?)
    ]], { citizenid, fullname ~= '' and fullname or 'Unknown', callsign })

    if success then
        ps.debug('Auto-created MDT profile for: ' .. citizenid)
        return true
    end
    ps.warn('Failed to create MDT profile for: ' .. citizenid)
    return false
end

function EnsureProfileData(citizenid, fullname, callsign, badgeNumber, rank, department)
    if not citizenid then
        return nil
    end

    -- Sanitize callsign and skip it if another profile already owns it
    -- (UNIQUE index would otherwise throw and abort the caller's transaction).
    callsign = GetAssignableCallsign(callsign, citizenid)

    local profile = MySQL.single.await('SELECT id FROM mdt_profiles WHERE citizenid = ?', { citizenid })
    if profile and profile.id then
        -- Try the full update; if it still trips the callsign UNIQUE index for
        -- any reason (e.g. a race), retry once without touching the callsign so
        -- the profile/session is never lost over a callsign clash.
        local ok = pcall(MySQL.update.await, [[UPDATE mdt_profiles
            SET fullname = COALESCE(?, fullname),
                callsign = COALESCE(?, callsign),
                badge_number = COALESCE(?, badge_number),
                rank = COALESCE(?, rank),
                department = COALESCE(?, department)
            WHERE citizenid = ?
        ]], { fullname, callsign, badgeNumber, rank, department, citizenid })

        if not ok then
            ps.warn(('EnsureProfileData: update failed for %s, retrying without callsign'):format(tostring(citizenid)))
            pcall(MySQL.update.await, [[UPDATE mdt_profiles
                SET fullname = COALESCE(?, fullname),
                    badge_number = COALESCE(?, badge_number),
                    rank = COALESCE(?, rank),
                    department = COALESCE(?, department)
                WHERE citizenid = ?
            ]], { fullname, badgeNumber, rank, department, citizenid })
        end

        return profile.id
    end

    local okInsert, result = pcall(MySQL.insert.await, [[INSERT INTO mdt_profiles
        (citizenid, fullname, callsign, badge_number, rank, department)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { citizenid, fullname or 'Unknown', callsign, badgeNumber, rank, department })

    if not okInsert then
        -- Insert failed (most likely the callsign clash). Retry without callsign.
        ps.warn(('EnsureProfileData: insert failed for %s, retrying without callsign'):format(tostring(citizenid)))
        okInsert, result = pcall(MySQL.insert.await, [[INSERT INTO mdt_profiles
            (citizenid, fullname, badge_number, rank, department)
            VALUES (?, ?, ?, ?, ?)
        ]], { citizenid, fullname or 'Unknown', badgeNumber, rank, department })
    end

    if not okInsert then
        ps.error(('EnsureProfileData: could not create profile for %s: %s'):format(tostring(citizenid), tostring(result)))
        return nil
    end

    return result
end

-- Returns the owner of a vehicle based on its license plate.
---@param plate string -- The license plate of the vehicle to check
---@return string -- The name of the vehicle owner or "Unknown Owner" if not found
function GetVehicleOwner(plate)
    if not plate then
        return "Unknown Owner"
    end

    -- Sanitise plate input
    plate = string.gsub(plate, "%s+", "") -- Remove spaces
    plate = string.upper(plate) -- Convert to uppercase
    ps.debug('Fetching vehicle owner for plate: ' .. plate)

    -- Fetch the owner
    local result = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    ps.debug('Vehicle owner result: ' .. tostring(result))

    if result then
        -- If a result is found, get the player's name
        local playerName = ps.getPlayerNameByIdentifier(result)
        ps.debug('Vehicle owner name: ' .. tostring(playerName))
        if playerName and playerName ~= 'Unknown Person' then
            return playerName
        end
    end

    -- If no owner or player name is found, return "Unknown Owner"
    ps.debug('No owner found for plate: ' .. plate)
    return "Unknown Owner"
end

function GetBoloStatus(plate)
    if not plate then return false, "", "" end
    plate = string.gsub(plate, "%s+", "")
    plate = string.upper(plate)

    local result = MySQL.single.await([[
        SELECT id, subject_name, notes
        FROM mdt_bolos
        WHERE type = 'vehicle'
          AND status = 'active'
          AND UPPER(REPLACE(subject_id, ' ', '')) = ?
        LIMIT 1
    ]], { plate })

    if result then
        return true, result.subject_name or result.notes or "Active BOLO", tostring(result.id)
    end
    return false, "", ""
end

-- Returns the warrant status for a given report ID.
---@param reportId number -- The ID of the report to check for a warrant
---@return boolean, string -- Returns true if a warrant is active, false otherwise, along with a status message
function GetWarrantStatusByReport(reportId)
    if not reportId then
        return false, "No report ID provided"
    end

    local reportIdNumber = tonumber(reportId)
    if not reportIdNumber then
        return false, "Invalid report ID type"
    end

    local warrantRow = MySQL.single.await([[
        SELECT reportid, expirydate
        FROM mdt_reports_warrants
        WHERE reportid = ?
          AND expirydate >= NOW()
        LIMIT 1
    ]], { reportIdNumber })

    if not warrantRow then
        return false, "No active warrant"
    end

    return true, "Warrant is active"
end

-- Returns the warrant status for a vehicle plate (used by plate reader).
---@param plate string -- The vehicle plate to check
---@return boolean, string, string -- Returns warrant found, owner name, report ID
function GetWarrantStatus(plate)
    if not plate then return false, "", "" end
    plate = string.gsub(plate, "%s+", "")
    plate = string.upper(plate)

    local ownerCid = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE UPPER(REPLACE(plate, \' \', \'\')) = ? LIMIT 1', { plate })
    if not ownerCid then return false, "", "" end

    local ownerName = ps.getPlayerNameByIdentifier(ownerCid) or "Unknown"

    local warrantRow = MySQL.single.await([[
        SELECT reportid
        FROM mdt_reports_warrants
        WHERE citizenid = ?
          AND expirydate >= NOW()
        LIMIT 1
    ]], { ownerCid })

    if warrantRow then
        return true, ownerName, tostring(warrantRow.reportid)
    end
    return false, "", ""
end

-- Count charges for a citizen from the v3 normalized schema
function countCharges(cid)
    local rows = MySQL.query.await([[
        SELECT pc.charge_class, SUM(rc.count) AS total
        FROM mdt_reports_charges rc
        JOIN mdt_penal_codes pc ON rc.charge = pc.label
        WHERE rc.citizenid = ?
        GROUP BY pc.charge_class
    ]], { cid })

    local chargeCounts = { Felony = 0, Misdemeanor = 0, Infraction = 0 }
    if rows then
        for _, row in ipairs(rows) do
            local class = row.charge_class
            if class == 'felony' then
                chargeCounts.Felony = tonumber(row.total) or 0
            elseif class == 'misdemeanor' then
                chargeCounts.Misdemeanor = tonumber(row.total) or 0
            elseif class == 'infraction' then
                chargeCounts.Infraction = tonumber(row.total) or 0
            end
        end
    end

    local chargeDetails = MySQL.query.await([[
        SELECT rc.reportid, rc.charge, rc.count, rc.time, rc.fine, pc.charge_class
        FROM mdt_reports_charges rc
        JOIN mdt_penal_codes pc ON rc.charge = pc.label
        WHERE rc.citizenid = ?
        ORDER BY rc.reportid DESC
    ]], { cid })

    return { charges = chargeDetails or {}, count = chargeCounts }
end

-- Get reports where a citizen is involved (replaces old getIncidents that used mdt_incidents)
function getIncidents(cid)
    if not cid then return {} end

    local reports = MySQL.query.await([[
        SELECT r.id, r.title, r.type, r.datecreated
        FROM mdt_reports r
        INNER JOIN mdt_reports_involved ri ON r.id = ri.reportid
        WHERE ri.citizenid = ?
        ORDER BY r.datecreated DESC
        LIMIT 20
    ]], { cid })

    return reports or {}
end

-- Get citizen list with charge counts and weapon counts (batch queries, no N+1)
function getCitizens(source)
    if ps.getJobType(source) ~= "leo" then
        return {}
    end

    local citizens = MySQL.query.await([[
        SELECT p.citizenid,
               JSON_UNQUOTE(JSON_EXTRACT(p.charinfo, '$.firstname')) AS firstname,
               JSON_UNQUOTE(JSON_EXTRACT(p.charinfo, '$.lastname')) AS lastname
        FROM players p
        LIMIT 50
    ]], {})

    if not citizens or #citizens == 0 then return {} end

    local result = {}
    for i = 1, #citizens do
        local cid = citizens[i].citizenid
        local weaponCount = MySQL.scalar.await('SELECT COUNT(*) FROM mdt_weapons WHERE owner = ?', { cid }) or 0
        result[#result + 1] = {
            name = (citizens[i].firstname or '') .. ' ' .. (citizens[i].lastname or ''),
            identifier = cid,
            convictions = countCharges(cid),
            incidents = getIncidents(cid),
            weapons = {},
            weaponCount = tonumber(weaponCount) or 0,
        }
    end
    return result
end

ps.registerCallback('ps-mdt:hasProfile', function(source)
    local src = source
    assert(src, 'Player ID cannot be nil')
    local citizenId = ps.getIdentifier(src)
    if not citizenId then
        ps.warn('No citizen ID found for source: ' .. tostring(src))
        return false
    end

    return EnsureProfileExists(citizenId)
end)
-- ---------------------------------------------------------------------------
-- Phone number resolution (config-based, export-driven)
-- ---------------------------------------------------------------------------
-- Resolve a citizen's phone number through the configured phone resource so the
-- MDT shows the correct number even when it isn't stored in charinfo.phone
-- (lb-phone, gksphone, yseries, …). `fallback` is the charinfo.phone value; it is
-- returned when the phone resource yields nothing and Config.Phone.UseCharinfoFallback
-- is not disabled. Returns nil only when neither source produces a number.
function GetCitizenPhoneNumber(citizenid, fallback)
    local cfg = (Config and Config.Phone) or {}

    local function withFallback(num)
        if num ~= nil and tostring(num) ~= '' then return tostring(num) end
        if cfg.UseCharinfoFallback ~= false and fallback ~= nil and tostring(fallback) ~= '' then
            return tostring(fallback)
        end
        return nil
    end

    if not citizenid or citizenid == '' then return withFallback(nil) end

    local res = cfg.Resource
    if not res or res == '' then return withFallback(nil) end
    if GetResourceState(res) ~= 'started' then return withFallback(nil) end

    local exportName = cfg.NumberExport
    if not exportName or exportName == '' then exportName = 'GetEquippedPhoneNumber' end

    local ok, num = pcall(function()
        return exports[res][exportName](exports[res], citizenid)
    end)
    if ok then return withFallback(num) end
    return withFallback(nil)
end

-- Convenience export so other resources can reuse the same resolution.
--- Send an e-mail to a citizen through the configured phone resource.
--- Mirrors the lb-phone flow court.lua already uses: resolve the citizen's number,
--- ask the phone for the mail address behind it, then send.
--- Silent no-op when no phone resource is configured or running, so nothing that
--- calls this ever depends on a phone being installed.
--- @return boolean sent
function SendCitizenMail(citizenid, sender, subject, message)
    if not citizenid then return false end

    local cfg = (Config and Config.Phone) or {}
    local res = cfg.Resource
    if not res or res == '' then return false end
    if GetResourceState(res) ~= 'started' then return false end

    local number = GetCitizenPhoneNumber and GetCitizenPhoneNumber(citizenid) or nil
    if not number or tostring(number) == '' then return false end

    local ok, email = pcall(function() return exports[res]:GetEmailAddress(number) end)
    if not ok or not email or tostring(email) == '' then return false end

    local sent = pcall(function()
        exports[res]:SendMail({
            to      = email,
            sender  = sender or 'Los Santos Police Department',
            subject = subject or '',
            message = message or '',
        })
    end)
    return sent and true or false
end

exports('GetCitizenPhoneNumber', function(citizenid, fallback)
    return GetCitizenPhoneNumber(citizenid, fallback)
end)