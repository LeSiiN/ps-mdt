--[[
    ps-mdt / bridge / framework  (client)

    Client half of the framework bridge. Same reasoning as the server file: one
    qb-core code path, which qbx_core provides through its compatibility layer.

    All getters take no arguments - they always describe the local player, which
    is how ps_lib's client bridge behaved too.
]]

---@diagnostic disable-next-line: lowercase-global
MDT = MDT or {}

local QBCore

--- Lazily resolves the core object. qb-core may not have started yet.
---@return table|nil
local function core()
    if QBCore then return QBCore end

    if GetResourceState('qb-core') ~= 'started' then return nil end

    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if not ok or type(obj) ~= 'table' then return nil end

    QBCore = obj
    return QBCore
end

-- Player ---------------------------------------------------------------------

--- Returns the local PlayerData table.
---@return table
function MDT.getPlayerData()
    local qb = core()
    if not qb then return {} end
    return qb.Functions.GetPlayerData() or {}
end

--- Returns the local player's citizenid.
---@return string|nil
function MDT.getIdentifier()
    return MDT.getPlayerData().citizenid
end

--- Returns a single metadata value.
---@param key string
---@return any
function MDT.getMetadata(key)
    local data = MDT.getPlayerData()
    return data.metadata and data.metadata[key] or nil
end

--- Returns a single charinfo value.
---@param key string
---@return any
function MDT.getCharInfo(key)
    local data = MDT.getPlayerData()
    return data.charinfo and data.charinfo[key] or nil
end

--- Returns "Firstname Lastname".
---@return string|nil
function MDT.getPlayerName()
    local data = MDT.getPlayerData()
    if not data.charinfo then return nil end

    local name = ((data.charinfo.firstname or '') .. ' ' .. (data.charinfo.lastname or ''))
        :gsub('^%s+', ''):gsub('%s+$', '')

    return name ~= '' and name or nil
end
MDT.getName = MDT.getPlayerName

--- True while the player is dead or in last stand. Used to force the MDT shut.
---@return boolean
function MDT.isDead()
    return MDT.getMetadata('isdead') == true
        or MDT.getMetadata('inlaststand') == true
end

-- Job ------------------------------------------------------------------------

--- Returns the whole job table.
---@return table|nil
function MDT.getJob()
    return MDT.getPlayerData().job
end

--- Returns a single job field, or the whole job table when no key is given.
---@param key? string
---@return any
function MDT.getJobData(key)
    local job = MDT.getJob()
    if not job then return nil end
    if key == nil then return job end
    return job[key]
end

---@return string|nil
function MDT.getJobName()
    local job = MDT.getJob()
    return job and job.name or nil
end

---@return string|nil
function MDT.getJobType()
    local job = MDT.getJob()
    return job and job.type or nil
end

---@return boolean
function MDT.getJobDuty()
    local job = MDT.getJob()
    return job ~= nil and job.onduty == true
end

---@return boolean
function MDT.isBoss()
    local job = MDT.getJob()
    return job ~= nil and job.isboss == true
end

---@return table|nil
function MDT.getJobGrade()
    local job = MDT.getJob()
    return job and job.grade or nil
end

---@return number
function MDT.getJobGradeLevel()
    local grade = MDT.getJobGrade()
    return grade and tonumber(grade.level) or 0
end

---@return string|nil
function MDT.getJobGradeName()
    local grade = MDT.getJobGrade()
    return grade and grade.name or nil
end
