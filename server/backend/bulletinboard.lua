local resourceName = tostring(GetCurrentResourceName())

-- Pull every identifier we can off a connected player, for the exploit log below. Native
-- lookups rather than the ps bridge, so this keeps working regardless of framework state.
local function collectIdentifiers(src)
    local ids = { license = 'unknown', license2 = 'unknown', discord = 'unknown', steam = 'unknown', ip = 'unknown' }
    local ok = pcall(function()
        for i = 0, GetNumPlayerIdentifiers(src) - 1 do
            local id = GetPlayerIdentifier(src, i)
            if id then
                local kind, value = id:match('^(%w+):(.+)$')
                if kind == 'license' and ids.license == 'unknown' then ids.license = value
                elseif kind == 'license2' then ids.license2 = value
                elseif kind == 'discord' then ids.discord = value
                elseif kind == 'steam' then ids.steam = value
                elseif kind == 'ip' then ids.ip = value end
            end
        end
    end)
    if not ok then ps.debug('collectIdentifiers failed for src ' .. tostring(src)) end
    return ids
end

-- A sanitized-away payload means someone submitted markup that would execute, navigate or
-- embed. That is an attempted XSS, so log who did it loudly with everything needed to
-- identify them. This fires even when the NUI would have stripped it client-side, because
-- the record of the attempt is what matters.
local function logExploitAttempt(src, field, original, cleaned)
    local ids = collectIdentifiers(src)
    local citizenId = (ps.getIdentifier and ps.getIdentifier(src)) or 'unknown'
    local charName  = (ps.getPlayerName and ps.getPlayerName(src)) or 'unknown'
    local fivemName = tostring(GetPlayerName(src) or 'unknown')

    -- A short excerpt of what they tried, so the log shows the vector without dumping a
    -- potentially huge payload into the console.
    local excerpt = original:gsub('%s+', ' '):sub(1, 200)

    ps.warn(('─────────────────────────────────────────────'))
    ps.warn(('[SECURITY] Bulletin XSS attempt blocked (%s)'):format(field))
    ps.warn(('  Server ID : %s'):format(tostring(src)))
    ps.warn(('  FiveM name: %s'):format(fivemName))
    ps.warn(('  Char name : %s'):format(charName))
    ps.warn(('  CitizenID : %s'):format(citizenId))
    ps.warn(('  license   : %s'):format(ids.license))
    ps.warn(('  license2  : %s'):format(ids.license2))
    ps.warn(('  discord   : %s'):format(ids.discord))
    ps.warn(('  steam     : %s'):format(ids.steam))
    ps.warn(('  ip        : %s'):format(ids.ip))
    ps.warn(('  payload   : %s'):format(excerpt))
    ps.warn(('─────────────────────────────────────────────'))

    -- Also route it through the audit log so it's queryable later, not just in the console.
    if ps.auditLog then
        CreateThread(function()
            pcall(ps.auditLog, src, 'bulletin_xss_blocked', 'security', citizenId, {
                field = field,
                fivem_name = fivemName,
                license = ids.license,
                license2 = ids.license2,
                discord = ids.discord,
                steam = ids.steam,
                ip = ids.ip,
                payload = excerpt,
                action_label = 'Blocked an attempted bulletin XSS injection',
            })
        end)
    end
end

-- Server-side content sanitizer. The NUI already strips dangerous HTML before rendering,
-- but that is the client's word for it — a crafted packet can call this callback directly
-- and never touch the NUI. So we also strip on the way into the database.
-- Allowlist in spirit: whole categories of executable/navigating/embedding tag are removed,
-- along with every on* handler and javascript:/vbscript: URL. Formatting tags are kept.
local function sanitizeBulletinHtml(html)
    if type(html) ~= 'string' or html == '' then return '' end
    local out = html

    -- Remove script/style/iframe/object/embed/meta/link/svg blocks together with whatever
    -- they contain — their content is the payload.
    for _, tag in ipairs({ 'script', 'style', 'iframe', 'object', 'embed', 'svg', 'template' }) do
        out = out:gsub('<%s*' .. tag .. '.-<%s*/%s*' .. tag .. '%s*>', '')  -- paired
        out = out:gsub('<%s*' .. tag .. '[^>]*>', '')                         -- stray/self-closing open
        out = out:gsub('<%s*/%s*' .. tag .. '%s*>', '')                       -- stray close
    end

    -- Void/standalone tags that navigate or load: meta (http-equiv refresh), base, link.
    for _, tag in ipairs({ 'meta', 'base', 'link' }) do
        out = out:gsub('<%s*' .. tag .. '[^>]*>', '')
    end

    -- Strip event-handler attributes (onload, onerror, onclick, …) wherever they appear.
    out = out:gsub('[oO][nN]%w+%s*=%s*"[^"]*"', '')
    out = out:gsub("[oO][nN]%w+%s*=%s*'[^']*'", '')
    out = out:gsub('[oO][nN]%w+%s*=%s*[^%s>]+', '')

    -- Neutralise javascript:/vbscript: URLs in any remaining attribute.
    -- Case-insensitive: lower-case a copy to find the scheme, blank it in the original.
    out = out:gsub('(%a+)%s*:', function(scheme)
        local low = scheme:lower()
        if low == 'javascript' or low == 'vbscript' then return '' end
        return scheme .. ':'
    end)

    -- Second return value: did we actually remove anything dangerous? Compared on a
    -- whitespace-normalised basis so trivial spacing differences don't count as an attack.
    local function squish(v) return (v:gsub('%s+', ' ')) end
    local changed = squish(out) ~= squish(html)
    return out, changed
end

-- ════════════════════════════════════════════════════════════
--  Bulletin Posts
-- ════════════════════════════════════════════════════════════

-- ── Get all bulletin posts for the officer's department ──────

ps.registerCallback(resourceName .. ':server:getBulletinPosts', function(source)
    local src = source
    if not CheckAuth(src) then return {} end

    local jobName = ps.getJobName(src)
    if not jobName or jobName == '' then return {} end

    local ok, posts = pcall(MySQL.query.await, [[
        SELECT
            bp.id, bp.title, bp.content, bp.author, bp.author_rank,
            bp.category, bp.priority, bp.pinned, bp.created_by,
            bp.created_at, bp.updated_at,
            COALESCE(bc.label, bp.category) AS category_label,
            COALESCE(bc.color, '#6B7280')   AS category_color
        FROM mdt_bulletin_posts bp
        LEFT JOIN mdt_bulletin_categories bc
            ON bc.value = bp.category AND bc.job = bp.job
        WHERE bp.job = ?
        ORDER BY bp.pinned DESC,
                 FIELD(bp.priority, 'urgent', 'high', 'normal', 'low'),
                 bp.created_at DESC
    ]], { jobName })

    if not ok or not posts then return {} end

    for _, post in ipairs(posts) do
        post.pinned = post.pinned == 1 or post.pinned == '1' or post.pinned == true
    end

    return posts
end)

-- ── Create a bulletin post ────────────────────────────────────

ps.registerCallback(resourceName .. ':server:createBulletinPost', function(source, data)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'bulletin_post') then
        return { success = false, error = 'No permission to create bulletin posts' }
    end

    data = data or {}

    -- Validate category exists for this job (or allow any stored value)
    local jobName   = ps.getJobName(src)
    local jobRank   = ps.getJobGradeName(src)
    local citizenId = ps.getIdentifier(src)

    local title = tostring(data.title or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if title == '' then return { success = false, error = 'Title is required' } end

    local VALID_PRIORITIES = { low = true, normal = true, high = true, urgent = true }
    if not VALID_PRIORITIES[data.priority] then
        return { success = false, error = 'Invalid priority' }
    end

    -- Check category exists for job
    local catRow = MySQL.single.await(
        'SELECT value FROM mdt_bulletin_categories WHERE value = ? AND job = ?',
        { data.category, jobName }
    )
    if not catRow then
        return { success = false, error = 'Invalid or unknown category' }
    end

    local profile = MySQL.single.await(
        'SELECT fullname FROM mdt_profiles WHERE citizenid = ?',
        { citizenId }
    )
    local author = (profile and profile.fullname) or tostring(GetPlayerName(src) or 'Unknown')

    local canPin = CheckPermission(src, 'bulletin_pin')
    local pinned = (canPin and data.pinned == true) and 1 or 0

    -- Sanitize before storing; if anything was stripped, this was an injection attempt.
    local rawContent = tostring(data.content or '')
    local cleanContent, wasExploit = sanitizeBulletinHtml(rawContent)
    if wasExploit then logExploitAttempt(src, 'create', rawContent, cleanContent) end

    local id = MySQL.insert.await([[
        INSERT INTO mdt_bulletin_posts
            (title, content, author, author_rank, category, priority, pinned, job, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        title:sub(1, 255),
        cleanContent:sub(1, 65535),
        author:sub(1, 100),
        jobRank,
        data.category,
        data.priority,
        pinned,
        jobName,
        citizenId
    })

    if not id then return { success = false, error = 'Database error' } end
    return { success = true, id = id }
end)

-- ── Update a bulletin post ────────────────────────────────────

ps.registerCallback(resourceName .. ':server:updateBulletinPost', function(source, postId, updates)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end

    postId  = tonumber(postId)
    updates = updates or {}
    if not postId then return { success = false, error = 'Invalid post id' } end

    local existing = MySQL.single.await(
        'SELECT created_by, job FROM mdt_bulletin_posts WHERE id = ?',
        { postId }
    )
    if not existing then return { success = false, error = 'Post not found' } end

    local jobName      = ps.getJobName(src)
    local citizenId    = ps.getIdentifier(src)
    local isSupervisor = CheckPermission(src, 'bulletin_post')
    local isOwner      = existing.created_by == citizenId

    if not isOwner and not isSupervisor then
        return { success = false, error = 'No permission to edit this post' }
    end
    if existing.job ~= jobName then
        return { success = false, error = 'Post belongs to a different department' }
    end

    local VALID_PRIORITIES = { low = true, normal = true, high = true, urgent = true }

    local sets = {}
    local vals = {}

    if updates.title ~= nil then
        local t = tostring(updates.title):gsub('^%s+', ''):gsub('%s+$', '')
        if t ~= '' then
            sets[#sets + 1] = 'title = ?'
            vals[#vals + 1] = t:sub(1, 255)
        end
    end
    if updates.content ~= nil then
        local rawContent = tostring(updates.content)
        local cleanContent, wasExploit = sanitizeBulletinHtml(rawContent)
        if wasExploit then logExploitAttempt(src, 'edit', rawContent, cleanContent) end
        sets[#sets + 1] = 'content = ?'
        vals[#vals + 1] = cleanContent:sub(1, 65535)
    end
    if updates.category ~= nil then
        -- Validate category belongs to this job
        local catRow = MySQL.single.await(
            'SELECT value FROM mdt_bulletin_categories WHERE value = ? AND job = ?',
            { updates.category, jobName }
        )
        if catRow then
            sets[#sets + 1] = 'category = ?'
            vals[#vals + 1] = updates.category
        end
    end
    if updates.priority ~= nil and VALID_PRIORITIES[updates.priority] then
        sets[#sets + 1] = 'priority = ?'
        vals[#vals + 1] = updates.priority
    end
    if updates.pinned ~= nil and isSupervisor then
        sets[#sets + 1] = 'pinned = ?'
        vals[#vals + 1] = updates.pinned and 1 or 0
    end

    if #sets == 0 then return { success = false, error = 'No valid fields to update' } end

    vals[#vals + 1] = postId
    MySQL.update.await(
        'UPDATE mdt_bulletin_posts SET ' .. table.concat(sets, ', ') .. ' WHERE id = ?',
        vals
    )
    return { success = true }
end)

-- ── Delete a bulletin post ────────────────────────────────────

ps.registerCallback(resourceName .. ':server:deleteBulletinPost', function(source, postId)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end

    postId = tonumber(postId)
    if not postId then return { success = false, error = 'Invalid post id' } end

    local existing = MySQL.single.await(
        'SELECT created_by, job FROM mdt_bulletin_posts WHERE id = ?',
        { postId }
    )
    if not existing then return { success = false, error = 'Post not found' } end

    local jobName      = ps.getJobName(src)
    local citizenId    = ps.getIdentifier(src)
    local isSupervisor = CheckPermission(src, 'bulletin_pin')
    local isOwner      = existing.created_by == citizenId

    if not isOwner and not isSupervisor then
        return { success = false, error = 'No permission to delete this post' }
    end
    if existing.job ~= jobName then
        return { success = false, error = 'Post belongs to a different department' }
    end

    MySQL.update.await('DELETE FROM mdt_bulletin_posts WHERE id = ?', { postId })
    return { success = true }
end)

-- ── Toggle pin on a bulletin post ────────────────────────────

ps.registerCallback(resourceName .. ':server:toggleBulletinPin', function(source, postId)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'bulletin_pin') then
        return { success = false, error = 'No permission to pin posts' }
    end

    postId = tonumber(postId)
    if not postId then return { success = false, error = 'Invalid post id' } end

    local existing = MySQL.single.await(
        'SELECT pinned, job FROM mdt_bulletin_posts WHERE id = ?',
        { postId }
    )
    if not existing then return { success = false, error = 'Post not found' } end

    local jobName = ps.getJobName(src)
    if existing.job ~= jobName then
        return { success = false, error = 'Post belongs to a different department' }
    end

    local isPinned  = existing.pinned == 1 or existing.pinned == '1' or existing.pinned == true
    local newPinned = isPinned and 0 or 1

    MySQL.update.await(
        'UPDATE mdt_bulletin_posts SET pinned = ? WHERE id = ?',
        { newPinned, postId }
    )
    return { success = true, pinned = newPinned }
end)

-- ════════════════════════════════════════════════════════════
--  Category Management  (one row per category)
--
--  Table: mdt_bulletin_categories
--  Columns: id, job, value, label, icon, color, sort_order, is_default
-- ════════════════════════════════════════════════════════════

-- Slugify a label into a safe DB value  (e.g. "My Custom Cat" → "my_custom_cat")
local function slugify(str)
    return tostring(str)
        :lower()
        :gsub('%s+', '_')
        :gsub('[^%w_]', '')
        :sub(1, 48)
end

-- Seed default categories for a job if none exist yet
local function ensureDefaultCategories(jobName)
    local count = MySQL.scalar.await(
        'SELECT COUNT(*) FROM mdt_bulletin_categories WHERE job = ?',
        { jobName }
    )
    if (count or 0) > 0 then return end

    local defaults = {
        { value = 'announcement', label = 'Announcements', icon = 'campaign',     color = '#3B82F6', sort_order = 1 },
        { value = 'operations',   label = 'Operations',    icon = 'local_police', color = '#8B5CF6', sort_order = 2 },
        { value = 'training',     label = 'Training',      icon = 'school',       color = '#10B981', sort_order = 3 },
        { value = 'general',      label = 'General',       icon = 'forum',        color = '#6B7280', sort_order = 4 },
    }

    for _, cat in ipairs(defaults) do
        MySQL.insert.await([[
            INSERT IGNORE INTO mdt_bulletin_categories
                (job, value, label, icon, color, sort_order, is_default)
            VALUES (?, ?, ?, ?, ?, ?, 1)
        ]], { jobName, cat.value, cat.label, cat.icon, cat.color, cat.sort_order })
    end
end

-- ── GET categories ────────────────────────────────────────────

ps.registerCallback(resourceName .. ':server:getBulletinCategories', function(source)
    local src = source
    if not CheckAuth(src) then return {} end

    local jobName = ps.getJobName(src)
    if not jobName or jobName == '' then return {} end

    ensureDefaultCategories(jobName)

    local ok, cats = pcall(MySQL.query.await, [[
        SELECT value, label, icon, color, sort_order, is_default
        FROM mdt_bulletin_categories
        WHERE job = ?
        ORDER BY sort_order ASC, id ASC
    ]], { jobName })

    if not ok or not cats then return {} end

    for _, c in ipairs(cats) do
        c.is_default = c.is_default == 1 or c.is_default == '1' or c.is_default == true
    end

    return cats
end)

-- ── ADD category ──────────────────────────────────────────────

ps.registerCallback(resourceName .. ':server:addBulletinCategory', function(source, data)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'bulletin_post') then
        return { success = false, error = 'No permission to manage categories' }
    end

    data = data or {}
    local jobName = ps.getJobName(src)

    local label = tostring(data.label or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if label == '' then return { success = false, error = 'Label is required' } end

    -- Build value from label if not provided
    local value = (data.value and data.value ~= '') and slugify(data.value) or slugify(label)
    if value == '' then return { success = false, error = 'Could not generate a valid category key' } end

    -- Check for duplicate
    local existing = MySQL.scalar.await(
        'SELECT COUNT(*) FROM mdt_bulletin_categories WHERE job = ? AND value = ?',
        { jobName, value }
    )
    if (existing or 0) > 0 then
        return { success = false, error = 'A category with that key already exists' }
    end

    -- Max 20 categories per job
    local total = MySQL.scalar.await(
        'SELECT COUNT(*) FROM mdt_bulletin_categories WHERE job = ?',
        { jobName }
    )
    if (total or 0) >= 20 then
        return { success = false, error = 'Maximum of 20 categories per department reached' }
    end

    local nextOrder = MySQL.scalar.await(
        'SELECT COALESCE(MAX(sort_order), 0) + 1 FROM mdt_bulletin_categories WHERE job = ?',
        { jobName }
    )

    local id = MySQL.insert.await([[
        INSERT INTO mdt_bulletin_categories (job, value, label, icon, color, sort_order, is_default)
        VALUES (?, ?, ?, ?, ?, ?, 0)
    ]], {
        jobName,
        value,
        label:sub(1, 48),
        tostring(data.icon  or 'label'):sub(1, 48),
        tostring(data.color or '#6B7280'):sub(1, 7),
        nextOrder
    })

    if not id then return { success = false, error = 'Database error' } end
    return { success = true, value = value, id = id }
end)

-- ── UPDATE category ───────────────────────────────────────────

ps.registerCallback(resourceName .. ':server:updateBulletinCategory', function(source, data)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'bulletin_post') then
        return { success = false, error = 'No permission to manage categories' }
    end

    data = data or {}
    local jobName = ps.getJobName(src)

    local existing = MySQL.single.await(
        'SELECT id, is_default FROM mdt_bulletin_categories WHERE job = ? AND value = ?',
        { jobName, data.value }
    )
    if not existing then return { success = false, error = 'Category not found' } end

    local sets = {}
    local vals = {}

    if data.label ~= nil then
        local l = tostring(data.label):gsub('^%s+', ''):gsub('%s+$', '')
        if l ~= '' then
            sets[#sets + 1] = 'label = ?'
            vals[#vals + 1] = l:sub(1, 48)
        end
    end
    if data.icon ~= nil then
        sets[#sets + 1] = 'icon = ?'
        vals[#vals + 1] = tostring(data.icon):sub(1, 48)
    end
    if data.color ~= nil then
        -- Validate hex color
        local color = tostring(data.color)
        if color:match('^#%x%x%x%x%x%x$') or color:match('^#%x%x%x$') then
            sets[#sets + 1] = 'color = ?'
            vals[#vals + 1] = color
        end
    end

    if #sets == 0 then return { success = false, error = 'No valid fields to update' } end

    vals[#vals + 1] = jobName
    vals[#vals + 1] = data.value

    MySQL.update.await(
        'UPDATE mdt_bulletin_categories SET ' .. table.concat(sets, ', ') ..
        ' WHERE job = ? AND value = ?',
        vals
    )
    return { success = true }
end)

-- ── REMOVE category ───────────────────────────────────────────

ps.registerCallback(resourceName .. ':server:removeBulletinCategory', function(source, data)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'bulletin_post') then
        return { success = false, error = 'No permission to manage categories' }
    end

    -- Accept either a table { value = '...' } or a plain string (backwards compat)
    local value = type(data) == 'table' and tostring(data.value or '') or tostring(data or '')
    local jobName = ps.getJobName(src)

    if value == '' then return { success = false, error = 'Missing category value' } end

    local existing = MySQL.single.await(
        'SELECT id, is_default FROM mdt_bulletin_categories WHERE job = ? AND value = ?',
        { jobName, value }
    )
    if not existing then return { success = false, error = 'Category not found' } end

    -- Count remaining categories — keep at least 1
    local total = MySQL.scalar.await(
        'SELECT COUNT(*) FROM mdt_bulletin_categories WHERE job = ?',
        { jobName }
    )
    if (total or 0) <= 1 then
        return { success = false, error = 'Cannot remove the last category' }
    end

    -- Reassign posts in this category to 'general' (or the first remaining category)
    local fallback = MySQL.single.await(
        'SELECT value FROM mdt_bulletin_categories WHERE job = ? AND value != ? ORDER BY sort_order ASC LIMIT 1',
        { jobName, value }
    )
    if fallback then
        MySQL.update.await(
            'UPDATE mdt_bulletin_posts SET category = ? WHERE job = ? AND category = ?',
            { fallback.value, jobName, value }
        )
    end

    MySQL.update.await(
        'DELETE FROM mdt_bulletin_categories WHERE job = ? AND value = ?',
        { jobName, value }
    )
    return { success = true }
end)

-- ── REORDER categories ────────────────────────────────────────

ps.registerCallback(resourceName .. ':server:reorderBulletinCategories', function(source, data)
    local src = source
    if not CheckAuth(src) then return { success = false, error = 'Unauthorized' } end
    if not CheckPermission(src, 'bulletin_post') then
        return { success = false, error = 'No permission to manage categories' }
    end

    local jobName = ps.getJobName(src)

    -- data may arrive as the array directly, or wrapped: { order = [...] }
    local order = data
    if type(data) == 'table' and data.order then
        order = data.order
    end

    if type(order) ~= 'table' then
        return { success = false, error = 'Invalid order data' }
    end

    for i, item in ipairs(order) do
        local val   = item.value      and tostring(item.value)           or nil
        local sord  = item.sort_order and tonumber(item.sort_order)      or i
        if val then
            MySQL.update.await(
                'UPDATE mdt_bulletin_categories SET sort_order = ? WHERE job = ? AND value = ?',
                { sord, jobName, val }
            )
        end
    end

    return { success = true }
end)