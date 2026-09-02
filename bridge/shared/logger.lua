--[[
    ps-mdt / bridge / logger  (shared)

    Replaces ps_lib's ps.debug / ps.info / ps.warn / ps.error / ps.success with
    plain prints. No external library, no init(), nothing that can fail to load.

    Everything lives on the resource-local `MDT` table, which is created here
    because this is the first file the resource loads.

    Levels:
      MDT.debug   - only printed when debug output is enabled (see below)
      MDT.info    - normal operational output
      MDT.success - confirmation output
      MDT.warn    - something is off but the resource keeps working
      MDT.error   - something failed

    Debug output is on when EITHER of these is true:
      * Config.Debug            = true            (config.lua)
      * convar `ps_mdt_debug`   = 1               (setr ps_mdt_debug 1)
    and can be toggled at runtime with MDT.setDebug(true/false).

    All helpers accept varargs and stringify tables, so the ps_lib call style
    (`MDT.debug('thing failed:', someTable)`) keeps working unchanged.
]]

---@diagnostic disable-next-line: lowercase-global
MDT = MDT or {}

local RESOURCE = GetCurrentResourceName()
local IS_SERVER = IsDuplicityVersion() == true
local SIDE      = IS_SERVER and 'server' or 'client'

-- ^1 red  ^2 green  ^3 yellow  ^5 cyan  ^6 magenta  ^7 reset
local PREFIX = ('^5[%s]^7'):format(RESOURCE)

local debugOverride = nil -- nil = follow config/convar, true/false = forced

--- Returns true when debug output should be printed.
---@return boolean
local function debugEnabled()
    if debugOverride ~= nil then return debugOverride end
    if Config and Config.Debug == true then return true end
    return GetConvarInt('ps_mdt_debug', 0) == 1
end

--- json.encode can throw on cyclic tables or functions; never let logging break
--- the caller.
---@param value any
---@return string
local function stringify(value)
    local t = type(value)

    if t == 'string' then
        return value
    elseif t == 'table' then
        local ok, encoded = pcall(json.encode, value)
        return ok and encoded or '<table>'
    elseif t == 'nil' then
        return 'nil'
    end

    return tostring(value)
end

--- Joins all arguments into one space separated string.
---@param ... any
---@return string
local function formatArgs(...)
    local count = select('#', ...)
    if count == 0 then return '' end

    -- Plain table literal on purpose: CFX's table.create takes (narr, nrec) and
    -- throws when the second argument is omitted, and preallocating a handful of
    -- slots on a logging path buys nothing anyway.
    local parts = {}
    for i = 1, count do
        -- stringify never returns nil, so `parts` stays hole-free for concat.
        parts[i] = stringify((select(i, ...)))
    end

    return table.concat(parts, ' ')
end

--- Force debug output on or off for the current session.
--- Pass nil to fall back to Config.Debug / the convar again.
---@param state boolean|nil
function MDT.setDebug(state)
    debugOverride = state
end

--- True when debug output is currently enabled.
---@return boolean
function MDT.isDebug()
    return debugEnabled()
end

---@param ... any
function MDT.debug(...)
    if not debugEnabled() then return end
    print(('%s ^6[DEBUG]^7 %s'):format(PREFIX, formatArgs(...)))
end

---@param ... any
function MDT.info(...)
    print(('%s ^4[INFO]^7 %s'):format(PREFIX, formatArgs(...)))
end

---@param ... any
function MDT.success(...)
    print(('%s ^2[OK]^7 %s'):format(PREFIX, formatArgs(...)))
end

---@param ... any
function MDT.warn(...)
    print(('%s ^3[WARN]^7 %s'):format(PREFIX, formatArgs(...)))
end

--- Errors also print a short stack trace when debug output is enabled, which is
--- the single most useful thing ps_lib never gave us.
---@param ... any
function MDT.error(...)
    print(('%s ^1[ERROR]^7 %s'):format(PREFIX, formatArgs(...)))
    if debugEnabled() then
        print(('%s ^1[ERROR]^7 %s'):format(PREFIX, debug.traceback('', 2)))
    end
end

-- Runtime toggle. Server: console or ACE protected. Client: F8 console.
if IS_SERVER then
    RegisterCommand('mdtdebug', function(source, args)
        if source ~= 0 and not IsPlayerAceAllowed(source --[[@as string]], 'command.mdtdebug') then return end
        local state = args[1] == '1' or args[1] == 'true'
        MDT.setDebug(state)
        MDT.info(('debug output %s (%s)'):format(state and 'enabled' or 'disabled', SIDE))
    end, false)
else
    RegisterCommand('mdtdebug', function(_, args)
        local state = args[1] == '1' or args[1] == 'true'
        MDT.setDebug(state)
        MDT.info(('debug output %s (%s)'):format(state and 'enabled' or 'disabled', SIDE))
    end, false)
end
