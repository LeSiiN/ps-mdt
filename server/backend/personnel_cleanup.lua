-- ---------------------------------------------------------------------------
-- Personnel data cleanup engine (Phase 1 core)
-- ---------------------------------------------------------------------------
-- Removes a single person's PERSONAL MDT footprint when they are terminated,
-- without ever touching investigative or shared data. See Config.PersonnelCleanup
-- for the full keep/delete rationale.
--
-- Design notes:
--  * Every table/column is schema-checked at runtime against information_schema,
--    so installs with missing/renamed tables silently skip those steps instead
--    of throwing — the engine stays safe across schema versions.
--  * All deletes run inside ONE transaction, so a failure rolls everything back
--    (no half-cleaned, inconsistent state).
--  * We delete by the SUBJECT column (the fired person's own file). Child rows
--    are removed via existing ON DELETE CASCADE FKs (ppr_notes, fto_dor_ratings),
--    so there are no orphans.
--  * The core mdt_profiles identity row is intentionally NOT deleted: warrants /
--    reports reference it and some via ON DELETE CASCADE, so dropping it could
--    erase investigative data. We strip the officer footprint, not the identity.
-- ---------------------------------------------------------------------------

local schemaCache = nil

-- Build a { ["table.column"] = true } set of every mdt_ column that exists.
local function loadSchema()
    local rows = MySQL.query.await([[
        SELECT TABLE_NAME, COLUMN_NAME
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'mdt\_%'
    ]]) or {}
    local set = {}
    for _, r in ipairs(rows) do
        set[(tostring(r.TABLE_NAME) .. '.' .. tostring(r.COLUMN_NAME)):lower()] = true
    end
    return set
end

local function has(tbl, col)
    if not schemaCache then schemaCache = loadSchema() end
    return schemaCache[(tbl .. '.' .. col):lower()] == true
end

-- Allow a manual refresh (e.g. after a migration) without a resource restart.
function InvalidatePersonnelSchemaCache()
    schemaCache = nil
end

-- Remove the fired person from every patrol's member_ids JSON array. Patrols are
-- shared objects, so we edit membership rather than deleting the patrol. Returns
-- a list of {query, values} update statements to include in the transaction.
local function buildPatrolMembershipUpdates(citizenid)
    local updates = {}
    if not has('mdt_patrols', 'member_ids') then return updates end

    local rows = MySQL.query.await(
        'SELECT id, member_ids FROM mdt_patrols WHERE member_ids LIKE ?',
        { '%' .. citizenid .. '%' }
    ) or {}

    for _, row in ipairs(rows) do
        local ok, list = pcall(json.decode, row.member_ids or '[]')
        if ok and type(list) == 'table' then
            local kept, changed = {}, false
            for _, member in ipairs(list) do
                if tostring(member) == tostring(citizenid) then
                    changed = true
                else
                    kept[#kept + 1] = member
                end
            end
            -- LIKE can match substrings, so only update rows that really changed.
            if changed then
                updates[#updates + 1] = {
                    query = 'UPDATE mdt_patrols SET member_ids = ? WHERE id = ?',
                    values = { json.encode(kept), row.id },
                }
            end
        end
    end
    return updates
end

--- Wipe a person's personal MDT footprint. Safe to call for online or offline
--- citizenids. Returns a summary table { ok = bool, steps = n, error = str? }.
---@param citizenid string
---@return table
function CleanupPersonnelData(citizenid)
    if not citizenid or citizenid == '' then
        return { ok = false, error = 'missing citizenid' }
    end
    if not (Config and Config.PersonnelCleanup and Config.PersonnelCleanup.Enabled) then
        return { ok = false, error = 'cleanup disabled in config' }
    end

    local cfg = Config.PersonnelCleanup
    local queries = {}

    -- Simple "DELETE FROM <t> WHERE <c> = citizenid" steps, schema-checked.
    -- Each pair is a table the person OWNS (subject column).
    local subjectDeletes = {
        { 'mdt_profile_sessions',       'citizenid' },
        { 'mdt_profiles_identifiers',   'citizenid' },
        { 'mdt_officer_status',         'citizenid' },
        { 'mdt_sop_acknowledgements',   'citizenid' },
        { 'mdt_fto_assignments',        'trainee_citizenid' }, -- their FTO file
        { 'mdt_fto_phases',             'trainee_citizenid' },
        { 'mdt_ppr',                    'officer_citizenid' },  -- PPRs about them
    }
    for _, d in ipairs(subjectDeletes) do
        if has(d[1], d[2]) then
            queries[#queries + 1] = {
                query = ('DELETE FROM %s WHERE %s = ?'):format(d[1], d[2]),
                values = { citizenid },
            }
        end
    end

    -- FTO DORs hang off the trainee's assignments; remove them before/with the
    -- assignments so nothing is orphaned (dor_ratings cascade from dors).
    if has('mdt_fto_dors', 'assignment_id') and has('mdt_fto_assignments', 'trainee_citizenid') then
        table.insert(queries, 1, {
            query = [[DELETE FROM mdt_fto_dors
                      WHERE assignment_id IN (
                          SELECT id FROM (
                              SELECT id FROM mdt_fto_assignments WHERE trainee_citizenid = ?
                          ) AS t
                      )]],
            values = { citizenid },
        })
    end

    -- Officer tags/certifications ("air unit", "swat", etc.) are NOT stored in a
    -- join table — they live as a JSON array in mdt_profiles.certifications, and
    -- the callsign/badge/rank/department mark the person as active personnel.
    -- Since the profile row itself is intentionally kept (to avoid cascading into
    -- warrants/reports), those officer-identity fields must be cleared in place.
    do
        local sets, vals = {}, {}
        if has('mdt_profiles', 'certifications') then
            sets[#sets + 1] = '`certifications` = ?'
            vals[#vals + 1] = '[]'
        end
        for _, col in ipairs({ 'callsign', 'badge_number', 'rank', 'department' }) do
            if has('mdt_profiles', col) then
                sets[#sets + 1] = ('`%s` = NULL'):format(col)
            end
        end
        if #sets > 0 then
            vals[#vals + 1] = citizenid
            queries[#queries + 1] = {
                query = ('UPDATE mdt_profiles SET %s WHERE citizenid = ?'):format(table.concat(sets, ', ')),
                values = vals,
            }
        end
    end

    -- Optional: messages they sent.
    if cfg.DeleteSentMessages and has('mdt_messages', 'sender_citizenid') then
        queries[#queries + 1] = {
            query = 'DELETE FROM mdt_messages WHERE sender_citizenid = ?',
            values = { citizenid },
        }
    end

    -- Optional: audit-log rows about them (subject) and optionally by them (actor).
    if cfg.DeleteSubjectAuditLogs and has('mdt_audit_logs', 'entity_id') then
        queries[#queries + 1] = {
            query = [[DELETE FROM mdt_audit_logs
                      WHERE entity_id = ?
                        AND entity_type IN ('officers','officer','citizen','citizens')]],
            values = { citizenid },
        }
    end
    if cfg.DeleteActorAuditLogs and has('mdt_audit_logs', 'actor_citizenid') then
        queries[#queries + 1] = {
            query = 'DELETE FROM mdt_audit_logs WHERE actor_citizenid = ?',
            values = { citizenid },
        }
    end

    -- Patrol membership (JSON edit, computed up front).
    for _, u in ipairs(buildPatrolMembershipUpdates(citizenid)) do
        queries[#queries + 1] = u
    end

    if #queries == 0 then
        return { ok = true, steps = 0 }
    end

    -- Atomic: all-or-nothing so we never leave a partially-cleaned profile.
    local ok = MySQL.transaction.await(queries)
    if not ok then
        return { ok = false, error = 'transaction failed', steps = #queries }
    end

    -- The callsign lives in the player's metadata too, and a fired officer is usually
    -- still connected — so clearing only the database would be undone by their next
    -- autosave, and the number would stay locked to somebody who no longer works here.
    -- ClearCallsign clears the live player first, then the database, in that order.
    ClearCallsign(citizenid)

    if Config and Config.Debug then
        print(('[ps-mdt] personnel cleanup removed footprint for %s (%d steps)'):format(citizenid, #queries))
    end
    return { ok = true, steps = #queries }
end