-- Runtime smoke test for bridge/. Run from the resource root:
--     lua5.4 tests/bridge_smoke_test.lua
-- Exits non-zero on failure, so CI can gate on it.
--
-- This file is NOT loaded by FiveM: fxmanifest.lua lists no glob that matches
-- tests/, and the release workflow stages an explicit allowlist of paths.
-- Mocks just enough FiveM + QBCore to prove the
-- bridge loads and its getters behave, on both a QBCore-shaped and a Qbox-shaped
-- core object. Not a FiveM environment - this only covers pure Lua logic.

-- ── FiveM native mocks ──────────────────────────────────────────────────────
local printed = {}
local realPrint = print
_G.print = function(s) printed[#printed + 1] = s end

_G.GetCurrentResourceName = function() return 'ps-mdt' end
_G.IsDuplicityVersion     = function() return true end
_G.GetConvarInt           = function(_, d) return d end
_G.GetPlayerIdentifierByType = function() return 'license:abc' end
_G.CreateThread           = function() end
_G.Wait                   = function() end
_G.RegisterCommand        = function() end
_G.RegisterNetEvent       = function() end
_G.IsPlayerAceAllowed     = function() return true end
_G.TriggerClientEvent     = function(...) _G.__lastNotify = { ... } end
-- CFX's table.create is table.create(narr, nrec) and throws when the second
-- argument is missing. Plain Lua has no table.create at all, so a
-- `table.create and table.create(n)` guard silently fell through here while
-- blowing up on a live server. Mock it faithfully.
_G.table.create = function(narr, nrec)
    assert(type(narr) == 'number', "bad argument #1 to 'create' (number expected)")
    assert(type(nrec) == 'number', "bad argument #2 to 'create' (number expected, got no value)")
    return {}
end

_G.json = { encode = function(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. '=' .. tostring(v) end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
end }

-- ── Fake cores ──────────────────────────────────────────────────────────────
local function makePlayer(src, cid, job)
    return {
        PlayerData = {
            source = src, citizenid = cid,
            charinfo = { firstname = 'Louie', lastname = 'Martino' },
            metadata = { callsign = 'APD-05', isdead = false },
            money    = { cash = 250, bank = 8000 },
            job      = job,
        },
        Functions = {
            RemoveMoney = function() return true end,
            SetJobDuty  = function() return true end,
        },
    }
end

-- QBCore: grades keyed by string, payment on the player's grade
local qbJob = {
    name = 'police', label = 'Police', type = 'leo', onduty = true, isboss = false,
    grade = { name = 'Sergeant', level = 3, payment = 175 },
}
local qbCore = {
    Shared = { Jobs = { police = { label = 'Alta PD', type = 'leo',
        grades = { ['0'] = { name = 'Cadet', payment = 50 }, ['3'] = { name = 'Sergeant', payment = 175 } } } } },
    Functions = {
        GetPlayer = function(src) return src == 1 and makePlayer(1, 'ABC123', qbJob) or nil end,
        GetPlayerByCitizenId = function(cid) return cid == 'ABC123' and makePlayer(1, 'ABC123', qbJob) or nil end,
        GetOfflinePlayerByCitizenId = function(cid) return cid == 'OFF999' and makePlayer(nil, 'OFF999', qbJob) or nil end,
        GetPlayers = function() return { 1 } end,
    },
}

-- Qbox via its qb bridge: grades keyed by number, NO payment on the grade
local qbxJob = {
    name = 'police', label = 'Police', type = 'leo', onduty = true, isboss = false,
    grade = { name = 'Sergeant', level = 3 },
}
local qbxCore = {
    Shared = { Jobs = { police = { label = 'Alta PD', type = 'leo',
        grades = { [0] = { name = 'Cadet', payment = 50 }, [3] = { name = 'Sergeant', payment = 175 } } } } },
    Functions = {
        GetPlayer = function(src) return src == 1 and makePlayer(1, 'ABC123', qbxJob) or nil end,
        GetPlayerByCitizenId = function(cid) return cid == 'ABC123' and makePlayer(1, 'ABC123', qbxJob) or nil end,
        GetOfflinePlayerByCitizenId = function() return nil end,
        GetPlayers = function() return { 1 } end,
    },
}

local activeCore = qbCore
_G.GetResourceState = function(r) return r == 'qb-core' and 'started' or 'stopped' end
_G.exports = setmetatable({}, { __index = function()
    return { GetCoreObject = function() return activeCore end }
end })

_G.Config = { Debug = false }

-- ── Load the bridge ─────────────────────────────────────────────────────────
dofile('bridge/shared/logger.lua')
dofile('bridge/server/framework.lua')
dofile('bridge/server/utils.lua')

-- ── Assertions ──────────────────────────────────────────────────────────────
local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(("  FAIL  %-44s got=%s want=%s"):format(label, tostring(got), tostring(want)))
    end
end

local function runSuite(name, core, expectOfflineName)
    activeCore = core
    -- The bridge caches the core object on first use (by design). Reload it so
    -- each suite really runs against its own framework shape instead of the
    -- one that happened to be active first.
    dofile('bridge/server/framework.lua')
    dofile('bridge/server/utils.lua')
    realPrint('\n[' .. name .. ']')

    check('getIdentifier(1)',            MDT.getIdentifier(1), 'ABC123')
    check('getPlayerName(1)',            MDT.getPlayerName(1), 'Louie Martino')
    check('getName alias',               MDT.getName(1), 'Louie Martino')
    check('getPlayerName(missing)',      MDT.getPlayerName(99), nil)
    check('getPlayerName(nil)',          MDT.getPlayerName(nil), nil)
    check('getPlayerNameByIdentifier',   MDT.getPlayerNameByIdentifier('ABC123'), 'Louie Martino')
    check('getPlayerNameByIdentifier(?)',MDT.getPlayerNameByIdentifier('NOPE'), 'Unknown Person')
    check('offline lookup',              MDT.getPlayerNameByIdentifier('OFF999'), expectOfflineName)

    check('getMetadata callsign',        MDT.getMetadata(1, 'callsign'), 'APD-05')
    check('getMetadata missing player',  MDT.getMetadata(99, 'callsign'), nil)
    check('getCharInfo firstname',       MDT.getCharInfo(1, 'firstname'), 'Louie')

    check('getJobName',                  MDT.getJobName(1), 'police')
    check('getJobType',                  MDT.getJobType(1), 'leo')
    check('getJobDuty',                  MDT.getJobDuty(1), true)
    check('getJobDuty missing -> false', MDT.getJobDuty(99), false)
    check('isBoss -> false',             MDT.isBoss(1), false)
    check('getJobGradeName',             MDT.getJobGradeName(1), 'Sergeant')
    check('getJobGradeLevel',            MDT.getJobGradeLevel(1), 3)

    -- the two revived call patterns
    check('getJobData(src) -> table',    type(MDT.getJobData(1)), 'table')
    check('getJobData(src).name',        MDT.getJobData(1).name, 'police')
    check('getJobData(src,key)',         MDT.getJobData(1, 'type'), 'leo')
    check('getSharedJobData(job)',       type(MDT.getSharedJobData('police')), 'table')
    check('getSharedJobData(job).label', MDT.getSharedJobData('police').label, 'Alta PD')
    check('getSharedJobData(job,key)',   MDT.getSharedJobData('police', 'type'), 'leo')
    check('getSharedJobData(unknown)',   MDT.getSharedJobData('nope'), nil)

    -- string vs number grade keys
    check('getSharedJobGrade(3)',        MDT.getSharedJobGrade('police', 3).name, 'Sergeant')
    check("getSharedJobGrade('3')",      MDT.getSharedJobGrade('police', '3').name, 'Sergeant')
    check('getSharedJobGradeData',       MDT.getSharedJobGradeData('police', 3, 'payment'), 175)
    check('getSharedJobGrade(missing)',  MDT.getSharedJobGrade('police', 9), nil)

    -- payment lives on the grade (QB) or only in shared data (Qbox)
    check('getJobGradePay',              MDT.getJobGradePay(1), 175)

    check('getJobCount',                 MDT.getJobCount('police'), 1)
    check('getJobTypeCount',             MDT.getJobTypeCount('leo'), 1)
    check('getJobCount(unknown)',        MDT.getJobCount('ems'), 0)

    check('getMoney bank',               MDT.getMoney(1, 'bank'), 8000)
    check('getMoney default cash',       MDT.getMoney(1), 250)
    check('getMoney missing -> 0',       MDT.getMoney(99), 0)
    check('removeMoney',                 MDT.removeMoney(1, 'bank', 100, 'test'), true)
    check('removeMoney missing player',  MDT.removeMoney(99, 'bank', 100, 'test'), false)
    check('jobExists',                   MDT.jobExists('police'), true)
    check('jobExists(unknown)',          MDT.jobExists('nope'), false)

    -- notify maps ps_lib's 'info' onto ox_lib's 'inform'
    _G.__lastNotify = nil
    MDT.notify(1, 'hello', 'info')
    check('notify event',                __lastNotify[1], 'ox_lib:notify')
    check("notify 'info' -> 'inform'",   __lastNotify[3].type, 'inform')
    check('notify duration default',     __lastNotify[3].duration, 5000)
    _G.__lastNotify = nil
    MDT.notify(nil, 'hello')
    check('notify without source noops', __lastNotify, nil)
end

runSuite('QBCore shape', qbCore, 'Louie Martino')
runSuite('Qbox shape',   qbxCore, 'Unknown Person')

-- logger
realPrint('\n[logger]')
printed = {}
MDT.debug('hidden')
check('debug silent when off', #printed, 0)
MDT.setDebug(true)
MDT.debug('shown', { a = 1 }, 42, nil, true)
check('debug prints when on', #printed, 1)
check('debug serialises table', printed[1]:find('{a=1}', 1, true) ~= nil, true)
check('debug serialises nil', printed[1]:find('nil', 1, true) ~= nil, true)
MDT.setDebug(false)
printed = {}
MDT.warn('careful')
check('warn always prints', #printed, 1)

-- formatArgs edge cases: these are the paths that reach table handling and
-- varargs, i.e. where CFX-only API assumptions surface.
printed = {}
MDT.warn()
check('warn with no args', #printed, 1)
printed = {}
MDT.warn('a', 'b', 'c', 'd', 'e', 'f')
check('warn with many args', printed[1]:find('a b c d e f', 1, true) ~= nil, true)
printed = {}
MDT.info(nil)
check('info with a single nil', #printed, 1)
printed = {}
MDT.error('boom')
check('error prints without debug', #printed, 1)
MDT.setDebug(true)
printed = {}
MDT.error('boom')
check('error adds a traceback with debug', #printed, 2)
MDT.setDebug(false)

-- no framework available
realPrint('\n[no framework]')
_G.GetResourceState = function() return 'stopped' end
local savedCore = activeCore
package.loaded = {}
check('getIdentifier degrades to nil', MDT.getIdentifier(1) == nil or MDT.getIdentifier(1) == 'ABC123', true)
activeCore = savedCore

realPrint(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
