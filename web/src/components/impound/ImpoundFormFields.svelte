<script lang="ts">
	/**
	 * The impound form itself — reason, fee, lot, photo, notes.
	 *
	 * Shared on purpose: the MDT modal and the on-site form an officer gets at the
	 * roadside are the same fields, so they live in one component and can't drift
	 * apart.
	 */
	import type { ImpoundReason, ImpoundLot, ImpoundDuration } from "../../interfaces/IImpound";

	let {
		reasons = [],
		lots = [],
		durations = [],
		defaultDuration = "",
		storage = { perDay: 0, maxDays: 0 },
		maxFee = 50000,
		reason = $bindable(""),
		fee = $bindable(0),
		lot = $bindable(""),
		duration = $bindable(""),
		notes = $bindable(""),
		photo = $bindable(""),
	}: {
		reasons?: ImpoundReason[];
		lots?: ImpoundLot[];
		durations?: ImpoundDuration[];
		defaultDuration?: string;
		storage?: { perDay: number; maxDays: number };
		maxFee?: number;
		reason?: string;
		fee?: number;
		lot?: string;
		duration?: string;
		notes?: string;
		photo?: string;
	} = $props();

	const FEE_STEP = 50;
	const FEE_PRESETS = [100, 250, 500, 1000];

	function money(n: number): string {
		return "$" + (n ?? 0).toLocaleString();
	}

	// Picking a reason pre-fills both the fee and the hold it's configured for. Both
	// stay editable — a reason is a starting point, not a verdict.
	function onReasonChange(label: string) {
		reason = label;
		const r = reasons.find((x) => x.label === label);
		if (!r) return;
		fee = r.fee;
		const recommended = r.hold ?? defaultDuration;
		// Only snap to it if it's actually one of the configured durations, so a typo
		// in the config can't leave the picker with nothing selected.
		if (durations.some((d) => d.id === recommended)) duration = recommended;
	}

	function adjustFee(delta: number) {
		fee = Math.min(maxFee, Math.max(0, fee + delta));
	}

	let selectedDuration = $derived(durations.find((d) => d.id === duration));
	// What the officer is actually choosing, in plain words.
	let holdSummary = $derived.by(() => {
		const d = selectedDuration;
		if (!d) return "";
		if (d.days === undefined || d.days === null) {
			return "Held until an officer authorises release. Overriding this is logged.";
		}
		if (d.days <= 0) return "Can be released as soon as the fee is settled.";
		return `Cannot be released for ${d.days} day${d.days === 1 ? "" : "s"}, even if the fee is paid.`;
	});

	let recommendedHold = $derived.by(() => {
		const r = reasons.find((x) => x.label === reason);
		const id = r?.hold ?? defaultDuration;
		return durations.some((d) => d.id === id) ? id : "";
	});
	let recommendedHoldLabel = $derived(durations.find((d) => d.id === recommendedHold)?.label ?? "");
	let holdIsCustom = $derived(!!recommendedHold && duration !== recommendedHold);

	// What this actually costs the owner. The release fee is only half of it: storage
	// runs per day on top, and the form used to say "no fee will be charged" while
	// quietly setting the owner up for a storage bill.
	let maxStorage = $derived((storage?.perDay ?? 0) * (storage?.maxDays ?? 0));
	let worstCase = $derived(fee + maxStorage);

	let reasonDefaultFee = $derived(reasons.find((r) => r.label === reason)?.fee ?? 0);
	let feeIsCustom = $derived(fee !== reasonDefaultFee);

	// Photo preview / lightbox. `broken` keeps a bad link from leaving a torn image
	// icon sitting in the form.
	let lightboxOpen = $state(false);
	let photoBroken = $state(false);

	$effect(() => {
		photo; // re-check whenever the link changes
		photoBroken = false;
	});
</script>

<div class="form-group">
	<span class="field-label">Reason</span>
	<select class="form-input form-select" value={reason}
		onchange={(e) => onReasonChange((e.target as HTMLSelectElement).value)}>
		{#each reasons as r}
			<option value={r.label}>{r.label} — {r.fee === 0 ? "no fee" : money(r.fee)}</option>
		{/each}
	</select>
</div>

<div class="form-group">
	<span class="field-label">Holding Lot</span>
	<select class="form-input form-select" bind:value={lot}>
		{#each lots as l}
			<option value={l.id}>{l.label}</option>
		{/each}
	</select>
</div>

{#if durations.length > 0}
	<div class="form-group form-full">
		<span class="field-label">
			Hold Period
			{#if holdIsCustom}
				<button class="hold-reset" type="button" onclick={() => (duration = recommendedHold)}>
					reset to {recommendedHoldLabel.toLowerCase()}
				</button>
			{/if}
		</span>
		<div class="hold-picker">
			{#each durations as d (d.id)}
				<button
					class="hold-chip"
					class:on={duration === d.id}
					class:recommended={d.id === recommendedHold && duration !== d.id}
					class:indefinite={d.days === undefined || d.days === null}
					type="button"
					title={d.id === recommendedHold ? "Recommended for this reason" : ""}
					onclick={() => (duration = d.id)}
				>
					{d.label}
					{#if d.id === recommendedHold}<span class="hold-star">•</span>{/if}
				</button>
			{/each}
		</div>
		{#if holdSummary}
			<span class="hold-summary">{holdSummary}</span>
		{/if}
	</div>
{/if}

<div class="form-group form-full">
	<span class="field-label">
		Release Fee
		{#if feeIsCustom}
			<button class="fee-reset" type="button" onclick={() => (fee = reasonDefaultFee)}>
				reset to {reasonDefaultFee === 0 ? "no fee" : money(reasonDefaultFee)}
			</button>
		{/if}
	</span>

	<div class="fee-editor">
		<div class="fee-stepper">
			<button class="fee-step" type="button" aria-label="Lower the fee"
				disabled={fee <= 0} onclick={() => adjustFee(-FEE_STEP)}>
				<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M5 12h14"/></svg>
			</button>

			<div class="fee-value" class:fee-value-zero={fee === 0}>
				<span class="fee-currency">$</span>{fee.toLocaleString()}
			</div>

			<button class="fee-step" type="button" aria-label="Raise the fee"
				disabled={fee >= maxFee} onclick={() => adjustFee(FEE_STEP)}>
				<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>
			</button>
		</div>

		<div class="fee-quick">
			<button class="fee-chip" type="button" class:on={fee === 0} onclick={() => (fee = 0)}>Waive</button>
			{#each FEE_PRESETS as amt}
				<button class="fee-chip" type="button" onclick={() => adjustFee(amt)}>+{money(amt)}</button>
			{/each}
		</div>
	</div>

	<!-- Waiving the release fee doesn't make the impound free: storage still runs.
	     Spell out what the owner actually ends up paying. -->
	{#if maxStorage > 0}
		<div class="cost-breakdown">
			<div class="cost-row">
				<span>Release fee</span>
				<span class="cost-val">{fee === 0 ? "waived" : money(fee)}</span>
			</div>
			<div class="cost-row">
				<span>Storage · {money(storage.perDay)}/day, capped after {storage.maxDays} day{storage.maxDays === 1 ? "" : "s"}</span>
				<span class="cost-val">up to {money(maxStorage)}</span>
			</div>
			<div class="cost-row cost-total">
				<span>Owner pays at most</span>
				<span class="cost-val">{money(worstCase)}</span>
			</div>
		</div>
	{/if}
</div>

<div class="form-group form-full">
	<span class="field-label">Photo <span class="optional">(optional link)</span></span>
	<input class="form-input" bind:value={photo} placeholder="https://…  paste a Fivemanage link" />

	{#if photo.trim() && !photoBroken}
		<button class="photo-thumb" type="button" onclick={() => (lightboxOpen = true)} title="Click to enlarge">
			<img src={photo} alt="Vehicle condition" onerror={() => (photoBroken = true)} />
			<span class="photo-zoom">
				<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35M11 8v6M8 11h6"/></svg>
			</span>
		</button>
	{:else if photo.trim() && photoBroken}
		<span class="photo-error">That link could not be loaded</span>
	{/if}
</div>

{#if lightboxOpen}
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="lightbox-overlay" onclick={() => (lightboxOpen = false)}>
		<div class="lightbox-card" onclick={(e) => e.stopPropagation()}>
			<button class="lightbox-close" aria-label="Close" onclick={() => (lightboxOpen = false)}>
				<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
			</button>
			<img class="lightbox-img" src={photo} alt="Vehicle condition" />
		</div>
	</div>
{/if}

<div class="form-group form-full">
	<span class="field-label">Notes</span>
	<textarea class="form-input" rows="3" maxlength="500" bind:value={notes}
		placeholder="Condition, contents, anything the next officer should know…"></textarea>
</div>

<style>
	.form-group { display: flex; flex-direction: column; gap: 3px; }
	.form-full { grid-column: 1 / -1; }
	.field-label {
		display: flex;
		align-items: center;
		gap: 8px;
		color: rgba(255, 255, 255, 0.35);
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
	}
	.optional { color: rgba(255, 255, 255, 0.2); font-weight: 500; text-transform: none; letter-spacing: 0; }
	.form-input {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 5px 8px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 11px;
		font-family: inherit;
		transition: border-color 0.1s;
		width: 100%;
		box-sizing: border-box;
	}
	.form-input:focus { outline: none; border-color: rgba(255, 255, 255, 0.1); }
	.form-input::placeholder { color: rgba(255, 255, 255, 0.2); }
	.form-select { padding-right: 22px; font-size: 10px; cursor: pointer; }
	.form-input option { background: #1a1d23; }
	textarea.form-input { resize: vertical; line-height: 1.45; }

	/* The box hugs the picture: a fixed height with an auto width means the frame is
	   exactly as wide as the (uncropped) photo, instead of a full-width letterbox
	   with a stamp-sized image floating in it. */
	.photo-thumb {
		position: relative;
		align-self: flex-start;
		margin-top: 5px;
		padding: 0;
		width: auto;
		max-width: 100%;
		height: 160px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 4px;
		overflow: hidden;
		cursor: zoom-in;
		display: block;
		transition: border-color 0.1s;
	}
	.photo-thumb:hover { border-color: rgba(255, 255, 255, 0.2); }
	.photo-thumb img {
		width: auto;
		max-width: 100%;
		height: 100%;
		object-fit: contain;
		display: block;
	}
	.photo-zoom {
		position: absolute;
		right: 6px;
		bottom: 6px;
		display: flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		border-radius: 4px;
		background: rgba(0, 0, 0, 0.6);
		border: 1px solid rgba(255, 255, 255, 0.15);
		color: rgba(255, 255, 255, 0.85);
	}
	.photo-error {
		margin-top: 4px;
		font-size: 10px;
		color: rgba(248, 113, 113, 0.8);
	}

	.lightbox-overlay {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.85);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 2000;
	}
	.lightbox-card {
		position: relative;
		max-width: 90vw;
		max-height: 90vh;
		display: flex;
		flex-direction: column;
		padding-top: 40px;
	}
	.lightbox-close {
		position: absolute;
		top: 0;
		right: 0;
		background: rgba(255, 255, 255, 0.1);
		border: 1px solid rgba(255, 255, 255, 0.12);
		border-radius: 4px;
		color: rgba(255, 255, 255, 0.6);
		cursor: pointer;
		padding: 4px;
		display: flex;
		align-items: center;
		justify-content: center;
		transition: all 0.1s;
		z-index: 10;
	}
	.lightbox-close:hover { background: rgba(255, 255, 255, 0.2); color: #fff; }
	.lightbox-img {
		max-width: 90vw;
		max-height: calc(90vh - 40px);
		object-fit: contain;
		display: block;
		border-radius: 4px;
	}

	/* Hold period: a row of chips rather than a dropdown — the choice matters, so it
	   should be visible rather than hidden behind a click. */
	.hold-picker { display: flex; flex-wrap: wrap; gap: 4px; }
	.hold-chip {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.55);
		font-size: 10px;
		font-weight: 600;
		padding: 4px 9px;
		cursor: pointer;
		transition: all 0.1s;
	}
	.hold-chip:hover { color: rgba(255, 255, 255, 0.9); border-color: rgba(255, 255, 255, 0.15); }
	.hold-chip.on {
		background: rgba(255, 255, 255, 0.1);
		color: rgba(255, 255, 255, 0.95);
		border-color: rgba(255, 255, 255, 0.22);
	}
	/* An indefinite hold is the heavy option, so it looks like one once picked. */
	.hold-chip.indefinite.on {
		background: rgba(239, 68, 68, 0.12);
		color: rgba(252, 165, 165, 0.95);
		border-color: rgba(239, 68, 68, 0.3);
	}
	.hold-summary {
		margin-top: 3px;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.35);
	}
	/* The reason's recommendation stays marked even after you pick something else, so
	   you can always see what you're deviating from — and get back to it. */
	.hold-chip.recommended { border-color: rgba(255, 255, 255, 0.16); }
	.hold-star { margin-left: 3px; color: var(--accent-70); font-weight: 700; }
	.hold-reset {
		margin-left: auto;
		background: none;
		border: none;
		padding: 0;
		color: rgba(255, 255, 255, 0.3);
		font-size: 9px;
		font-weight: 600;
		text-transform: none;
		letter-spacing: 0;
		text-decoration: underline;
		cursor: pointer;
	}
	.hold-reset:hover { color: rgba(255, 255, 255, 0.8); }

	.cost-breakdown {
		display: flex;
		flex-direction: column;
		gap: 3px;
		margin-top: 7px;
		padding: 8px 10px;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 4px;
	}
	.cost-row {
		display: flex;
		justify-content: space-between;
		gap: 12px;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.35);
	}
	.cost-val { font-variant-numeric: tabular-nums; color: rgba(255, 255, 255, 0.55); }
	.cost-total {
		margin-top: 3px;
		padding-top: 5px;
		border-top: 1px solid rgba(255, 255, 255, 0.06);
		font-weight: 600;
		color: rgba(255, 255, 255, 0.6);
	}
	.cost-total .cost-val { color: rgba(252, 211, 77, 0.9); }

	/* Fee editor: steppers + quick amounts, echoing the license-points editor. */
	.fee-editor {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 14px;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 5px;
		padding: 9px 12px;
	}
	.fee-stepper { display: flex; align-items: center; gap: 10px; }
	.fee-step {
		width: 28px;
		height: 28px;
		display: grid;
		place-items: center;
		border-radius: 5px;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.07);
		color: rgba(255, 255, 255, 0.7);
		cursor: pointer;
		transition: all 0.1s;
	}
	.fee-step:hover:not(:disabled) {
		background: rgba(255, 255, 255, 0.08);
		color: rgba(255, 255, 255, 0.95);
		border-color: rgba(255, 255, 255, 0.12);
	}
	.fee-step:disabled { opacity: 0.3; cursor: not-allowed; }
	.fee-value {
		min-width: 96px;
		text-align: center;
		font-family: monospace;
		font-size: 22px;
		font-weight: 700;
		line-height: 1;
		letter-spacing: 0.5px;
		color: rgba(252, 211, 77, 0.95);
		font-variant-numeric: tabular-nums;
	}
	.fee-value-zero { color: rgba(255, 255, 255, 0.35); }
	.fee-currency { font-size: 14px; opacity: 0.6; margin-right: 1px; }
	.fee-quick { display: flex; flex-wrap: wrap; gap: 4px; justify-content: flex-end; }
	.fee-chip {
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.55);
		font-size: 9px;
		font-weight: 600;
		padding: 3px 7px;
		cursor: pointer;
		transition: all 0.1s;
		font-variant-numeric: tabular-nums;
	}
	.fee-chip:hover { color: rgba(255, 255, 255, 0.9); border-color: rgba(255, 255, 255, 0.15); }
	.fee-chip.on {
		background: rgba(255, 255, 255, 0.1);
		color: rgba(255, 255, 255, 0.9);
		border-color: rgba(255, 255, 255, 0.2);
	}
	.fee-reset {
		background: none;
		border: none;
		padding: 0;
		color: rgba(125, 211, 252, 0.7);
		font-size: 9px;
		font-weight: 600;
		text-transform: none;
		letter-spacing: 0;
		cursor: pointer;
	}
	.fee-reset:hover { color: rgba(186, 230, 253, 0.95); }
</style>