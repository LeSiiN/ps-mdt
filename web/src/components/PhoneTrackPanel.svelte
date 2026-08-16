<script lang="ts">
	/**
	 * Phone tracking, in two modes, deliberately not its own page.
	 *
	 *   mode="request"  officers: look a number up, submit a justification, and
	 *                   execute a granted warrant. Lives on the Dispatch map,
	 *                   because that is where the result appears.
	 *   mode="review"   judges: approve or deny. Lives under Warrant Review,
	 *                   next to the other thing they sign off on.
	 *
	 * Approval and execution are separate on purpose: a granted warrant is not
	 * switched on, it is handed to the officer with a shelf life. The countdown
	 * on the execute button is that shelf life running out.
	 */
	import { onMount, onDestroy } from "svelte";
	import { fetchNui } from "@/utils/fetchNui";
	import { NUI_EVENTS } from "@/constants/nuiEvents";

	interface Track {
		id: number;
		number: string;
		citizen_name?: string;
		citizenid?: string;
		officer_name?: string;
		reason?: string;
		status: string;
		review_reason?: string;
		reviewer_name?: string;
		approval_seconds_left?: number | null;
		created_at?: string;
	}

	interface Props {
		mode: "request" | "review";
	}

	let { mode }: Props = $props();

	let loading = $state(false);
	let error = $state("");
	let mine = $state<Track[]>([]);
	let pending = $state<Track[]>([]);
	let recent = $state<Track[]>([]);

	// Request form
	let number = $state("");
	let reason = $state("");
	let subscriber = $state<{ citizenid: string; name?: string } | null>(null);
	let busy = $state(false);
	let notice = $state("");
	let open = $state(false);

	/** Requests are paged rather than dumped: the list is the tail end of the
	 *  dialog and an officer with thirty of them would push the footer off. */
	const PAGE = 5;
	let shown = $state(PAGE);
	let visibleMine = $derived(mine.slice(0, shown));

	let liveCount = $derived(mine.filter((t) => t.status === "active").length);
	let readyCount = $derived(
		mine.filter((t) => t.status === "approved" && secondsLeft(t) > 0).length,
	);

	// Review form — keyed by track id so two open reasons never collide
	let reviewReason = $state<Record<number, string>>({});

	/** Local countdown so the shelf life visibly runs out without re-polling. */
	let tick = $state(0);
	let timer: ReturnType<typeof setInterval> | undefined;

	async function load() {
		loading = true;
		error = "";
		try {
			if (mode === "review") {
				const res = await fetchNui<any>(NUI_EVENTS.PHONE_TRACK.GET_REQUESTS, {});
				if (res?.success) {
					pending = res.pending ?? [];
					recent = res.recent ?? [];
				} else error = res?.message ?? "Could not load requests";
			} else {
				const res = await fetchNui<any>(NUI_EVENTS.PHONE_TRACK.GET_MINE, {});
				if (res?.success) mine = res.mine ?? [];
				else error = res?.message ?? "Could not load tracks";
			}
		} catch {
			error = "Could not reach the server";
		}
		loading = false;
		tick = 0;
	}

	async function lookup() {
		if (!number.trim()) return;
		busy = true;
		error = "";
		subscriber = null;
		try {
			const res = await fetchNui<any>(NUI_EVENTS.PHONE_TRACK.LOOKUP_NUMBER, { number });
			if (res?.success) subscriber = { citizenid: res.citizenid, name: res.name };
			else error = res?.message ?? "No subscriber found";
		} catch {
			error = "Lookup failed";
		}
		busy = false;
	}

	async function submit() {
		if (!number.trim() || !reason.trim()) return;
		busy = true;
		error = "";
		try {
			const res = await fetchNui<any>(NUI_EVENTS.PHONE_TRACK.REQUEST, { number, reason });
			if (res?.success) {
				number = "";
				reason = "";
				subscriber = null;
				await load();
			} else error = res?.message ?? "Request failed";
		} catch {
			error = "Request failed";
		}
		busy = false;
	}

	type NuiEvent = Parameters<typeof fetchNui>[0];

	async function act(event: NuiEvent, payload: Record<string, unknown>) {
		busy = true;
		error = "";
		notice = "";
		try {
			const res = await fetchNui<any>(event, payload);
			if (!res?.success) {
				// An abort means the handset did not answer. That is an outcome
				// in the world, not a fault the officer made, so it reads as a
				// dispatch note rather than a red failure.
				if (res?.aborted) notice = res?.message ?? "No handset responding.";
				else error = res?.message ?? "Action failed";
			}
			await load();
		} catch {
			error = "Action failed";
		}
		busy = false;
	}

	/** Seconds left on a granted warrant, counted down locally since the load. */
	function secondsLeft(track: Track): number {
		const base = track.approval_seconds_left ?? 0;
		return Math.max(0, base - tick);
	}

	function clock(seconds: number): string {
		const m = Math.floor(seconds / 60);
		const s = seconds % 60;
		return `${m}:${String(s).padStart(2, "0")}`;
	}

	function openModal() {
		open = true;
		shown = PAGE;
		load();
	}

	onMount(() => {
		load();
		timer = setInterval(() => (tick += 1), 1000);
	});

	onDestroy(() => {
		if (timer !== undefined) clearInterval(timer);
	});
</script>

<!-- Both modes are a toolbar button that opens a dialog, following Add Weapon.
     Neither the warrant list nor the review queue has room for a panel parked
     above it, and a card in its own visual language looked bolted on. The count
     badge is the exception: a running track, a warrant about to lapse, or a
     request waiting on a judge has to be visible without opening anything. -->
<button class="pt-trigger" onclick={openModal}>
	<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
		<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>
	</svg>
	Phone Tracking
	{#if mode === "review"}
		{#if pending.length > 0}
			<span class="pt-badge-ready">{pending.length}</span>
		{/if}
	{:else if liveCount > 0}
		<span class="pt-badge-live"><span class="pt-live-dot"></span>{liveCount}</span>
	{:else if readyCount > 0}
		<span class="pt-badge-ready">{readyCount}</span>
	{/if}
</button>

{#if open}
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="modal-backdrop" onclick={(e) => { if (e.target === e.currentTarget) open = false; }}>
		<div class="modal" role="dialog" aria-modal="true" tabindex="-1">
			<div class="modal-header">
				<h3>Phone Tracking</h3>
				<button class="close-btn" aria-label="Close" onclick={() => (open = false)}>
					<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
						<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
					</svg>
				</button>
			</div>

			<div class="modal-body">
				{#if error}<p class="pt-error">{error}</p>{/if}
				{#if notice}
					<p class="pt-notice">
						<span class="pt-notice-tag">Dispatch</span>
						{notice}
					</p>
				{/if}

				{#if mode === "review"}
					<span class="field-label">Awaiting review</span>
					<div class="pt-list">
						{#each pending as track (track.id)}
							<div class="pt-item pt-item-review">
								<div class="pt-review-head">
									<span class="pt-num">{track.number}</span>
									<span class="pt-name">{track.citizen_name || track.citizenid || "Unknown subscriber"}</span>
									<span class="pt-officer">{track.officer_name}</span>
								</div>
								<p class="pt-reason">{track.reason}</p>
								<div class="pt-row">
									<input class="form-input" type="text" placeholder="Reason for the decision" bind:value={reviewReason[track.id]} />
									<button class="pt-btn pt-btn-primary" disabled={busy}
										onclick={() => act(NUI_EVENTS.PHONE_TRACK.REVIEW, { id: track.id, decision: "approved", reason: reviewReason[track.id] ?? "" })}>Approve</button>
									<button class="pt-btn pt-btn-deny" disabled={busy}
										onclick={() => act(NUI_EVENTS.PHONE_TRACK.REVIEW, { id: track.id, decision: "denied", reason: reviewReason[track.id] ?? "" })}>Deny</button>
								</div>
							</div>
						{:else}
							<p class="pt-empty">No requests awaiting review.</p>
						{/each}
					</div>

					{#if recent.length > 0}
						<span class="field-label">Recent decisions</span>
						<div class="pt-list">
							{#each recent.slice(0, 8) as track (track.id)}
								<div class="pt-item pt-item-quiet">
									<div class="pt-item-main">
										<span class="pt-num">{track.number}</span>
										<span class="pt-name">{track.citizen_name || track.citizenid}</span>
									</div>
									<span class="pt-status pt-status-{track.status}">{track.status}</span>
								</div>
							{/each}
						</div>
					{/if}
				{:else}
				<div class="form-group">
					<span class="field-label">Phone Number</span>
					<div class="pt-row">
						<input class="form-input" type="text" placeholder="e.g. 555-0123" bind:value={number} />
						<button class="pt-btn" onclick={lookup} disabled={busy || !number.trim()}>Look up</button>
					</div>
				</div>

				{#if subscriber}
					<div class="pt-subscriber">
						<span class="pt-sub-label">Registered to</span>
						<span class="pt-sub-name">{subscriber.name || subscriber.citizenid}</span>
					</div>
				{/if}

				<div class="form-group">
					<span class="field-label">Justification</span>
					<textarea class="form-input" rows="3" placeholder="The reviewing judge sees this and nothing else." bind:value={reason}></textarea>
				</div>

				{#if mine.length > 0}
					<span class="field-label pt-recent-label">Your requests</span>
					<div class="pt-list">
						{#each visibleMine as track (track.id)}
							<div class="pt-item">
								<div class="pt-item-main">
									<span class="pt-num">{track.number}</span>
									<span class="pt-name">{track.citizen_name || track.citizenid || "Unknown"}</span>
								</div>
								<div class="pt-item-side">
									<span class="pt-status pt-status-{track.status}">{track.status}</span>
									{#if track.status === "approved"}
										{#if secondsLeft(track) > 0}
											<button class="pt-btn pt-btn-primary" disabled={busy}
												onclick={() => act(NUI_EVENTS.PHONE_TRACK.START, { id: track.id })}>
												Start · {clock(secondsLeft(track))}
											</button>
										{:else}
											<span class="pt-lapsed">Expired</span>
										{/if}
									{:else if track.status === "active"}
										<button class="pt-btn" disabled={busy} onclick={() => act(NUI_EVENTS.PHONE_TRACK.CANCEL, { id: track.id })}>Stop</button>
									{:else if track.status === "pending"}
										<button class="pt-btn" disabled={busy} onclick={() => act(NUI_EVENTS.PHONE_TRACK.CANCEL, { id: track.id })}>Withdraw</button>
									{/if}
								</div>
							</div>
						{/each}
					</div>
					{#if mine.length > shown}
						<button class="pt-more" onclick={() => (shown += PAGE)}>
							Load more
							<span class="pt-more-count">{shown} of {mine.length}</span>
						</button>
					{/if}
				{/if}
				{/if}
			</div>

			<div class="modal-footer">
				<button class="cancel-btn" onclick={() => (open = false)}>Close</button>
				{#if mode !== "review"}
					<button class="primary-btn" onclick={submit} disabled={busy || !number.trim() || !reason.trim()}>
						Submit for approval
					</button>
				{/if}
			</div>
		</div>
	</div>
{/if}

<style>
	.pt {
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 16px 18px;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 10px;
	}

	/* Trigger button — same weight as "New Warrant" beside it. */
	/* Matched to .btn-secondary / .btn-primary on the pages this sits in:
	   10px text, 4px 10px padding, 3px radius. Anything larger makes the
	   button shout next to its neighbours, which is what it was doing. */
	.pt-trigger {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 4px 10px;
		border-radius: 3px;
		font-family: inherit;
		font-size: 10px;
		font-weight: 500;
		line-height: 1.4;
		cursor: pointer;
		flex-shrink: 0;
		color: rgba(245, 158, 11, 0.75);
		background: rgba(245, 158, 11, 0.06);
		border: 1px solid rgba(245, 158, 11, 0.14);
		transition: all 0.1s;
	}

	.pt-trigger:hover {
		background: rgba(245, 158, 11, 0.12);
		border-color: rgba(245, 158, 11, 0.3);
		color: rgba(245, 158, 11, 0.95);
	}

	.pt-trigger svg { width: 11px; height: 11px; }

	/* The one thing that must be visible without opening anything: a track
	   running, or a warrant waiting to be executed before it lapses. */
	.pt-badge-live,
	.pt-badge-ready {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		font-size: 9px;
		font-weight: 700;
		padding: 0 5px;
		border-radius: 999px;
		margin-left: 1px;
	}

	.pt-badge-live { color: rgb(134, 239, 172); background: rgba(34, 197, 94, 0.18); }
	.pt-badge-ready { color: rgb(252, 211, 77); background: rgba(245, 158, 11, 0.2); }

	.pt-live-dot {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: currentColor;
		animation: pt-blink 1.6s ease-in-out infinite;
	}

	@keyframes pt-blink {
		0%, 100% { opacity: 1; }
		50% { opacity: 0.25; }
	}

	:global(.mdt-reduced-motion) .pt-live-dot { animation: none; }

	/* Modal shell, matching the Add Weapon dialog. No backdrop-filter: CEF
	   paints it as a solid black block instead of blurring. */
	.modal-backdrop {
		position: fixed;
		inset: 0;
		padding: 16px;
		background: rgba(0, 0, 0, 0.78);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 999;
	}

	.modal {
		background: var(--card-dark-bg);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 6px;
		width: min(520px, 92%);
		/*
		 * Percentages, not vh. The content area carries a CSS transform for the
		 * UI-scale preference, and a transform makes that element the
		 * containing block for position:fixed children — so the backdrop fills
		 * the MDT rather than the screen, and 85vh resolved against the
		 * viewport was overflowing it at any zoom above 100%. A percentage
		 * resolves against the same box the backdrop covers, and the px cap
		 * keeps it sane on very tall windows.
		 */
		max-height: min(88%, 640px);
		overflow: hidden;
		display: flex;
		flex-direction: column;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);
	}

	.modal-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 10px 16px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}

	.modal-header h3 { margin: 0; font-size: 12px; font-weight: 600; color: rgba(255, 255, 255, 0.85); }

	.close-btn {
		display: flex;
		align-items: center;
		justify-content: center;
		background: transparent;
		color: rgba(255, 255, 255, 0.3);
		border: 1px solid rgba(255, 255, 255, 0.06);
		padding: 4px;
		border-radius: 3px;
		cursor: pointer;
	}

	.close-btn:hover { color: rgba(255, 255, 255, 0.7); border-color: rgba(255, 255, 255, 0.1); }

	.modal-body {
		padding: 14px 16px;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 12px;
		/* Without this the flex item refuses to shrink and scrolls the whole
		   dialog off the bottom instead of scrolling its own content. */
		min-height: 0;
		flex: 1 1 auto;
	}

	.modal-header, .modal-footer { flex: none; }

	.pt-notice {
		display: flex;
		align-items: baseline;
		gap: 7px;
		margin: 0;
		font-size: 11px;
		line-height: 1.5;
		color: rgba(255, 255, 255, 0.6);
		background: rgba(245, 158, 11, 0.07);
		border-left: 2px solid rgba(245, 158, 11, 0.5);
		padding: 8px 10px;
		border-radius: 4px;
	}

	.pt-notice-tag {
		flex: none;
		font-size: 9px;
		font-weight: 700;
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: rgba(245, 158, 11, 0.8);
	}

	.pt-more {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		width: 100%;
		padding: 7px;
		border-radius: 4px;
		font-family: inherit;
		font-size: 11px;
		font-weight: 500;
		cursor: pointer;
		color: rgba(255, 255, 255, 0.5);
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.06);
	}

	.pt-more:hover { color: rgba(255, 255, 255, 0.85); background: rgba(255, 255, 255, 0.05); }
	.pt-more-count { font-size: 10px; color: rgba(255, 255, 255, 0.28); }

	.modal-footer {
		display: flex;
		justify-content: flex-end;
		align-items: center;
		gap: 6px;
		padding: 10px 16px;
		border-top: 1px solid rgba(255, 255, 255, 0.06);
	}

	.form-group { display: flex; flex-direction: column; gap: 5px; }

	.field-label {
		color: rgba(255, 255, 255, 0.35);
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
	}

	.form-input {
		width: 100%;
		padding: 8px 10px;
		font-family: inherit;
		font-size: 12px;
		color: rgba(255, 255, 255, 0.85);
		background: rgba(0, 0, 0, 0.25);
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 4px;
		resize: none;
	}

	.form-input:focus { outline: none; border-color: rgba(var(--accent-rgb), 0.45); }

	.cancel-btn, .primary-btn {
		padding: 7px 14px;
		border-radius: 4px;
		font-family: inherit;
		font-size: 12px;
		font-weight: 500;
		cursor: pointer;
	}

	.cancel-btn {
		color: rgba(255, 255, 255, 0.5);
		background: transparent;
		border: 1px solid rgba(255, 255, 255, 0.08);
	}

	.primary-btn {
		color: rgba(var(--accent-text-rgb), 0.95);
		background: rgba(var(--accent-rgb), 0.18);
		border: 1px solid rgba(var(--accent-rgb), 0.4);
	}

	.primary-btn:hover:not(:disabled) {
		background: rgba(var(--accent-rgb), 0.28);
		border-color: rgba(var(--accent-rgb), 0.55);
	}

	.cancel-btn:hover { color: rgba(255, 255, 255, 0.8); }

	.primary-btn:disabled { opacity: 0.4; cursor: not-allowed; }

	.pt-error {
		margin: 0;
		font-size: 12px;
		color: rgb(248, 113, 113);
		background: rgba(239, 68, 68, 0.08);
		border-left: 2px solid rgba(239, 68, 68, 0.5);
		padding: 7px 10px;
		border-radius: 4px;
	}

	.pt-row { display: flex; align-items: center; gap: 8px; }

	.pt-input {
		flex: 1;
		min-width: 0;
		padding: 8px 10px;
		font-family: inherit;
		font-size: 12px;
		color: rgba(255, 255, 255, 0.85);
		background: rgba(0, 0, 0, 0.25);
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 6px;
	}

	.pt-input:focus { outline: none; border-color: rgba(var(--accent-rgb), 0.45); }
	.pt-textarea { resize: none; line-height: 1.45; }

	.pt-subscriber {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 7px 10px;
		background: rgba(245, 158, 11, 0.06);
		border-left: 2px solid rgba(245, 158, 11, 0.5);
		border-radius: 4px;
	}

	.pt-sub-label {
		font-size: 10px;
		font-weight: 600;
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: rgba(255, 255, 255, 0.35);
	}

	.pt-sub-name { font-size: 13px; font-weight: 500; color: rgba(255, 255, 255, 0.9); }
	.pt-recent-label { margin-top: 6px; }

	.pt-list { display: flex; flex-direction: column; gap: 6px; }

	.pt-item {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 9px 11px;
		background: rgba(255, 255, 255, 0.02);
		border-radius: 6px;
	}

	.pt-item-review { flex-direction: column; align-items: stretch; gap: 8px; }
	.pt-item-quiet { opacity: 0.6; }

	.pt-item-main, .pt-review-head { display: flex; align-items: baseline; gap: 10px; min-width: 0; }
	.pt-item-side { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }

	.pt-num { font-family: monospace; font-size: 13px; color: rgba(255, 255, 255, 0.9); }
	.pt-name { font-size: 12px; color: rgba(255, 255, 255, 0.6); }
	.pt-officer { font-size: 11px; color: rgba(255, 255, 255, 0.35); margin-left: auto; }

	.pt-reason {
		margin: 0;
		font-size: 12px;
		line-height: 1.5;
		color: rgba(255, 255, 255, 0.55);
	}

	.pt-status {
		font-size: 10px;
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		padding: 3px 7px;
		border-radius: 4px;
		color: rgba(255, 255, 255, 0.5);
		background: rgba(255, 255, 255, 0.05);
	}

	.pt-status-approved { color: rgb(252, 211, 77); background: rgba(245, 158, 11, 0.12); }
	.pt-status-active { color: rgb(134, 239, 172); background: rgba(34, 197, 94, 0.12); }
	.pt-status-denied, .pt-status-lapsed { color: rgb(248, 113, 113); background: rgba(239, 68, 68, 0.1); }

	.pt-lapsed { font-size: 11px; color: rgba(248, 113, 113, 0.8); }

	.pt-empty { margin: 0; font-size: 12px; color: rgba(255, 255, 255, 0.3); padding: 6px 2px; }

	.pt-btn {
		padding: 7px 13px;
		border-radius: 6px;
		font-family: inherit;
		font-size: 12px;
		font-weight: 500;
		cursor: pointer;
		flex-shrink: 0;
		color: rgba(255, 255, 255, 0.55);
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.08);
		transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
	}

	.pt-btn:hover:not(:disabled) {
		background: rgba(255, 255, 255, 0.07);
		color: rgba(255, 255, 255, 0.9);
	}

	.pt-btn:disabled { opacity: 0.4; cursor: not-allowed; }

	.pt-btn-primary {
		background: rgba(var(--accent-rgb), 0.06);
		color: rgba(var(--accent-text-rgb), 0.7);
		border-color: rgba(var(--accent-rgb), 0.1);
	}

	.pt-btn-deny { color: rgba(248, 113, 113, 0.85); border-color: rgba(239, 68, 68, 0.3); }
</style>