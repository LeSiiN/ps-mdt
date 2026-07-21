-- ============================================================================
--  phone.lua (client)  —  bridge for CLIENT-SIDED phone exports
-- ----------------------------------------------------------------------------
--  Some phone scripts expose their messaging exports on the client only (JPR
--  Phone's sendiMessage and sendWhatsapp, for instance). The MDT's court
--  scheduler runs on the server, so those calls have to be handed to a client
--  to execute — the recipient's own, which keeps delivery to the intended
--  phone and no one else's session.
--
--  The event is server-triggered; a client cannot invoke it on another player.
--  It is still narrowed to the configured phone resource so a stray trigger
--  cannot be used to call exports elsewhere.
-- ============================================================================

local resourceName = tostring(GetCurrentResourceName())

RegisterNetEvent(resourceName .. ':client:phoneExport', function(resource, method, args)
    local cfg = (Config and Config.Phone) or {}
    if type(resource) ~= 'string' or resource == '' then return end
    if resource ~= cfg.Resource then return end
    if type(method) ~= 'string' or method == '' then return end
    if GetResourceState(resource) ~= 'started' then return end

    local ok, err = pcall(function()
        exports[resource][method](exports[resource], table.unpack(args or {}))
    end)
    if not ok then
        ps.debug('phoneExport failed:', method, tostring(err))
    end
end)
