--[[
    ps-mdt / bridge / utils  (server)

    Replaces the ps_lib notify bridge with a direct ox_lib notification.

    Server callbacks are NOT wrapped: every `ps.registerCallback` call site was
    rewritten to `lib.callback.register`, which has the identical signature
    (name, function(source, ...)) and, unlike ps_lib, keys pending requests per
    request instead of per name - so two clients asking for the same callback at
    the same time no longer overwrite each other's promise.
]]

---@diagnostic disable-next-line: lowercase-global
MDT = MDT or {}

--- Sends a notification to a player.
---@param source number
---@param text string
---@param notifyType? string 'inform' | 'success' | 'error' | 'warning'
---@param duration? number milliseconds, defaults to 5000
function MDT.notify(source, text, notifyType, duration)
    if not source or not text then return end

    -- ps_lib used 'info'; ox_lib calls it 'inform' and falls back to the
    -- default style for anything it does not know.
    if notifyType == 'info' then notifyType = 'inform' end

    TriggerClientEvent('ox_lib:notify', source, {
        description = text,
        type        = notifyType or 'inform',
        duration    = duration or 5000,
    })
end

--- Flips a player's duty state. Replaces ps_lib's `ps_lib:server:toggleDuty`.
RegisterNetEvent('ps-mdt:server:toggleDuty', function()
    local src = source
    if not src then return end

    local job = MDT.getJob(src)
    if not job then return end

    MDT.setJobDuty(src, not job.onduty)
end)
