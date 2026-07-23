<script lang="ts">
    import { onMount } from "svelte";
    import { sanitizeHtml } from "../utils/sanitizeHtml";
    import { formatDateTime } from "../utils/datetime";
    import { fetchNui } from "../utils/fetchNui";
    import { NUI_EVENTS } from "../constants/nuiEvents";
    import type { AuthService } from "../services/authService.svelte";

    // ── Types ──────────────────────────────────────────────────

    interface BulletinPost {
        id: number;
        title: string;
        content: string;
        author: string;
        author_rank: string;
        category: string;
        category_label?: string;
        category_color?: string;
        priority: BulletinPriority;
        pinned: boolean;
        created_by: string;
        created_at: string;
        updated_at?: string;
    }

    interface SidebarCategory {
        value: string;
        label: string;
        icon: string;
        color: string;
        sort_order?: number;
        is_default?: boolean;
    }

    type BulletinPriority = 'low' | 'normal' | 'high' | 'urgent';

    interface ModalState {
        open: boolean;
        mode: 'create' | 'edit';
        post: Partial<BulletinPost>;
    }

    let { authService }: { authService?: AuthService } = $props();

    // ── Constants ──────────────────────────────────────────────

    const STATIC_ALL_CATEGORY: SidebarCategory = {
        label: 'All Posts', icon: 'dashboard', value: 'all', color: '#6B7280'
    };

    const PRIORITY_META: Record<BulletinPriority, { label: string; icon: string; color: string }> = {
        low:    { label: 'Low',    icon: 'arrow_downward', color: 'rgba(100,200,100,0.80)' },
        normal: { label: 'Normal', icon: 'remove',         color: 'rgba(160,160,210,0.80)' },
        high:   { label: 'High',   icon: 'arrow_upward',   color: 'rgba(240,180,40,0.90)'  },
        urgent: { label: 'Urgent', icon: 'priority_high',  color: 'rgba(220,70,60,0.95)'   },
    };

    // Re-alpha an rgba() string for use as a chip background. The priority colours are
    // authored as rgba(), so swapping the alpha keeps the hue exactly and avoids
    // color-mix(), which CEF doesn't handle reliably.
    function tint(rgba: string, alpha: number): string {
        return rgba.replace(/[\d.]+\)$/, `${alpha})`);
    }

    // ── State ──────────────────────────────────────────────────

    let posts           = $state<BulletinPost[]>([]);
    let categories      = $state<SidebarCategory[]>([]);
    let loading         = $state(true);
    let saving          = $state(false);
    let searchQuery     = $state('');
    let activeCategory  = $state('all');
    let expandedId      = $state<number | null>(null);

    let modal = $state<ModalState>({
        open: false,
        mode: 'create',
        post: defaultPost(),
    });

    let deleteConfirm = $state<{ open: boolean; postId: number | null }>({
        open: false,
        postId: null,
    });

    // ── Derived ────────────────────────────────────────────────

    let sidebarCategories = $derived([STATIC_ALL_CATEGORY, ...categories]);

    let activeCatMeta = $derived(
        sidebarCategories.find(c => c.value === activeCategory) ?? STATIC_ALL_CATEGORY
    );

    let pinnedPosts = $derived(
        posts.filter(p =>
            p.pinned &&
            (activeCategory === 'all' || p.category === activeCategory) &&
            matchesSearch(p)
        )
    );

    let regularPosts = $derived(() => {
        const base = posts.filter(p =>
            !p.pinned &&
            (activeCategory === 'all' || p.category === activeCategory) &&
            matchesSearch(p)
        );
        const order: Record<BulletinPriority, number> = { urgent: 0, high: 1, normal: 2, low: 3 };
        return base.sort((a, b) => {
            const pd = order[a.priority] - order[b.priority];
            return pd !== 0 ? pd : new Date(b.created_at).getTime() - new Date(a.created_at).getTime();
        });
    });

    let postCountFor = $derived((cat: string) =>
        cat === 'all'
            ? posts.length
            : posts.filter(p => p.category === cat).length
    );

    // ── Helpers ────────────────────────────────────────────────

    function defaultPost(): Partial<BulletinPost> {
        const firstCat = categories[0]?.value ?? 'general';
        return { title: '', content: '', category: firstCat, priority: 'normal', pinned: false };
    }

    function matchesSearch(p: BulletinPost): boolean {
        const q = searchQuery.toLowerCase().trim();
        if (!q) return true;
        return (
            p.title.toLowerCase().includes(q) ||
            p.content.toLowerCase().includes(q) ||
            p.author.toLowerCase().includes(q)
        );
    }

    function formatDate(dateStr: string): string {
        return formatDateTime(dateStr, dateStr);
    }

    function getCategoryMeta(value: string): SidebarCategory {
        return categories.find(c => c.value === value) ?? {
            value,
            label: value,
            icon: 'label',
            color: '#6B7280',
        };
    }

    function canEdit(_post: BulletinPost): boolean {
        return authService?.hasPermission?.('bulletin_post') || false;
    }

    function canPost(): boolean {
        return authService?.hasPermission?.('bulletin_post') || false;
    }

    function canPin(): boolean {
        return authService?.hasPermission?.('bulletin_pin') || false;
    }

    // ── Data loading ───────────────────────────────────────────

    onMount(async () => {
        await loadCategories();
        await loadPosts();
    });

    async function loadCategories() {
        try {
            const result = await fetchNui<SidebarCategory[]>(NUI_EVENTS.BULLETIN.GET_CATEGORIES, {}, []);
            if (Array.isArray(result) && result.length > 0) {
                categories = result;
            }
        } catch {
            // keep empty, posts still load fine
        }
    }

    async function loadPosts() {
        loading = true;
        try {
            const result = await fetchNui<BulletinPost[]>(NUI_EVENTS.BULLETIN.GET_POSTS, {}, []);
            posts = result || [];
        } catch {
            posts = [];
        } finally {
            loading = false;
        }
    }

    // ── CRUD actions ───────────────────────────────────────────

    function openCreate() {
        modal = { open: true, mode: 'create', post: defaultPost() };
    }

    function openEdit(post: BulletinPost) {
        modal = { open: true, mode: 'edit', post: { ...post } };
    }

    function closeModal() {
        modal = { open: false, mode: 'create', post: defaultPost() };
    }

    async function savePost() {
        if (!modal.post.title?.trim() || !modal.post.content?.trim()) return;
        saving = true;
        try {
            if (modal.mode === 'create') {
                const res = await fetchNui<{ success: boolean; id?: number }>(
                    NUI_EVENTS.BULLETIN.CREATE_POST, modal.post, { success: false }
                );
                if (res?.success) { await loadPosts(); closeModal(); }
            } else {
                const res = await fetchNui<{ success: boolean }>(
                    NUI_EVENTS.BULLETIN.UPDATE_POST, modal.post, { success: false }
                );
                if (res?.success) { await loadPosts(); closeModal(); }
            }
        } finally {
            saving = false;
        }
    }

    function askDelete(postId: number) {
        deleteConfirm = { open: true, postId };
    }

    async function confirmDelete() {
        if (!deleteConfirm.postId) return;
        saving = true;
        try {
            await fetchNui(NUI_EVENTS.BULLETIN.DELETE_POST, { id: deleteConfirm.postId }, {});
            await loadPosts();
            deleteConfirm = { open: false, postId: null };
        } finally {
            saving = false;
        }
    }

    async function togglePin(post: BulletinPost) {
        await fetchNui(NUI_EVENTS.BULLETIN.TOGGLE_PIN, { id: post.id }, {});
        await loadPosts();
    }
</script>

<!-- ════════════════════════════════════════════════════════════
     Layout
═════════════════════════════════════════════════════════════ -->
<div class="bulletin-page">

    <!-- ── Sidebar ── -->
    <div class="bulletin-sidebar">
        <div class="sidebar-header">
            <span class="material-icons header-icon">campaign</span>
            <h2>Bulletin Board</h2>
        </div>

        <div class="search-box">
            <span class="material-icons search-icon">search</span>
            <input type="text" placeholder="Search posts..." bind:value={searchQuery} />
        </div>

        <div class="category-list">
            {#each sidebarCategories as cat}
                {@const count = postCountFor(cat.value)}
                <button
                    class="category-item"
                    class:active={activeCategory === cat.value}
                    onclick={() => activeCategory = cat.value}
                    style={activeCategory === cat.value && cat.value !== 'all'
                        ? `--cat-color: ${cat.color}; background: ${cat.color}14; border-color: ${cat.color}33;`
                        : ''}
                >
                    <!-- Colored dot for non-"all" categories -->
                    {#if cat.value !== 'all'}
                        <span
                            class="cat-color-dot"
                            style="background:{cat.color};"
                        ></span>
                    {/if}
                    <span
                        class="material-icons cat-icon"
                        style={activeCategory === cat.value && cat.value !== 'all' ? `color:${cat.color};` : ''}
                    >{cat.icon}</span>
                    <div class="cat-info">
                        <span class="cat-title">{cat.label}</span>
                        <span class="cat-count">{count} post{count !== 1 ? 's' : ''}</span>
                    </div>
                    {#if activeCategory === cat.value && cat.value !== 'all'}
                        <span
                            class="cat-active-bar"
                            style="background:{cat.color};"
                        ></span>
                    {/if}
                </button>
            {/each}
        </div>

        <div class="sidebar-footer">
            {#if canPost()}
                <button class="create-btn" onclick={openCreate}>
                    <span class="material-icons">add</span>
                    New Post
                </button>
            {/if}
        </div>
    </div>

    <!-- ── Main Content ── -->
    <div class="bulletin-content">

        <!-- Active category header bar -->
        {#if activeCategory !== 'all'}
            <div
                class="content-cat-header"
                style="border-left-color:{activeCatMeta.color}; background:linear-gradient(90deg, {activeCatMeta.color}12, transparent);"
            >
                <span class="material-icons" style="color:{activeCatMeta.color}; font-size:16px;">{activeCatMeta.icon}</span>
                <span class="content-cat-title" style="color:{activeCatMeta.color};">{activeCatMeta.label}</span>
                <span class="content-cat-sep">·</span>
                <span class="content-cat-count">{postCountFor(activeCategory)} post{postCountFor(activeCategory) !== 1 ? 's' : ''}</span>
            </div>
        {/if}

        {#if loading}
            <div class="content-empty">
                <div class="spinner"></div>
                <span>Loading bulletin board...</span>
            </div>

        {:else if posts.length === 0}
            <div class="content-empty">
                <span class="material-icons empty-icon">campaign</span>
                <h3>No Posts Yet</h3>
                <p>Be the first to post on the bulletin board.</p>
            </div>

        {:else}

            <!-- Pinned Posts -->
            {#if pinnedPosts.length > 0}
                <div class="section-label">
                    <span class="material-icons label-icon">push_pin</span>
                    <span>Pinned</span>
                </div>
                <div class="posts-list">
                    {#each pinnedPosts as post (post.id)}
                        {@const catMeta = getCategoryMeta(post.category)}
                        <div class="post-card pinned" class:expanded={expandedId === post.id}
                             style="--post-cat-color:{catMeta.color};">
                            <button class="post-header" onclick={() => expandedId = expandedId === post.id ? null : post.id}>
                                <div class="post-header-left">
                                    <span
                                        class="priority-badge"
                                        style="color:{PRIORITY_META[post.priority].color};border-color:{PRIORITY_META[post.priority].color};"
                                    >
                                        <span class="material-icons prio-icon">{PRIORITY_META[post.priority].icon}</span>
                                        {PRIORITY_META[post.priority].label}
                                    </span>
                                    <h3 class="post-title">{post.title}</h3>
                                </div>
                                <div class="post-header-right">
                                    <span class="material-icons pin-icon" style="color:{catMeta.color}40;">push_pin</span>
                                    <span class="material-icons expand-icon">{expandedId === post.id ? 'expand_less' : 'expand_more'}</span>
                                </div>
                            </button>

                            <div class="post-meta">
                                <span class="material-icons meta-icon">person</span>
                                <span class="meta-author">{post.author}</span>
                                {#if post.author_rank}
                                    <span class="meta-rank">{post.author_rank}</span>
                                {/if}
                                <span class="meta-sep">·</span>
                                <!-- Category tag with color -->
                                <span
                                    class="meta-cat-tag"
                                    style="color:{catMeta.color};background:{catMeta.color}12;border-color:{catMeta.color}25;"
                                >
                                    <span class="material-icons" style="font-size:10px;">{catMeta.icon}</span>
                                    {post.category_label ?? catMeta.label}
                                </span>
                                <span class="meta-sep">·</span>
                                <span class="material-icons meta-icon">schedule</span>
                                <span class="meta-date">{formatDate(post.created_at)}</span>
                            </div>

                            {#if expandedId === post.id}
                                <div class="post-body prose">
                                    {@html sanitizeHtml(post.content)}
                                </div>
                                <div class="post-actions">
                                    {#if canPin()}
                                        <button class="action-btn pin" onclick={() => togglePin(post)}>
                                            <span class="material-icons">push_pin</span>
                                            Unpin
                                        </button>
                                    {/if}
                                    {#if canEdit(post)}
                                        <button class="action-btn edit" onclick={() => openEdit(post)}>
                                            <span class="material-icons">edit</span>
                                            Edit
                                        </button>
                                    {/if}
                                    <button class="action-btn delete" onclick={() => askDelete(post.id)}>
                                        <span class="material-icons">delete</span>
                                        Delete
                                    </button>
                                </div>
                            {/if}
                        </div>
                    {/each}
                </div>
            {/if}

            <!-- Regular Posts -->
            {#if regularPosts().length > 0}
                <div class="section-label" style="margin-top: {pinnedPosts.length > 0 ? '16px' : '0'};">
                    <span class="material-icons label-icon">article</span>
                    <span>Posts</span>
                </div>
                <div class="posts-list">
                    {#each regularPosts() as post (post.id)}
                        {@const catMeta = getCategoryMeta(post.category)}
                        <div class="post-card" class:expanded={expandedId === post.id}
                             style="--post-cat-color:{catMeta.color};">
                            <!-- Left color accent bar -->
                            <div class="post-cat-bar" style="background:{catMeta.color};"></div>

                            <button class="post-header" onclick={() => expandedId = expandedId === post.id ? null : post.id}>
                                <div class="post-header-left">
                                    <span
                                        class="priority-badge"
                                        style="color:{PRIORITY_META[post.priority].color};border-color:{PRIORITY_META[post.priority].color};"
                                    >
                                        <span class="material-icons prio-icon">{PRIORITY_META[post.priority].icon}</span>
                                        {PRIORITY_META[post.priority].label}
                                    </span>
                                    <h3 class="post-title">{post.title}</h3>
                                </div>
                                <span class="material-icons expand-icon">{expandedId === post.id ? 'expand_less' : 'expand_more'}</span>
                            </button>

                            <div class="post-meta">
                                <span class="material-icons meta-icon">person</span>
                                <span class="meta-author">{post.author}</span>
                                {#if post.author_rank}
                                    <span class="meta-rank">{post.author_rank}</span>
                                {/if}
                                <span class="meta-sep">·</span>
                                <!-- Category tag with color -->
                                <span
                                    class="meta-cat-tag"
                                    style="color:{catMeta.color};background:{catMeta.color}12;border-color:{catMeta.color}25;"
                                >
                                    <span class="material-icons" style="font-size:10px;">{catMeta.icon}</span>
                                    {post.category_label ?? catMeta.label}
                                </span>
                                <span class="meta-sep">·</span>
                                <span class="material-icons meta-icon">schedule</span>
                                <span class="meta-date">{formatDate(post.created_at)}</span>
                            </div>

                            {#if expandedId === post.id}
                                <div class="post-body prose">
                                    {@html sanitizeHtml(post.content)}
                                </div>
                                <div class="post-actions">
                                    {#if canPin()}
                                        <button class="action-btn pin" onclick={() => togglePin(post)}>
                                            <span class="material-icons">push_pin</span>
                                            Pin
                                        </button>
                                    {/if}
                                    {#if canEdit(post)}
                                        <button class="action-btn edit" onclick={() => openEdit(post)}>
                                            <span class="material-icons">edit</span>
                                            Edit
                                        </button>
                                    {/if}
                                    <button class="action-btn delete" onclick={() => askDelete(post.id)}>
                                        <span class="material-icons">delete</span>
                                        Delete
                                    </button>
                                </div>
                            {/if}
                        </div>
                    {/each}
                </div>
            {:else if pinnedPosts.length === 0}
                <div class="content-empty">
                    <span class="material-icons empty-icon">search_off</span>
                    <h3>No posts found</h3>
                    <p>Try adjusting your search or category filter.</p>
                </div>
            {/if}
        {/if}
    </div>
</div>

<!-- ════════════════════════════════════════════════════════════
     Create / Edit Modal
═════════════════════════════════════════════════════════════ -->
{#if modal.open}
    <div class="modal-backdrop" onclick={closeModal}>
        <div class="modal" onclick={(e) => e.stopPropagation()}>
            <div class="modal-header">
                <span class="material-icons modal-header-icon">
                    {modal.mode === 'create' ? 'add_circle' : 'edit'}
                </span>
                <h3>{modal.mode === 'create' ? 'New Bulletin Post' : 'Edit Post'}</h3>
                <button class="close-btn" onclick={closeModal} aria-label="Close">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
                    </svg>
                </button>
            </div>

            <div class="modal-body">
                <div class="form-group form-full">
                    <span class="field-label">Title <span class="required">*</span></span>
                    <input
                        class="form-input"
                        type="text"
                        placeholder="Post title..."
                        bind:value={modal.post.title}
                        maxlength="255"
                    />
                </div>

                <div class="form-group form-full">
                    <span class="field-label">Category</span>
                    <!-- Chips rather than a dropdown, following the impound form: the choice
                         carries colour and meaning, so it should be visible at a glance
                         instead of hidden behind a click. -->
                    <div class="chip-row">
                        {#each categories as cat}
                            {@const on = modal.post.category === cat.value}
                            <button
                                type="button"
                                class="pick-chip"
                                class:on
                                style={on ? `background:${cat.color}1f; border-color:${cat.color}59; color:${cat.color};` : ''}
                                onclick={() => (modal.post.category = cat.value)}
                            >
                                <span class="chip-dot" style="background:{cat.color};"></span>
                                <span class="material-icons chip-ico">{cat.icon}</span>
                                {cat.label}
                            </button>
                        {/each}
                    </div>
                </div>

                <div class="form-group form-full">
                    <span class="field-label">Priority</span>
                    <div class="chip-row">
                        {#each ['low', 'normal', 'high', 'urgent'] as p}
                            {@const meta = PRIORITY_META[p as BulletinPriority]}
                            {@const on = modal.post.priority === p}
                            <button
                                type="button"
                                class="pick-chip"
                                class:on
                                style={on ? `background:${tint(meta.color, 0.14)}; border-color:${meta.color}; color:${meta.color};` : ''}
                                onclick={() => (modal.post.priority = p as BulletinPriority)}
                            >
                                <span class="material-icons chip-ico">{meta.icon}</span>
                                {meta.label}
                            </button>
                        {/each}
                    </div>
                </div>

                <div class="form-group form-full">
                    <span class="field-label">Content <span class="required">*</span></span>
                    <textarea
                        class="form-input"
                        placeholder="Write your post content here... (HTML supported)"
                        bind:value={modal.post.content}
                        rows="8"
                    ></textarea>
                    <span class="field-hint">Basic HTML tags are supported: &lt;b&gt;, &lt;ul&gt;, &lt;li&gt;, &lt;p&gt;, etc.</span>
                </div>

                {#if canPin()}
                    <!-- Same switch the Settings tab uses for every other boolean. -->
                    <div class="form-group form-full toggle-row">
                        <label class="toggle">
                            <input type="checkbox" bind:checked={modal.post.pinned} />
                            <span class="toggle-slider"></span>
                        </label>
                        <div class="toggle-text">
                            <span class="toggle-title">
                                <span class="material-icons">push_pin</span>
                                Pin to top
                            </span>
                            <span class="toggle-sub">Keeps this post above all others in its category</span>
                        </div>
                    </div>
                {/if}
            </div>

            <div class="modal-footer">
                <button class="cancel-btn" onclick={closeModal} disabled={saving}>Cancel</button>
                <button
                    class="primary-btn"
                    onclick={savePost}
                    disabled={saving || !modal.post.title?.trim() || !modal.post.content?.trim()}
                >
                    {#if saving}
                        <div class="spinner-sm"></div>
                    {:else}
                        <span class="material-icons" style="font-size: 13px;">save</span>
                    {/if}
                    {modal.mode === 'create' ? 'Post' : 'Save Changes'}
                </button>
            </div>
        </div>
    </div>
{/if}

<!-- ════════════════════════════════════════════════════════════
     Delete Confirm Modal
═════════════════════════════════════════════════════════════ -->
{#if deleteConfirm.open}
    <div class="modal-backdrop" onclick={() => deleteConfirm = { open: false, postId: null }}>
        <div class="modal modal-sm" onclick={(e) => e.stopPropagation()}>
            <div class="modal-header">
                <span class="material-icons modal-header-icon" style="color: rgba(220,70,60,0.85);">warning</span>
                <h3>Delete Post</h3>
                <button class="close-btn" onclick={() => deleteConfirm = { open: false, postId: null }} aria-label="Close">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
                    </svg>
                </button>
            </div>
            <div class="modal-body">
                <p class="confirm-text">Are you sure you want to delete this post? This action cannot be undone.</p>
            </div>
            <div class="modal-footer">
                <button class="cancel-btn" onclick={() => deleteConfirm = { open: false, postId: null }} disabled={saving}>Cancel</button>
                <button class="delete-btn" onclick={confirmDelete} disabled={saving}>
                    {#if saving}<div class="spinner-sm"></div>{:else}<span class="material-icons" style="font-size: 13px;">delete</span>{/if}
                    Delete
                </button>
            </div>
        </div>
    </div>
{/if}

<style>
    /* Aligned to the MDT's house style (Bolos, the roster table, the impound form):
       3px radii, hairline 1px borders, 9-12px type, 42px header bars, 0.1s transitions.
       List surfaces are flat with hairline separators rather than rounded cards. */

    /* ── Layout ──────────────────────────────────────────────── */
    .bulletin-page { display: flex; height: 100%; overflow: hidden; background: var(--card-dark-bg); color: rgba(255, 255, 255, 0.9); }

    /* ── Sidebar ─────────────────────────────────────────────── */
    .bulletin-sidebar {
        width: 240px; min-width: 240px;
        border-right: 1px solid rgba(255,255,255,0.06);
        display: flex; flex-direction: column; overflow: hidden;
    }

    /* Matches the 42px topbar every other list view uses. */
    .sidebar-header {
        height: 42px; padding: 0 16px;
        display: flex; align-items: center; gap: 8px;
        border-bottom: 1px solid rgba(255,255,255,0.06);
        flex-shrink: 0;
    }

    .header-icon { font-size: 16px; color: var(--accent-70); }
    .sidebar-header h2 { font-size: 12px; font-weight: 600; color: rgba(255,255,255,0.85); margin: 0; }

    .search-box { padding: 10px 12px; position: relative; flex-shrink: 0; }
    .search-icon { position: absolute; left: 21px; top: 50%; transform: translateY(-50%); font-size: 14px; color: rgba(255,255,255,0.25); }
    .search-box input {
        width: 100%; padding: 5px 8px 5px 28px;
        background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06);
        border-radius: 3px; color: rgba(255,255,255,0.8); font-size: 11px; font-family: inherit; outline: none; transition: border-color 0.1s;
    }
    .search-box input:focus { border-color: var(--accent-35); }
    .search-box input::placeholder { color: rgba(255,255,255,0.2); }

    .category-list {
        flex: 1; overflow-y: auto; padding: 2px 6px;
        scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.06) transparent;
    }
    .category-list::-webkit-scrollbar { width: 4px; }
    .category-list::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.06); border-radius: 2px; }

    .category-item {
        width: 100%; display: flex; align-items: center; gap: 8px;
        padding: 6px 9px;
        border: 1px solid transparent; background: transparent;
        border-radius: 3px; cursor: pointer; text-align: left;
        transition: all 0.1s; margin-bottom: 1px; outline: none;
        position: relative; overflow: hidden;
    }
    .category-item:hover:not(.active) { background: rgba(255,255,255,0.03); }
    /* The active tint/border come from an inline style built with 8-digit hex alpha —
       color-mix() is unreliable in CEF, which is why the rest of this file already uses
       the `${color}14` form. */

    .cat-color-dot {
        width: 5px; height: 5px; border-radius: 50%; flex-shrink: 0;
        opacity: 0.75;
    }

    .cat-active-bar {
        position: absolute; right: 0; top: 22%; bottom: 22%;
        width: 2px; opacity: 0.7;
    }

    .cat-icon { font-size: 15px; color: rgba(255,255,255,0.35); flex-shrink: 0; }

    .cat-info { display: flex; flex-direction: column; gap: 1px; min-width: 0; flex: 1; }
    .cat-title { font-size: 11px; font-weight: 500; color: rgba(255,255,255,0.75); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .cat-count { font-size: 9px; color: rgba(255,255,255,0.3); }

    .sidebar-footer { padding: 10px 12px; border-top: 1px solid rgba(255,255,255,0.06); flex-shrink: 0; }

    /* Green is this codebase's "create" colour — Bolos' .new-btn and the modal's own
       .primary-btn both use it. Blue read as navigation rather than as an action. */
    .create-btn {
        width: 100%; display: flex; align-items: center; justify-content: center; gap: 5px;
        padding: 6px 10px; background: rgba(16,185,129,0.06); border: 1px solid rgba(16,185,129,0.12);
        border-radius: 3px; color: rgba(52,211,153,0.75);
        font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.4px;
        cursor: pointer; transition: all 0.1s; outline: none;
    }
    .create-btn:hover { background: rgba(16,185,129,0.13); border-color: rgba(16,185,129,0.22); color: rgba(110,231,183,0.95); }
    .create-btn .material-icons { font-size: 14px; }

    /* ── Main Content ────────────────────────────────────────── */
    .bulletin-content {
        flex: 1; overflow-y: auto; padding: 14px 16px;
        scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.06) transparent;
    }
    .bulletin-content::-webkit-scrollbar { width: 5px; }
    .bulletin-content::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.06); border-radius: 3px; }

    /* Category header bar */
    .content-cat-header {
        display: flex; align-items: center; gap: 7px;
        padding: 6px 11px; border-radius: 3px; border-left: 2px solid;
        margin-bottom: 12px;
    }
    .content-cat-title { font-size: 11px; font-weight: 600; }
    .content-cat-sep   { color: rgba(255,255,255,0.18); font-size: 11px; }
    .content-cat-count { font-size: 10px; color: rgba(255,255,255,0.35); }

    .content-empty {
        display: flex; flex-direction: column; align-items: center; justify-content: center;
        height: 100%; gap: 6px; color: rgba(255,255,255,0.35); text-align: center;
    }
    .empty-icon { font-size: 32px; color: rgba(255,255,255,0.12); margin-bottom: 4px; }
    .content-empty h3 { font-size: 13px; font-weight: 500; color: rgba(255,255,255,0.5); margin: 0; }
    .content-empty p  { font-size: 11px; color: rgba(255,255,255,0.3); margin: 0; }

    .section-label {
        display: flex; align-items: center; gap: 5px;
        font-size: 9px; font-weight: 700; text-transform: uppercase;
        letter-spacing: 0.6px; color: rgba(255,255,255,0.28); margin-bottom: 7px;
    }
    .label-icon { font-size: 12px; color: rgba(255,255,255,0.22); }

    .posts-list { display: flex; flex-direction: column; gap: 4px; margin-bottom: 8px; }

    /* ── Post cards ──────────────────────────────────────────── */
    /* Flat and squared like .bolo-row, not rounded cards. */
    .post-card {
        background: rgba(255,255,255,0.02);
        border: 1px solid rgba(255,255,255,0.04);
        border-radius: 3px; overflow: hidden; transition: border-color 0.1s;
        position: relative;
    }
    .post-card:hover { border-color: rgba(255,255,255,0.09); }

    /* Left accent bar (regular posts) */
    .post-cat-bar {
        position: absolute; left: 0; top: 0; bottom: 0;
        width: 2px; opacity: 0.6;
    }

    .post-card.pinned {
        background: rgba(59,130,246,0.06);
        border-color: rgba(59,130,246,0.15);
    }
    .post-card.pinned:hover { border-color: rgba(59,130,246,0.25); }

    .post-card.expanded { border-color: rgba(255,255,255,0.1); }
    .post-card.pinned.expanded { border-color: rgba(59,130,246,0.28); }

    .post-header {
        width: 100%; display: flex; align-items: center; justify-content: space-between; gap: 10px;
        padding: 8px 12px 8px 16px;
        background: transparent; border: none; cursor: pointer; text-align: left; outline: none;
    }
    .post-header-left  { display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1; }
    .post-header-right { display: flex; align-items: center; gap: 5px; flex-shrink: 0; }

    /* Same shape as .status-pill elsewhere: 9px uppercase, 3px radius. */
    .priority-badge {
        display: inline-flex; align-items: center; gap: 3px;
        padding: 1px 6px 1px 4px; border: 1px solid; border-radius: 3px;
        font-size: 9px; font-weight: 600; text-transform: uppercase;
        letter-spacing: 0.3px; flex-shrink: 0; white-space: nowrap;
    }
    .prio-icon { font-size: 10px; }

    .post-title {
        font-size: 12px; font-weight: 600; color: rgba(255,255,255,0.85);
        margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }

    .pin-icon    { font-size: 13px; }
    .expand-icon { font-size: 15px; color: rgba(255,255,255,0.22); flex-shrink: 0; }

    /* Meta row */
    .post-meta {
        display: flex; align-items: center; gap: 5px;
        padding: 0 12px 7px 16px; flex-wrap: wrap;
    }
    .meta-icon   { font-size: 11px; color: rgba(255,255,255,0.22); }
    .meta-author { font-size: 10px; font-weight: 500; color: rgba(255,255,255,0.5); }
    .meta-rank   {
        font-size: 9px; color: rgba(255,255,255,0.3);
        background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06);
        border-radius: 3px; padding: 1px 5px;
    }
    .meta-sep  { color: rgba(255,255,255,0.15); font-size: 10px; }
    .meta-date { font-size: 10px; color: rgba(255,255,255,0.28); }

    .meta-cat-tag {
        display: inline-flex; align-items: center; gap: 3px;
        font-size: 9px; font-weight: 500;
        padding: 1px 6px; border-radius: 3px; border: 1px solid;
    }

    /* Post body */
    .post-body {
        padding: 11px 12px 11px 16px; border-top: 1px solid rgba(255,255,255,0.04);
        color: rgba(255,255,255,0.7); font-size: 12px; line-height: 1.65;
    }
    .post-body :global(h1), .post-body :global(h2), .post-body :global(h3) { color: rgba(255,255,255,0.88); margin: 10px 0 5px; }
    .post-body :global(h1) { font-size: 13px; }
    .post-body :global(h2) { font-size: 12.5px; }
    .post-body :global(h3) { font-size: 12px; }
    .post-body :global(p)  { margin: 5px 0; }
    .post-body :global(ul), .post-body :global(ol) { padding-left: 18px; margin: 5px 0; }
    .post-body :global(li) { margin: 3px 0; }
    .post-body :global(strong) { color: rgba(255,255,255,0.93); }

    /* Post actions */
    .post-actions {
        display: flex; align-items: center; gap: 5px;
        padding: 8px 12px 9px 16px; border-top: 1px solid rgba(255,255,255,0.04);
    }

    /* House button spec, matching .action-btn / .delete-btn in Bolos. */
    .action-btn {
        display: inline-flex; align-items: center; gap: 4px;
        padding: 4px 10px; border-radius: 3px; font-size: 10px; font-weight: 500;
        cursor: pointer; border: 1px solid; transition: all 0.1s; outline: none;
    }
    .action-btn .material-icons { font-size: 12px; }
    .action-btn.pin  { color: var(--accent-70); background: var(--accent-06); border-color: var(--accent-10); }
    .action-btn.pin:hover  { background: var(--accent-15); }
    .action-btn.edit { color: rgba(255,255,255,0.5); background: rgba(255,255,255,0.03); border-color: rgba(255,255,255,0.06); }
    .action-btn.edit:hover { color: rgba(255,255,255,0.85); background: rgba(255,255,255,0.06); }
    .action-btn.delete { color: rgba(248,113,113,0.6); background: rgba(239,68,68,0.05); border-color: rgba(239,68,68,0.1); margin-left: auto; }
    .action-btn.delete:hover { background: rgba(239,68,68,0.12); color: rgba(248,113,113,0.9); }

    /* ════ Modals ════════════════════════════════════════════ */
    /* No backdrop-filter: CEF paints it as a solid black block rather than blurring, so a
       plain darker scrim is used instead — same as the impound and application forms. */
    .modal-backdrop {
        position: fixed; inset: 0; background: rgba(0,0,0,0.6);
        display: flex; align-items: center; justify-content: center; z-index: 100;
    }
    .modal {
        background: var(--card-dark-bg, #1a1c22); border: 1px solid rgba(255,255,255,0.06);
        border-radius: 6px; width: min(540px, 92vw); max-height: 85vh; overflow: hidden;
        display: flex; flex-direction: column; box-shadow: 0 20px 60px rgba(0,0,0,0.5);
    }
    .modal-sm { width: min(380px, 92vw); }

    .modal-header {
        display: flex; align-items: center; gap: 10px;
        padding: 10px 16px; border-bottom: 1px solid rgba(255,255,255,0.06); flex-shrink: 0;
    }
    .modal-header-icon { font-size: 16px; color: var(--accent-70); }
    .modal-header h3 { font-size: 12px; font-weight: 600; color: rgba(255,255,255,0.85); margin: 0; flex: 1; }

    .close-btn {
        display: flex; align-items: center; justify-content: center;
        background: transparent; color: rgba(255,255,255,0.3);
        border: 1px solid rgba(255,255,255,0.06); padding: 4px; border-radius: 3px;
        cursor: pointer; transition: all 0.1s; outline: none;
    }
    .close-btn:hover { color: rgba(255,255,255,0.7); border-color: rgba(255,255,255,0.1); }

    .modal-body {
        flex: 1; overflow-y: auto; padding: 14px 16px;
        display: grid; grid-template-columns: 1fr 1fr; gap: 10px; align-content: start;
        scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.06) transparent;
    }

    .form-group { display: flex; flex-direction: column; gap: 4px; }
    .form-full  { grid-column: 1 / -1; }

    .field-label { font-size: 9px; font-weight: 600; color: rgba(255,255,255,0.35); text-transform: uppercase; letter-spacing: 0.6px; }
    .required    { color: rgba(248,113,113,0.85); }

    .form-input {
        background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06); border-radius: 3px;
        padding: 5px 8px; color: rgba(255,255,255,0.8); font-size: 11px; font-family: inherit; outline: none; transition: border-color 0.1s;
    }
    .form-input:focus { border-color: var(--accent-35); }
    .form-input::placeholder { color: rgba(255,255,255,0.2); }
    textarea.form-input { resize: vertical; min-height: 120px; line-height: 1.6; }

    .field-hint  { font-size: 9px; color: rgba(255,255,255,0.25); }

    .confirm-text { font-size: 11px; color: rgba(255,255,255,0.6); margin: 0; line-height: 1.6; grid-column: 1 / -1; }

    .modal-footer {
        display: flex; align-items: center; justify-content: flex-end; gap: 6px;
        padding: 10px 16px; border-top: 1px solid rgba(255,255,255,0.06); flex-shrink: 0;
    }

    .cancel-btn {
        background: transparent; border: 1px solid rgba(255,255,255,0.06); border-radius: 3px;
        padding: 4px 12px; color: rgba(255,255,255,0.4); font-size: 10px; font-weight: 500; cursor: pointer; outline: none; transition: all 0.1s;
    }
    .cancel-btn:hover:not(:disabled) { color: rgba(255,255,255,0.7); border-color: rgba(255,255,255,0.1); }
    .cancel-btn:disabled { opacity: 0.3; cursor: not-allowed; }

    .primary-btn {
        display: flex; align-items: center; gap: 4px;
        background: rgba(16,185,129,0.06); border: 1px solid rgba(16,185,129,0.1); border-radius: 3px;
        padding: 4px 12px; color: rgba(52,211,153,0.7); font-size: 10px; font-weight: 600; cursor: pointer; outline: none; transition: all 0.1s;
    }
    .primary-btn:hover:not(:disabled) { background: rgba(16,185,129,0.12); color: rgba(110,231,183,0.9); }
    .primary-btn:disabled { opacity: 0.3; cursor: not-allowed; }

    .delete-btn {
        display: flex; align-items: center; gap: 4px;
        background: rgba(239,68,68,0.06); border: 1px solid rgba(239,68,68,0.15); border-radius: 3px;
        padding: 4px 12px; color: rgba(248,113,113,0.8); font-size: 10px; font-weight: 600; cursor: pointer; outline: none; transition: all 0.1s;
    }
    .delete-btn:hover:not(:disabled) { background: rgba(239,68,68,0.12); color: rgba(248,113,113,1); }
    .delete-btn:disabled { opacity: 0.3; cursor: not-allowed; }

    /* ── Chip pickers ─────────────────────────────────────────── */
    /* Same construction as the impound form's hold-period chips. */
    .chip-row { display: flex; flex-wrap: wrap; gap: 4px; }
    .pick-chip {
        display: inline-flex; align-items: center; gap: 5px;
        background: rgba(255,255,255,0.03);
        border: 1px solid rgba(255,255,255,0.07);
        border-radius: 3px;
        color: rgba(255,255,255,0.5);
        font-size: 10px; font-weight: 600;
        padding: 4px 9px;
        cursor: pointer; transition: all 0.1s; outline: none;
        font-family: inherit;
    }
    .pick-chip:hover:not(.on) { color: rgba(255,255,255,0.85); border-color: rgba(255,255,255,0.15); }
    /* The `on` colours arrive as an inline style built from the category/priority colour,
       so each chip lights up in its own hue. */
    .chip-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; opacity: 0.85; }
    .chip-ico { font-size: 12px; }

    /* ── Pin toggle ───────────────────────────────────────────── */
    /* Lifted from the Settings tab so booleans look the same everywhere in the MDT. */
    .toggle-row { flex-direction: row; align-items: center; gap: 10px; }
    .toggle {
        position: relative; display: inline-block;
        width: 32px; height: 18px; flex-shrink: 0;
    }
    .toggle input { opacity: 0; width: 0; height: 0; }
    .toggle-slider {
        position: absolute; cursor: pointer;
        top: 0; left: 0; right: 0; bottom: 0;
        background: rgba(255,255,255,0.06);
        border: 1px solid rgba(255,255,255,0.05);
        border-radius: 18px;
        transition: background 0.2s ease, border-color 0.2s ease;
    }
    .toggle-slider:hover { border-color: rgba(255,255,255,0.12); }
    .toggle-slider::before {
        content: ""; position: absolute;
        height: 12px; width: 12px; left: 2px; bottom: 2px;
        background: rgba(255,255,255,0.4);
        border-radius: 50%;
        transition: transform 0.2s ease, background 0.2s ease;
    }
    .toggle input:checked + .toggle-slider {
        background: rgba(var(--accent-rgb), 0.35);
        border-color: rgba(var(--accent-rgb), 0.3);
    }
    .toggle input:checked + .toggle-slider::before {
        transform: translateX(14px);
        background: rgba(255,255,255,0.85);
    }
    .toggle-text { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
    .toggle-title {
        display: flex; align-items: center; gap: 5px;
        font-size: 11px; font-weight: 500; color: rgba(255,255,255,0.75);
    }
    .toggle-title .material-icons { font-size: 13px; color: rgba(255,255,255,0.4); }
    .toggle-sub { font-size: 9px; color: rgba(255,255,255,0.28); }

    /* ── Spinners ─────────────────────────────────────────────── */
    .spinner {
        width: 22px; height: 22px;
        border: 2px solid rgba(255,255,255,0.06); border-left-color: var(--accent-60);
        border-radius: 50%; animation: spin 0.8s linear infinite; margin-bottom: 8px;
    }
    .spinner-sm {
        width: 11px; height: 11px;
        border: 2px solid rgba(255,255,255,0.1); border-left-color: currentColor;
        border-radius: 50%; animation: spin 0.8s linear infinite;
    }

    @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
</style>