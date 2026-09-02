--[[
    ps-mdt / bridge / framework  (server)

    Replaces the ps_lib framework bridge. Talks to QBCore only.

    Why QBCore only:
      qbx_core ships a qb-core compatibility layer (`provide 'qb-core'` plus
      bridge/qb/server/main.lua) that exposes the full GetCoreObject() surface -
      Functions.GetPlayer, GetPlayerByCitizenId, GetOfflinePlayerByCitizenId,
      GetQBPlayers, Shared.Jobs, Shared.Items, ... - so one code path covers both
      QBCore and Qbox. That layer can be switched off with
      `setr qbx:enablebridge false`; if someone does that we print a loud, actionable
      error instead of silently half-working.

    Every getter here is nil safe. ps_lib indexed the player object without
    checking it, so a lookup for an offline citizen threw instead of returning
    nil - which is why so many call sites are wrapped in `... or 'Unknown'`.
    Those fallbacks now actually do something.
]]

---@diagnostic disable-next-line: lowercase-global
MDT = MDT or {}

local QBCore

--- Resolves the core object lazily. qb-core may not be started yet when this
--- file runs, so we retry on every access until it is.
---@return table|nil
local function core()
    if QBCore then return QBCore end

    if GetResourceState('qb-core') ~= 'started' then return nil end

    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if not ok or type(obj) ~= 'table' then return nil end

    QBCore = obj
    return QBCore
end

--- Accepts either a player source (number or numeric string) or a citizenid.
--- Falls back to the offline record, exactly like ps_lib did, but without the
--- pointless database round trip for numeric sources.
---@param id number|string|nil
---@return table|nil player
local function resolvePlayer(id)
    if id == nil then return nil end

    local qb = core()
    if not qb then return nil end

    local src = tonumber(id)
    if src then
        local player = qb.Functions.GetPlayer(src)
        if player then return player end
    end

    if type(id) == 'string' then
        return qb.Functions.GetPlayerByCitizenId(id)
            or qb.Functions.GetOfflinePlayerByCitizenId(id)
    end

    return nil
end

--- Shortcut for the PlayerData table.
---@param id number|string|nil
---@return table|nil
local function playerData(id)
    local player = resolvePlayer(id)
    return player and player.PlayerData or nil
end

-- Startup sanity check -------------------------------------------------------

CreateThread(function()
    Wait(2500) -- let every framework resource finish starting

    if core() then
        MDT.success('framework bridge ready (qb-core API)')
        return
    end

    if GetResourceState('qbx_core') == 'started' then
        MDT.error('qbx_core is running but its qb-core bridge is disabled.')
        MDT.error('Remove `setr qbx:enablebridge false` from your server.cfg, or set it to true, then restart.')
    else
        MDT.error('No supported framework found. ps-mdt needs qb-core or qbx_core (with its qb bridge enabled).')
    end
end)

-- Player ---------------------------------------------------------------------

--- Returns the player object for a source or citizenid.
---@param id number|string
---@return table|nil
function MDT.getPlayer(id)
    return resolvePlayer(id)
end

--- Returns the player object for a citizenid, online first, then offline.
---@param identifier string
---@return table|nil
function MDT.getPlayerByIdentifier(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return nil end

    local qb = core()
    if not qb then return nil end

    return qb.Functions.GetPlayerByCitizenId(identifier)
        or qb.Functions.GetOfflinePlayerByCitizenId(identifier)
end

--- Returns the offline player object for a citizenid.
---@param identifier string
---@return table|nil
function MDT.getOfflinePlayer(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return nil end

    local qb = core()
    return qb and qb.Functions.GetOfflinePlayerByCitizenId(identifier) or nil
end

--- Returns the citizenid for a player source.
---@param source number
---@return string|nil
function MDT.getIdentifier(source)
    local data = playerData(source)
    return data and data.citizenid or nil
end

--- Returns the source for a citizenid, or nil when the player is offline.
---@param identifier string
---@return number|nil
function MDT.getSource(identifier)
    local player = MDT.getPlayerByIdentifier(identifier)
    return player and player.PlayerData and player.PlayerData.source or nil
end

--- Returns the Rockstar license identifier for a source.
---@param source number
---@return string|nil
function MDT.getLicense(source)
    if GetConvarInt('sv_fxdkMode', 0) == 1 then return 'license:fxdk' end
    return GetPlayerIdentifierByType(source --[[@as string]], 'license')
end

--- Returns "Firstname Lastname" for a source or citizenid.
---@param id number|string
---@return string|nil
function MDT.getPlayerName(id)
    local data = playerData(id)
    if not data or not data.charinfo then return nil end

    local first = data.charinfo.firstname or ''
    local last  = data.charinfo.lastname or ''
    local name  = (first .. ' ' .. last):gsub('^%s+', ''):gsub('%s+$', '')

    return name ~= '' and name or nil
end
MDT.getName = MDT.getPlayerName

--- Returns "Firstname Lastname" for a citizenid, online or offline.
---@param identifier string
---@return string
function MDT.getPlayerNameByIdentifier(identifier)
    local player = MDT.getPlayerByIdentifier(identifier)
    local data   = player and player.PlayerData
    if not data or not data.charinfo then return 'Unknown Person' end

    local name = ((data.charinfo.firstname or '') .. ' ' .. (data.charinfo.lastname or ''))
        :gsub('^%s+', ''):gsub('%s+$', '')

    return name ~= '' and name or 'Unknown Person'
end

--- Returns the whole PlayerData table.
---@param id number|string
---@return table|nil
function MDT.getPlayerData(id)
    return playerData(id)
end

--- Returns a single metadata value.
---@param id number|string
---@param key string
---@return any
function MDT.getMetadata(id, key)
    local data = playerData(id)
    return data and data.metadata and data.metadata[key] or nil
end

--- Returns a single charinfo value (firstname, lastname, birthdate, phone, ...).
---@param id number|string
---@param key string
---@return any
function MDT.getCharInfo(id, key)
    local data = playerData(id)
    return data and data.charinfo and data.charinfo[key] or nil
end

--- Returns every connected player source.
---@return number[]
function MDT.getAllPlayers()
    local qb = core()
    if not qb then return {} end
    return qb.Functions.GetPlayers() or {}
end

--- True when the player is connected and loaded.
---@param identifier string
---@return boolean
function MDT.isOnline(identifier)
    local qb = core()
    if not qb then return false end
    return qb.Functions.GetPlayerByCitizenId(identifier) ~= nil
end

-- Job ------------------------------------------------------------------------

--- Returns the whole job table.
---@param id number|string
---@return table|nil
function MDT.getJob(id)
    local data = playerData(id)
    return data and data.job or nil
end

--- Returns a single job field (name, label, type, onduty, isboss, grade, ...),
--- or the whole job table when no key is given.
---
--- ps_lib required the key and did `job[nil]`, which silently returned nil. Six
--- call sites in this resource (server/auth.lua, server/backend/management.lua)
--- call it with only a source and expect the table back, so every one of those
--- branches was dead. Making the key optional revives them.
---@param id number|string
---@param key? string
---@return any
function MDT.getJobData(id, key)
    local job = MDT.getJob(id)
    if not job then return nil end
    if key == nil then return job end
    return job[key]
end

---@param id number|string
---@return string|nil
function MDT.getJobName(id)
    local job = MDT.getJob(id)
    return job and job.name or nil
end

---@param id number|string
---@return string|nil
function MDT.getJobType(id)
    local job = MDT.getJob(id)
    return job and job.type or nil
end

---@param id number|string
---@return boolean
function MDT.getJobDuty(id)
    local job = MDT.getJob(id)
    return job ~= nil and job.onduty == true
end

---@param id number|string
---@return boolean
function MDT.isBoss(id)
    local job = MDT.getJob(id)
    return job ~= nil and job.isboss == true
end

--- Returns the grade table. QBCore and Qbox both use { name, level, ... }.
---@param id number|string
---@return table|nil
function MDT.getJobGrade(id)
    local job = MDT.getJob(id)
    return job and job.grade or nil
end

---@param id number|string
---@return number
function MDT.getJobGradeLevel(id)
    local grade = MDT.getJobGrade(id)
    return grade and tonumber(grade.level) or 0
end

---@param id number|string
---@return string|nil
function MDT.getJobGradeName(id)
    local grade = MDT.getJobGrade(id)
    return grade and grade.name or nil
end

--- Returns the hourly pay for the player's current grade.
--- QBCore stores `payment` on the grade itself; Qbox does not, so we fall back
--- to the shared job definition.
---@param id number|string
---@return number|nil
function MDT.getJobGradePay(id)
    local job = MDT.getJob(id)
    if not job then return nil end

    local grade = job.grade
    if grade and (grade.payment or grade.pay) then
        return tonumber(grade.payment or grade.pay)
    end

    local shared = MDT.getSharedJobGrade(job.name, grade and grade.level or 0)
    return shared and tonumber(shared.payment or shared.pay) or nil
end

--- Counts on-duty players with the given job name.
---@param jobName string
---@return number
function MDT.getJobCount(jobName)
    local count = 0
    for _, src in pairs(MDT.getAllPlayers()) do
        local job = MDT.getJob(src)
        if job and job.name == jobName and job.onduty then
            count = count + 1
        end
    end
    return count
end

--- Counts on-duty players with the given job type (e.g. 'leo', 'ems').
---@param jobType string
---@return number
function MDT.getJobTypeCount(jobType)
    local count = 0
    for _, src in pairs(MDT.getAllPlayers()) do
        local job = MDT.getJob(src)
        if job and job.type == jobType and job.onduty then
            count = count + 1
        end
    end
    return count
end

--- Sets a player's job.
---@param source number
---@param jobName string
---@param grade? number
---@return boolean
function MDT.setJob(source, jobName, grade)
    local player = resolvePlayer(source)
    if not player or not player.Functions then return false end

    local ok = pcall(function() player.Functions.SetJob(jobName, grade or 0) end)
    return ok
end

--- Sets a player's duty state.
---@param source number
---@param duty boolean
---@return boolean
function MDT.setJobDuty(source, duty)
    local player = resolvePlayer(source)
    if not player or not player.Functions then return false end

    local ok = pcall(function() player.Functions.SetJobDuty(duty) end)
    return ok
end

-- Shared job data ------------------------------------------------------------

--- Returns the shared job definition.
---@param jobName string
---@return table|nil
function MDT.getSharedJob(jobName)
    local qb = core()
    if not qb or not qb.Shared or not qb.Shared.Jobs then return nil end
    return qb.Shared.Jobs[jobName]
end

--- Returns a single field from the shared job definition, or the whole
--- definition when no key is given (same reasoning as MDT.getJobData - two call
--- sites in management.lua and roster.lua pass only the job name).
---@param jobName string
---@param key? string
---@return any
function MDT.getSharedJobData(jobName, key)
    local job = MDT.getSharedJob(jobName)
    if not job then return nil end
    if key == nil then return job end
    return job[key]
end

--- Returns a grade table from the shared job definition.
--- QBCore keys grades by string ('0'), Qbox keys them by number (0), so we try
--- both instead of guessing.
---@param jobName string
---@param grade number|string
---@return table|nil
function MDT.getSharedJobGrade(jobName, grade)
    local job = MDT.getSharedJob(jobName)
    if not job or not job.grades then return nil end

    return job.grades[grade]
        or job.grades[tostring(grade)]
        or job.grades[tonumber(grade) or -1]
end

--- Returns a single field from a shared job grade.
---@param jobName string
---@param grade number|string
---@param key string
---@return any
function MDT.getSharedJobGradeData(jobName, grade, key)
    local gradeData = MDT.getSharedJobGrade(jobName, grade)
    return gradeData and gradeData[key] or nil
end

--- True when the job exists in the shared job list.
---@param jobName string
---@return boolean
function MDT.jobExists(jobName)
    return MDT.getSharedJob(jobName) ~= nil
end

-- Money ----------------------------------------------------------------------

--- Adds money to a player account.
---@param source number
---@param accountType? string 'cash' | 'bank'
---@param amount number
---@param reason? string
---@return boolean
function MDT.addMoney(source, accountType, amount, reason)
    local player = resolvePlayer(source)
    if not player or not player.Functions then return false end

    local ok, result = pcall(function()
        return player.Functions.AddMoney(accountType or 'cash', amount or 0, reason or 'ps-mdt')
    end)

    return ok and result ~= false
end

--- Removes money from a player account. Returns false when they cannot afford it.
---@param source number
---@param accountType? string 'cash' | 'bank'
---@param amount number
---@param reason? string
---@return boolean
function MDT.removeMoney(source, accountType, amount, reason)
    local player = resolvePlayer(source)
    if not player or not player.Functions then return false end

    local ok, result = pcall(function()
        return player.Functions.RemoveMoney(accountType or 'cash', amount or 0, reason or 'ps-mdt')
    end)

    return ok and result ~= false
end

--- Returns the balance of a player account.
---@param source number
---@param accountType? string
---@return number
function MDT.getMoney(source, accountType)
    local data = playerData(source)
    if not data or not data.money then return 0 end
    return tonumber(data.money[accountType or 'cash']) or 0
end
