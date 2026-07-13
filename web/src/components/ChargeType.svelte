<script lang="ts">
	import type { Charge } from "./../interfaces/ICharges";

	interface Props {
		type: Charge["type"];
		groupedCharges: Record<string, Charge[]>;
		collapsed: boolean;
		onToggle: () => void;
		onUpdate?: (charge: Charge, payload: Partial<Charge>) => Promise<boolean>;
		onManage?: (charge: Charge) => void;
		colorClass?: string;
		canManage?: boolean;
	}

	let {
		type,
		groupedCharges,
		collapsed,
		onToggle,
		onManage,
		colorClass = "",
		canManage = false,
	}: Props = $props();

	function getNumericValue(
		charge: Charge,
		keys: Array<"fine" | "time" | "months">
	): number {
		for (const key of keys) {
			const value = (charge as unknown as Record<string, unknown>)[key];
			const numeric = Number(value);
			if (Number.isFinite(numeric) && numeric > 0) {
				return numeric;
			}
			if (numeric === 0) {
				return 0;
			}
		}
		return 0;
	}

	function getFineValue(charge: Charge) {
		return getNumericValue(charge, ["fine"]);
	}

	function getTimeValue(charge: Charge) {
		return getNumericValue(charge, ["time", "months"]);
	}

	function getTypePillClass(): string {
		switch (type) {
			case "felony": return "pill-red";
			case "misdemeanor": return "pill-orange";
			case "infraction": return "pill-green";
			default: return "pill-grey";
		}
	}

	function formatFine(value: number): string {
		return `$${value.toLocaleString()}`;
	}

	function formatTime(value: number): string {
		if (value === 0) return "-";
		return `${value}mo`;
	}
</script>

<div class="charge-section">
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
	<div class="section-header" onclick={onToggle}>
		<span class="section-title">
			<span class="pill {getTypePillClass()}">{type.charAt(0).toUpperCase() + type.slice(1)}s</span>
			<span class="charge-count">{Object.values(groupedCharges).reduce((a, b) => a + b.length, 0)}</span>
		</span>
		<svg class="chevron" class:collapsed width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
	</div>

	{#if !collapsed}
		{#each Object.entries(groupedCharges) as [category, chargeList]}
			<div class="category-group">
				<div class="category-label">{category}</div>
				<div class="table-header">
					<span class="col-code">Code</span>
					<span class="col-label">Charge</span>
					<span class="col-desc">Description</span>
					<span class="col-fine">Fine</span>
					<span class="col-time">Time</span>
					{#if canManage}
						<span class="col-actions"></span>
					{/if}
				</div>
				{#each chargeList as charge (charge.code || charge.label)}
					<!-- svelte-ignore a11y_click_events_have_key_events -->
					<!-- svelte-ignore a11y_no_static_element_interactions -->
					<div
						class="charge-row"
						class:clickable={canManage}
						title={canManage ? "Click to edit this charge" : ""}
						onclick={() => canManage && onManage?.(charge)}
					>
						<span class="col-code">
							{#if charge.code}
								<span class="code-tag">{charge.code}</span>
							{:else}
								<span class="muted">-</span>
							{/if}
						</span>
						<span class="col-label">{charge.label}</span>
						<span class="col-desc">{charge.description}</span>
						<span class="col-fine">{formatFine(getFineValue(charge))}</span>
						<span class="col-time">{formatTime(getTimeValue(charge))}</span>
						{#if canManage}
							<span class="col-actions">
								<span class="material-icons edit-hint-icon">tune</span>
							</span>
						{/if}
					</div>
				
				{/each}
			</div>
		{/each}
	{/if}
</div>

<style>
	.charge-section {
		background: transparent;
		border: none;
		border-radius: 0;
		overflow: hidden;
		margin-bottom: 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}

	.section-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 8px 16px;
		cursor: pointer;
		transition: background 0.1s;
	}

	.section-header:hover {
		background: rgba(255, 255, 255, 0.02);
	}

	.section-title {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.charge-count {
		color: rgba(255, 255, 255, 0.2);
		font-size: 10px;
	}

	.chevron {
		color: rgba(255, 255, 255, 0.35);
		transition: transform 0.15s ease;
	}

	.chevron.collapsed {
		transform: rotate(-90deg);
	}

	.pill {
		display: inline-flex;
		align-items: center;
		padding: 1px 6px;
		border-radius: 3px;
		font-size: 9px;
		font-weight: 600;
	}

	.pill-red {
		background: rgba(239, 68, 68, 0.08);
		color: rgba(252, 165, 165, 0.8);
		border: 1px solid rgba(239, 68, 68, 0.1);
	}

	.pill-orange {
		background: rgba(249, 115, 22, 0.08);
		color: rgba(253, 186, 116, 0.8);
		border: 1px solid rgba(249, 115, 22, 0.1);
	}

	.pill-green {
		background: rgba(16, 185, 129, 0.08);
		color: rgba(110, 231, 183, 0.8);
		border: 1px solid rgba(16, 185, 129, 0.1);
	}

	.pill-grey {
		background: rgba(255, 255, 255, 0.03);
		color: rgba(255, 255, 255, 0.4);
		border: 1px solid rgba(255, 255, 255, 0.05);
	}

	.category-group {
		border-top: 1px solid rgba(255, 255, 255, 0.04);
	}

	.category-label {
		padding: 6px 16px;
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.35);
		background: transparent;
	}

	.table-header {
		display: grid;
		grid-template-columns: 80px 1.2fr 2fr 80px 60px;
		gap: 8px;
		padding: 5px 16px;
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.2);
		border-bottom: 1px solid rgba(255, 255, 255, 0.04);
	}

	.charge-row {
		display: grid;
		grid-template-columns: 80px 1.2fr 2fr 80px 60px;
		gap: 8px;
		padding: 6px 16px;
		font-size: 11px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
		align-items: center;
		transition: background 0.1s;
	}

	.charge-row:hover {
		background: rgba(255, 255, 255, 0.02);
	}

	.charge-row.clickable {
		cursor: pointer;
	}

	.charge-row.clickable:hover {
		background: rgba(var(--accent-rgb), 0.04);
	}

	.charge-row:last-child {
		border-bottom: none;
	}

	.col-label {
		color: rgba(255, 255, 255, 0.8);
		font-weight: 500;
		font-size: 11px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.col-desc {
		color: rgba(255, 255, 255, 0.3);
		font-size: 10px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.col-fine {
		color: rgba(255, 255, 255, 0.6);
		font-weight: 500;
		font-size: 11px;
		text-align: right;
	}

	.col-time {
		color: rgba(255, 255, 255, 0.35);
		font-size: 10px;
		text-align: right;
	}

	.col-actions {
		display: flex;
		align-items: center;
		gap: 4px;
		justify-content: flex-end;
	}

	.code-tag {
		font-size: 10px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.35);
		font-family: monospace;
	}

	.muted {
		color: rgba(255, 255, 255, 0.1);
	}

	.edit-hint-icon {
		font-size: 12px;
		color: rgba(255, 255, 255, 0.15);
	}

	.charge-row.clickable:hover .edit-hint-icon {
		color: rgba(var(--accent-text-rgb), 0.5);
	}

</style>