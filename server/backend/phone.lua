-- ============================================================================
--  phone.lua  —  phone-script abstraction (numbers, SMS, e-mail)
-- ----------------------------------------------------------------------------
--  Phone scripts do not agree on much. lb-phone hands out a number for a
--  citizenid from a server export and addresses mail by e-mail ADDRESS, which
--  first has to be resolved from that number. JPR Phone takes a citizenid
--  straight for mail, orders its SMS arguments the other way round, wants a
--  fourth "type" argument nobody else has — and its number/SMS exports are
--  CLIENT sided, so a server-side scheduler cannot call them at all.
--
--  Rather than sprinkle those differences through the court scheduler, the
--  call shape lives in Config.Phone and this module performs it. Adding a
--  third phone script means describing it in the config, not touching code.
--
--  Public API (server):
--      PhoneNumberFor(citizenid, fallback) -> string|nil
--      PhoneSendSms(citizenid, body)       -> boolean
--      PhoneSendMail(citizenid, subject, message) -> boolean
-- ============================================================================

local resourceName = tostring(GetCurrentResourceName())

-- ── Built-in providers ───────────────────────────────────────────────────────
-- One entry per supported phone script. Server owners pick one by name in
-- Config.Phone.Provider; nothing here needs editing to switch between them.
--
-- Field reference (also what Config.Phone.Custom expects):
--   Resource  resource name to call
--   Number / Sms / Mail   one operation each:
--     kind      'export'        exports[Resource][method](...)          server
--               'client-export' same, executed on the recipient's client
--               'event'         TriggerEvent(method, ...)               server
--               'client-event'  TriggerClientEvent(method, target, ...)
--               'none'          this script cannot do it
--     method    export or event name
--     args      call arguments; values written with a leading @ are replaced
--               with @citizenid @number @sender @subject @message @address
--               @maildata — anything without an @ is passed through literally
--     payload   (mail) table handed to the script, same @ substitution
--     resolveAddress  (mail) optional extra lookup performed first, for
--               scripts that address mail by e-mail address rather than by
--               number or citizenid
local PROVIDERS = {
    ['lb-phone'] = {
        Resource = 'lb-phone',
        Number = { kind = 'export', method = 'GetEquippedPhoneNumber', args = { '@citizenid' } },
        Sms    = { kind = 'export', method = 'SendMessage', args = { '@sender', '@number', '@message' } },
        Mail   = {
            kind = 'export',
            method = 'SendMail',
            -- lb-phone mails an ADDRESS, resolved from the number first.
            resolveAddress = { kind = 'export', method = 'GetEmailAddress', args = { '@number' } },
            args = { '@maildata' },
            payload = { to = '@address', sender = '@sender', subject = '@subject', message = '@message' },
        },
    },

    ['jpr-phonesystem'] = {
        Resource = 'jpr-phonesystem',
        -- getPhoneNumber() is client-side and only ever returns the caller's
        -- own number, so it is no use for looking up somebody else. Numbers
        -- come from charinfo.phone via UseCharinfoFallback instead.
        Number = { kind = 'none' },
        -- Reversed argument order compared to lb-phone, plus a trailing
        -- message TYPE ('message' | 'gps' | 'image'). Client-side, so this
        -- reaches ONLINE players only.
        Sms = {
            kind = 'client-export',
            method = 'sendiMessage',
            args = { '@number', '@sender', '@message', 'message' },
        },
        -- Server-side and takes the citizenid directly — no address lookup,
        -- and it reaches offline players.
        Mail = {
            kind = 'export',
            method = 'sendNewMailToOffline',
            args = { '@citizenid', '@maildata' },
            payload = { sender = '@sender', subject = '@subject', message = '@message', button = {} },
        },
    },

    -- YSeries (teamsgg). Mail is addressed by PHONE NUMBER and carries a
    -- separate sender address and display name — a third addressing scheme
    -- next to lb-phone's e-mail address and JPR's citizenid.
    ['yseries'] = {
        Resource = 'yseries',
        Number = { kind = 'export', method = 'GetPhoneNumberByIdentifier', args = { '@citizenid' } },
        -- Reminders go out as a phone notification. Addressed by SERVER ID,
        -- following the same shape as the documented CellBroadcast export
        -- (to, title, content, ...), so it reaches ONLINE players only —
        -- requiresOnline makes that an explicit "not delivered" instead of a
        -- call into nothing, and the e-mail path below still covers everyone.
        --
        -- ASSUMPTION: the notification export's argument order was not in the
        -- public docs. If your build expects something else, this one line is
        -- the only place to correct it.
        Sms = {
            kind = 'export',
            method = 'SendNotification',
            args = { '@source', '@sender', '@message' },
            requiresOnline = true,
        },
        Mail = {
            kind = 'export',
            method = 'SendMail',
            -- SendMail(email, toType, to) — 'phoneNumber' selects how `to` is
            -- interpreted ('phoneImei' and 'all' are the alternatives).
            args = { '@maildata', 'phoneNumber', '@number' },
            payload = {
                title = '@subject',
                sender = '@senderAddress',
                senderDisplayName = '@sender',
                content = '@message',
            },
        },
    },

    ['none'] = {
        Resource = '',
        Number = { kind = 'none' },
        Sms    = { kind = 'none' },
        Mail   = { kind = 'none' },
    },
}

--- The active provider definition, merged with the settings the server owner
--- actually edits (sender names, charinfo fallback).
---@return table
local function phoneCfg()
    local user = (Config and Config.Phone) or {}
    local name = user.Provider

    local provider
    if name == 'custom' then
        provider = user.Custom or {}
    elseif type(name) == 'string' and PROVIDERS[name] then
        provider = PROVIDERS[name]
    elseif type(user.Resource) == 'string' and PROVIDERS[user.Resource] then
        -- Config from before Provider existed: match on the resource name.
        provider = PROVIDERS[user.Resource]
    else
        provider = PROVIDERS['none']
    end

    return {
        Resource = provider.Resource,
        Number = provider.Number,
        Sms = provider.Sms,
        Mail = provider.Mail,
        UseCharinfoFallback = user.UseCharinfoFallback,
        SmsSenderNumber = user.SmsSenderNumber,
        MailSender = user.MailSender,
    }
end

--- The configured phone resource, but only when it is actually running.
---@return string|nil
local function phoneResource()
    local res = phoneCfg().Resource
    if type(res) ~= 'string' or res == '' then return nil end
    if GetResourceState(res) ~= 'started' then return nil end
    return res
end

--- Substitute the `@name` placeholders in a configured argument list.
---
--- Only values written with a leading `@` are replaced; everything else is
--- passed through exactly as configured. That distinction matters because
--- some scripts expect literal strings that collide with field names — JPR
--- Phone's SMS call ends in the literal "message" describing the message
--- TYPE, which a bare-name scheme would have swallowed as the message body.
---@param args table|nil
---@param values table
---@return table
local function buildArgs(args, values)
    local out = {}
    for i = 1, #(args or {}) do
        local token = args[i]
        if type(token) == 'string' and token:sub(1, 1) == '@' then
            out[i] = values[token:sub(2)]
        else
            out[i] = token
        end
    end
    return out
end

--- Same substitution for a table payload (mail bodies).
---@param payload table|nil
---@param values table
---@return table
local function buildPayload(payload, values)
    local out = {}
    for key, token in pairs(payload or {}) do
        if type(token) == 'string' and token:sub(1, 1) == '@' then
            out[key] = values[token:sub(2)]
        else
            out[key] = token
        end
    end
    return out
end

---@param citizenid string|nil
---@return number|nil src  Server id of that citizen, when they are online
local function sourceForCitizen(citizenid)
    if not citizenid then return nil end
    local ok, player = pcall(function()
        return QBCore and QBCore.Functions and QBCore.Functions.GetPlayerByCitizenId
            and QBCore.Functions.GetPlayerByCitizenId(citizenid) or nil
    end)
    if ok and player and player.PlayerData then return player.PlayerData.source end
    return nil
end

--- Perform one configured call.
---@param spec table|nil  { kind, method, args, ... }
---@param values table    placeholder values
---@param citizenid string|nil  needed for client-side calls
---@return boolean ok, any result
local function invoke(spec, values, citizenid)
    if type(spec) ~= 'table' then return false end
    local kind = spec.kind or 'export'
    if kind == 'none' then return false end

    local res = phoneResource()
    if not res then return false end
    if type(spec.method) ~= 'string' or spec.method == '' then return false end

    -- Some exports address a player by SERVER ID rather than phone number
    -- (YSeries notifications, for instance). Resolved lazily so scripts that
    -- do not need it are unaffected — and a nil here means the player is
    -- offline, which those exports cannot reach anyway.
    if values.source == nil then values.source = sourceForCitizen(citizenid) end
    if spec.requiresOnline and not values.source then return false end

    local args = buildArgs(spec.args, values)

    if kind == 'export' then
        local ok, result = pcall(function()
            return exports[res][spec.method](exports[res], table.unpack(args))
        end)
        if not ok then
            ps.debug('phone: export failed', spec.method, tostring(result))
            return false
        end
        return true, result
    end

    if kind == 'client-export' then
        -- The export lives on the client, so it needs a client to run on.
        -- The recipient runs it themselves: the call addresses a phone
        -- number, so executing it in their context delivers to them and
        -- nobody else's session is involved.
        --
        -- Consequence worth knowing: this cannot reach an OFFLINE player.
        -- The court scheduler treats a false return as "SMS not delivered"
        -- and its e-mail path (which JPR Phone serves offline) still runs.
        local target = sourceForCitizen(citizenid)
        if not target then return false end
        TriggerClientEvent(resourceName .. ':client:phoneExport', target, res, spec.method, args)
        return true
    end

    if kind == 'event' then
        TriggerEvent(spec.method, table.unpack(args))
        return true
    end

    if kind == 'client-event' then
        local target = sourceForCitizen(citizenid)
        if not target then return false end
        TriggerClientEvent(spec.method, target, table.unpack(args))
        return true
    end

    return false
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- A citizen's phone number, with the charinfo fallback applied.
---@param citizenid string|nil
---@param fallback string|nil  charinfo.phone, used when the script has none
---@return string|nil
function PhoneNumberFor(citizenid, fallback)
    local cfg = phoneCfg()

    local function withFallback(num)
        if num ~= nil and tostring(num) ~= '' then return tostring(num) end
        if cfg.UseCharinfoFallback ~= false and fallback ~= nil and tostring(fallback) ~= '' then
            return tostring(fallback)
        end
        return nil
    end

    if not citizenid or citizenid == '' then return withFallback(nil) end

    local ok, num = invoke(cfg.Number, { citizenid = citizenid }, citizenid)
    if not ok then return withFallback(nil) end
    return withFallback(num)
end

--- Send an SMS to a citizen.
---@param citizenid string
---@param body string
---@return boolean delivered
function PhoneSendSms(citizenid, body)
    local cfg = phoneCfg()
    local number = PhoneNumberFor(citizenid)
    if not number then return false end

    local ok = invoke(cfg.Sms, {
        citizenid = citizenid,
        number    = number,
        sender    = cfg.SmsSenderNumber or 'COURT',
        message   = body,
    }, citizenid)
    return ok == true
end

--- Send an e-mail to a citizen.
---@param citizenid string
---@param subject string
---@param message string
---@param senderOverride string|nil  per-message sender (department mail etc.)
---@return boolean delivered
function PhoneSendMail(citizenid, subject, message, senderOverride)
    local cfg = phoneCfg()
    local spec = cfg.Mail
    if type(spec) ~= 'table' or spec.kind == 'none' then return false end

    local sender = (senderOverride and senderOverride ~= '' and senderOverride)
        or cfg.MailSender or 'Court'

    local values = {
        citizenid = citizenid,
        -- Per-call rather than by temporarily rewriting the config: two mails
        -- going out at once would otherwise race over the same field.
        sender    = sender,
        -- Scripts that show a sender ADDRESS next to the display name (YSeries)
        -- need something mail-shaped. Use the configured name when it already
        -- is an address, otherwise derive one so the field is never empty.
        senderAddress = sender:find('@', 1, true) and sender
            or (sender:lower():gsub('[^%a%d]', '') .. '@lsgov.us'),
        subject   = subject,
        message   = message,
    }

    -- Scripts that address mail by number need one; scripts that address it
    -- by citizenid (JPR Phone) do not, and asking for a number there would
    -- refuse to mail players whose phone script has no number for them.
    if spec.resolveAddress or (spec.args and table.concat(spec.args, ','):find('@number', 1, true)) then
        local number = PhoneNumberFor(citizenid)
        if not number then return false end
        values.number = number
    end

    -- Optional extra hop: lb-phone mails an ADDRESS, which has to be looked
    -- up from the number first.
    if type(spec.resolveAddress) == 'table' then
        local ok, address = invoke({
            kind = spec.resolveAddress.kind or 'export',
            method = spec.resolveAddress.method,
            args = spec.resolveAddress.args,
        }, values, citizenid)
        if not ok or not address or tostring(address) == '' then return false end
        values.address = tostring(address)
    end

    values.maildata = buildPayload(spec.payload, values)

    local ok = invoke(spec, values, citizenid)
    return ok == true
end