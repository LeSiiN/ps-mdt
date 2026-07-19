<script lang="ts">
	/**
	 * Audit / activity timeline for a person (officer or citizen): every recorded
	 * change keyed to their citizenid (promotions, callsign changes, status, DNA/
	 * fingerprint edits, jailing, …), newest first, paginated. Backed by
	 * mdt_audit_logs via getCitizenTimeline. Styled to match the boss-panel's
	 * IA-history list so it stays visually consistent with the other tabs.
	 */
	import { fetchNui } from "../utils/fetchNui";
	import { formatDateTime } from "../utils/datetime";
	import { NUI_EVENTS } from "../constants/nuiEvents";

	let { citizenid }: { citizenid: string } = $props();

	interface TimelineEntry {
		id: number;
		actor_citizenid: string | null;
		actor_name: string | null;
		action: string;
		entity_type: string;
		details: string | null;
		created_at: string;
	}

	let entries = $state<TimelineEntry[]>([]);
	let page = $state(1);
	let hasMore = $state(false);
	let loading = $state(false);
	let loadedFor = $state<string | null>(null);

	// Filtering happens server-side: the component only holds the pages it has already
	// pulled, so filtering here would quietly miss everything further back.
	let search = $state("");
	let searchTimer: ReturnType<typeof setTimeout> | undefined;

	function onSearchInput() {
		// One request per pause in typing rather than one per keystroke.
		if (searchTimer !== undefined) clearTimeout(searchTimer);
		searchTimer = setTimeout(() => {
			page = 1;
			entries = [];
			hasMore = false;
			load(1, false);
		}, 250);
	}

	function clearSearch() {
		if (!search) return;
		search = "";
		if (searchTimer !== undefined) clearTimeout(searchTimer);
		page = 1;
		entries = [];
		hasMore = false;
		load(1, false);
	}

	// "warrant_request_created" -> "Warrant request created"
	function pretty(action: string): string {
		const s = action.replace(/_/g, " ");
		return s.charAt(0).toUpperCase() + s.slice(1);
	}

	// Prefer the readable, detail-rich label the server already built (e.g.
	// "Assigned John Doe to 10-13" or "Dismissed 10-71 (Shooting) for all
	// units"); fall back to a prettified action name when there's no label.
	function label(e: TimelineEntry): string {
		if (e.details) {
			try {
				const d = JSON.parse(e.details) as Record<string, unknown>;
				if (typeof d.action_label === "string" && d.action_label.trim()) {
					return d.action_label;
				}
			} catch { /* fall through to pretty() */ }
		}
		return pretty(e.action);
	}

	function fmt(ts: string): string {
		return formatDateTime(ts, ts);
	}

	async function load(targetPage: number, append: boolean) {
		if (!citizenid) return;
		loading = true;
		try {
			const res = await fetchNui<{
				entries: TimelineEntry[];
				hasMore: boolean;
			}>(
				NUI_EVENTS.CITIZEN.GET_CITIZEN_TIMELINE,
				{ citizenid, page: targetPage, search: search.trim() || undefined },
				{ entries: [], hasMore: false },
			);
			const rows = Array.isArray(res?.entries) ? res.entries : [];
			entries = append ? [...entries, ...rows] : rows;
			hasMore = !!res?.hasMore;
			page = targetPage;
		} catch {
			if (!append) entries = [];
		} finally {
			loading = false;
		}
	}

	// Reload whenever the selected citizen changes.
	$effect(() => {
		const cid = citizenid;
		if (cid && cid !== loadedFor) {
			loadedFor = cid;
			search = "";
			page = 1;
			entries = [];
			hasMore = false;
			load(1, false);
		}
	});
</script>

<div class="act-search">
	<span class="material-icons act-search-icon">search</span>
	<input
		type="text"
		placeholder="Search activity..."
		bind:value={search}
		oninput={onSearchInput}
	/>
	{#if search}
		<button class="act-search-clear" aria-label="Clear search" onclick={clearSearch}>
			<span class="material-icons">close</span>
		</button>
	{/if}
</div>

{#if loading && entries.length === 0}
	<p class="act-hint">Loading...</p>
{:else if entries.length === 0}
	<div class="no-tags">
		<span class="material-icons no-tags-icon">history</span>
		<p>{search ? "No activity matches that search." : "No recorded activity for this officer."}</p>
	</div>
{:else}
	<div class="act-list">
		{#each entries as e (e.id)}
			<div class="act-item">
				<div class="act-info">
					<span class="act-action">{label(e)}</span>
				</div>
				<div class="act-meta">
					<span>{e.actor_name ?? e.actor_citizenid ?? "System"}</span>
					<span class="act-date">{fmt(e.created_at)}</span>
				</div>
			</div>
		{/each}
	</div>
	{#if hasMore}
		<button class="act-more" disabled={loading} onclick={() => load(page + 1, true)}>
			{loading ? "Loading..." : "Load more"}
		</button>
	{/if}
{/if}

<style>
	/* Same construction as the other inline search fields in the MDT (bulletin board,
	   camera list): bordered box, icon inset on the left, 11px type, 3px radius. */
	.act-search {
		position: relative;
		display: flex;
		align-items: center;
		margin-bottom: 8px;
	}
	.act-search-icon {
		position: absolute;
		left: 8px;
		font-size: 14px;
		color: rgba(255, 255, 255, 0.25);
		pointer-events: none;
	}
	.act-search input {
		width: 100%;
		padding: 5px 26px 5px 28px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 11px;
		font-family: inherit;
		outline: none;
		box-sizing: border-box;
		transition: border-color 0.1s;
	}
	.act-search input:focus { border-color: rgba(var(--accent-rgb), 0.35); }
	.act-search input::placeholder { color: rgba(255, 255, 255, 0.2); }
	.act-search-clear {
		position: absolute;
		right: 5px;
		display: grid;
		place-items: center;
		width: 18px;
		height: 18px;
		padding: 0;
		border: none;
		border-radius: 3px;
		background: transparent;
		color: rgba(255, 255, 255, 0.3);
		cursor: pointer;
	}
	.act-search-clear:hover { color: rgba(255, 255, 255, 0.75); background: rgba(255, 255, 255, 0.05); }
	.act-search-clear .material-icons { font-size: 13px; }

	/* Mirrors .ia-history-* in Roster.svelte for a consistent boss-panel look. */
	.act-list {
		display: flex;
		flex-direction: column;
		gap: 6px;
		max-height: 300px;
		overflow-y: auto;
		overflow-x: hidden;
		margin-right: -4px;
		padding-right: 4px;
	}
	.act-item {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 6px;
		padding: 8px 10px;
	}
	.act-info {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-bottom: 3px;
	}
	.act-action {
		font-size: 11px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.87);
		overflow-wrap: anywhere;
	}
	.act-meta {
		display: flex;
		align-items: center;
		gap: 8px;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.4);
	}
	.act-meta > span:first-child {
		overflow-wrap: anywhere;
		min-width: 0;
	}
	.act-date {
		margin-left: auto;
		white-space: nowrap;
	}
	.act-hint {
		font-size: 10px;
		color: rgba(255, 255, 255, 0.25);
		margin: 0 0 6px;
		line-height: 1.4;
	}
	.no-tags {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 6px;
		padding: 20px;
		color: rgba(255, 255, 255, 0.3);
		text-align: center;
	}
	.no-tags-icon {
		font-size: 28px;
		color: rgba(255, 255, 255, 0.2);
	}
	.no-tags p {
		margin: 0;
		font-size: 11px;
	}
	.act-more {
		width: 100%;
		margin-top: 6px;
		padding: 6px;
		font-size: 10px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.3px;
		color: rgba(255, 255, 255, 0.6);
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 6px;
		cursor: pointer;
		transition: all 0.15s;
	}
	.act-more:hover:not(:disabled) {
		background: rgba(255, 255, 255, 0.06);
		color: rgba(255, 255, 255, 0.8);
	}
	.act-more:disabled {
		opacity: 0.5;
		cursor: default;
	}
</style>