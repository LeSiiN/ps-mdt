-- ============================================================================
--  Audit log retention
-- ----------------------------------------------------------------------------
--  Nothing ever removed rows from mdt_audit_logs. Every report, search, impound
--  and login added one and it stayed forever. The Activity page pays for that on
--  every page load: it runs COUNT(*) over the whole table, and InnoDB has no
--  cached row count, so the page gets slower in exact step with the table.
--
--  Deleting old rows fixes it at the root. Two details matter:
--
--   * The index. `created_at` had none, so `DELETE ... WHERE created_at < x`
--     would itself scan the whole table — the sweep would be as expensive as the
--     problem it's fixing.
--
--   * The batching. A server that has been running for a year could have millions
--     of rows to remove on the first sweep. One big DELETE would hold a lock long
--     enough to stall the server thread, so it's done in chunks with a yield in
--     between. The sweep can take a while; nothing else has to wait for it.
-- ============================================================================

local function cfg()
    return (Config and Config.AuditRetention) or {}
end

--- Delete audit rows older than the retention window, a batch at a time.
--- @return number deleted
local function sweep()
    local c = cfg()
    if c.Enabled ~= true then return 0 end

    local days = tonumber(c.Days) or 0
    if days <= 0 then return 0 end

    local batchSize = tonumber(c.BatchSize) or 2000
    if batchSize < 1 then batchSize = 2000 end

    local deleted = 0
    while true do
        local ok, affected = pcall(MySQL.update.await, [[
            DELETE FROM mdt_audit_logs
            WHERE created_at < (NOW() - INTERVAL ? DAY)
            LIMIT ?
        ]], { days, batchSize })

        if not ok then
            ps.warn('[audit] Retention sweep failed: ' .. tostring(affected))
            return deleted
        end

        affected = tonumber(affected) or 0
        deleted = deleted + affected

        -- A short batch means we've reached the end of the old rows.
        if affected < batchSize then break end

        -- Give the server thread room between batches.
        Wait(200)
    end

    if deleted > 0 then
        print(('[ps-mdt] [audit] Pruned %d audit log entr%s older than %d days.')
            :format(deleted, deleted == 1 and 'y' or 'ies', days))
    end

    return deleted
end

CreateThread(function()
    -- Don't fight the rest of the resource for the DB during startup.
    Wait(30000)

    local c = cfg()
    if c.Enabled ~= true then return end

    -- Needed by the DELETE above. Adding it to an already-huge table takes a
    -- moment, which is a reason to do it now rather than later.
    EnsureIndex('mdt_audit_logs', 'idx_created_at', '`created_at`')

    local intervalMs = (tonumber(c.IntervalHours) or 24) * 60 * 60 * 1000
    if intervalMs < 60000 then intervalMs = 60000 end

    while true do
        sweep()
        Wait(intervalMs)
    end
end)

--- Exposed so a server owner can force a sweep without waiting for the timer,
--- e.g. right after lowering Config.AuditRetention.Days.
exports('pruneAuditLogs', function()
    return sweep()
end)
