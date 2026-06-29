<script lang="ts">
	/**
	 * Live dispatch breakdown: how many on-duty officers in this domain are
	 * currently in each status (Active / Busy / …). Self-contained — fetches and
	 * polls its own data so it can be dropped anywhere on the dashboard without
	 * touching the main dashboard payload.
	 */
	import { onMount, onDestroy } from "svelte";
	import { fetchNui } from "../../utils/fetchNui";
	import { NUI_EVENTS } from "../../constants/nuiEvents";

	interface StatusCount {
		id: string;
		label: string;
		color: string;
		count: number;
	}
	interface Breakdown {
		total: number;
		statuses: StatusCount[];
	}

	let breakdown = $state<Breakdown>({ total: 0, statuses: [] });
	let timer: ReturnType<typeof setInterval> | null = null;

	async function load() {
		try {
			const res = await fetchNui<Breakdown>(
				NUI_EVENTS.MAP.GET_OFFICER_STATUS_BREAKDOWN,
				{},
				{ total: 0, statuses: [] },
			);
			if (res && Array.isArray(res.statuses)) breakdown = res;
		} catch {
			/* keep last good values on a transient failure */
		}
	}

	onMount(() => {
		load();
		timer = setInterval(load, 15000);
	});
	onDestroy(() => {
		if (timer) {
			clearInterval(timer);
			timer = null;
		}
	});
</script>

{#if breakdown.statuses.length > 0}
	<div class="dispatch-status" aria-label="Officer status breakdown">
		{#each breakdown.statuses as s (s.id)}
			<div class="ds-chip" class:ds-muted={s.count === 0}>
				<span class="ds-dot" style="background:{s.color}"></span>
				<span class="ds-count">{s.count}</span>
				<span class="ds-label">{s.label}</span>
			</div>
		{/each}
	</div>
{/if}

<style>
	.dispatch-status {
		display: flex;
		align-items: center;
		gap: 12px;
	}
	.ds-chip {
		display: flex;
		align-items: center;
		gap: 5px;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.82);
	}
	.ds-chip.ds-muted {
		opacity: 0.4;
	}
	.ds-dot {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		flex: 0 0 auto;
		box-shadow: 0 0 6px rgba(0, 0, 0, 0.4);
	}
	.ds-count {
		font-weight: 600;
		font-variant-numeric: tabular-nums;
	}
	.ds-label {
		color: rgba(255, 255, 255, 0.55);
	}
</style>
