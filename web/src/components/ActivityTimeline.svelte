<script lang="ts">
	/**
	 * Audit / activity timeline for a person (officer or citizen): every recorded
	 * change keyed to their citizenid (promotions, callsign changes, status, DNA/
	 * fingerprint edits, jailing, …), newest first, paginated. Backed by
	 * mdt_audit_logs via getCitizenTimeline. Styled to match the boss-panel's
	 * IA-history list so it stays visually consistent with the other tabs.
	 */
	import { fetchNui } from "../utils/fetchNui";
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
		const d = new Date(ts.replace(" ", "T"));
		return isNaN(d.getTime()) ? ts : d.toLocaleString();
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
				{ citizenid, page: targetPage },
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
			page = 1;
			entries = [];
			hasMore = false;
			load(1, false);
		}
	});
</script>

{#if loading && entries.length === 0}
	<p class="act-hint">Loading...</p>
{:else if entries.length === 0}
	<div class="no-tags">
		<span class="material-icons no-tags-icon">history</span>
		<p>No recorded activity for this officer.</p>
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