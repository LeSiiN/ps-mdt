<script lang="ts">
	import Skeleton from "./Skeleton.svelte";

	/**
	 * A stack of placeholder rows for a list or table view. The point of matching the
	 * real row's rough shape — a thumbnail, then a few columns of varying width — is that
	 * when the data lands, nothing shifts; the skeleton was already the right size.
	 */
	interface Props {
		/** How many placeholder rows to show. */
		rows?: number;
		/** Show a leading thumbnail/avatar square on each row. */
		thumb?: boolean;
		/** Relative column widths, e.g. [2, 1, 1, 0.6]. Defaults to a sensible spread. */
		columns?: number[];
	}

	let { rows = 8, thumb = true, columns = [2, 1.3, 1, 0.8] }: Props = $props();

	// A little jitter per row so it reads as content, not a printed grid.
	const widths = ["82%", "68%", "90%", "74%", "60%", "86%"];
</script>

<div class="sk-list" aria-hidden="true">
	{#each Array(rows) as _, r (r)}
		<div class="sk-row">
			{#if thumb}
				<Skeleton height="34px" circle={false} radius="6px" width="34px" />
			{/if}
			<div class="sk-cols">
				{#each columns as col, c (c)}
					<div class="sk-col" style="flex: {col};">
						<Skeleton height="11px" width={widths[(r + c) % widths.length]} />
					</div>
				{/each}
			</div>
		</div>
	{/each}
</div>

<style>
	.sk-list {
		display: flex;
		flex-direction: column;
	}
	.sk-row {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 11px 10px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
	}
	.sk-cols {
		display: flex;
		align-items: center;
		gap: 12px;
		flex: 1;
		min-width: 0;
	}
	.sk-col {
		min-width: 0;
	}
</style>
