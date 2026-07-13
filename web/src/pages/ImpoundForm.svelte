<script lang="ts">
	/**
	 * On-site impound form.
	 *
	 * Opened by /impound at the roadside, outside the MDT — same shell and the same
	 * fields as the impound modal inside the MDT, so an officer sees one form, not
	 * two. Mounted outside VisibilityProvider (like ComplaintForm) so it works
	 * without the MDT being open.
	 */
	import { fetchNui } from "../utils/fetchNui";
	import ImpoundFormFields from "../components/impound/ImpoundFormFields.svelte";
	import type { ImpoundReason, ImpoundLot, ImpoundDuration } from "../interfaces/IImpound";

	let { show = false, vehicle = null, onClose = () => {} }: {
		show: boolean;
		vehicle: { plate: string; model?: string; netId: number; owner?: string; stolen?: boolean; bolo?: boolean; priorImpounds?: number } | null;
		onClose: () => void;
	} = $props();

	let reasons = $state<ImpoundReason[]>([]);
	let lots = $state<ImpoundLot[]>([]);
	let durations = $state<ImpoundDuration[]>([]);
	let storage = $state<{ perDay: number; maxDays: number }>({ perDay: 0, maxDays: 0 });
	let maxFee = $state(50000);
	let loaded = $state(false);
	let defaultDuration = $state("");

	let reason = $state("");
	let fee = $state(0);
	let lot = $state("");
	let duration = $state("");
	let notes = $state("");
	let photo = $state("");

	let busy = $state(false);
	let error = $state<string | null>(null);

	function money(n: number): string {
		return "$" + (n ?? 0).toLocaleString();
	}

	// Load the reason/lot config the first time the form is opened, and reset the
	// fields for each new vehicle.
	$effect(() => {
		if (!show || !vehicle) return;

		error = null;
		notes = "";
		photo = "";
		busy = false;

		if (loaded) {
			reason = reasons[0]?.label ?? "";
			fee = reasons[0]?.fee ?? 0;
			lot = lots[0]?.id ?? "";
			const rec = reasons[0]?.hold ?? defaultDuration;
			duration = durations.some((d) => d.id === rec) ? rec : defaultDuration;
			return;
		}

		(async () => {
			try {
				const res = await fetchNui<{
					reasons: ImpoundReason[]; lots: ImpoundLot[]; durations: ImpoundDuration[];
					maxFee: number; defaultDuration: string;
					storage: { perDay: number; maxDays: number };
				}>("getImpoundFormConfig", {}, {
					reasons: [], lots: [], durations: [], maxFee: 50000, defaultDuration: "immediate",
					storage: { perDay: 0, maxDays: 0 },
				});
				reasons = res?.reasons ?? [];
				lots = res?.lots ?? [];
				durations = res?.durations ?? [];
				if (typeof res?.maxFee === "number") maxFee = res.maxFee;
				defaultDuration = res?.defaultDuration || durations[0]?.id || "";
				storage = res?.storage ?? { perDay: 0, maxDays: 0 };
				reason = reasons[0]?.label ?? "";
				fee = reasons[0]?.fee ?? 0;
				lot = lots[0]?.id ?? "";
				const rec = reasons[0]?.hold ?? defaultDuration;
			duration = durations.some((d) => d.id === rec) ? rec : defaultDuration;
				loaded = true;
			} catch {
				error = "Could not load impound settings";
			}
		})();
	});

	async function close() {
		await fetchNui("closeImpoundForm", {}, { success: true });
		onClose();
	}

	async function submit() {
		if (!vehicle || busy || !reason) return;
		busy = true;
		error = null;
		try {
			const res = await fetchNui<{ success: boolean; message?: string }>(
				"submitOnSiteImpound",
				{
					netId: vehicle.netId,
					plate: vehicle.plate,
					reason,
					fee,
					lot,
					duration,
					notes: notes.trim() || undefined,
					photo: photo.trim() || undefined,
					onSite: true,
				},
				{ success: true, message: "Impounded" },
			);

			if (res?.success) {
				// Lua has already released NUI focus and is carrying on with the radio
				// call and the tow — just get the form out of the way. Calling the
				// close callback here would cancel the sequence it just started.
				onClose();
			} else {
				error = res?.message || "Failed to impound vehicle";
			}
		} catch {
			error = "Failed to impound vehicle";
		} finally {
			busy = false;
		}
	}
</script>

<svelte:window onkeydown={(e) => { if (show && e.key === "Escape") close(); }} />

{#if show && vehicle}
	<div class="modal-backdrop">
		<div class="modal" role="dialog" aria-modal="true" tabindex="-1">
			<div class="modal-header">
				<h3>Impound {vehicle.plate}</h3>
				<button class="close-btn" aria-label="Close" onclick={close}>
					<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
						<line x1="18" y1="6" x2="6" y2="18"/>
						<line x1="6" y1="6" x2="18" y2="18"/>
					</svg>
				</button>
			</div>

			<div class="modal-body form-body">
				<!-- The officer is standing at the car with no way to look it up. If it's
				     flagged, say so before they decide — impounding silently resolves a
				     BOLO, so they should at least know one was open. -->
				{#if vehicle.bolo || vehicle.stolen}
					<div class="alert-banner form-full" class:alert-stolen={vehicle.stolen}>
						<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
							<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>
							<line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
						</svg>
						<span>
							{#if vehicle.stolen && vehicle.bolo}
								Reported stolen and has an active BOLO — impounding will resolve the BOLO.
							{:else if vehicle.stolen}
								This vehicle is reported stolen.
							{:else}
								Active BOLO on this vehicle — impounding will resolve it.
							{/if}
						</span>
					</div>
				{/if}

				{#if vehicle.model}
					<div class="vehicle-strip form-full">
						<div class="vs-head">
							<span class="vs-model">{vehicle.model}</span>
							<span class="vs-plate">{vehicle.plate}</span>
						</div>
						<div class="vs-meta">
							{#if vehicle.owner}
								<span class="vs-owner">{vehicle.owner}</span>
							{/if}
							{#if (vehicle.priorImpounds ?? 0) > 0}
								<span class="vs-prior" class:vs-repeat={(vehicle.priorImpounds ?? 0) >= 3}>
									{vehicle.priorImpounds} prior impound{vehicle.priorImpounds === 1 ? "" : "s"}
								</span>
							{/if}
						</div>
					</div>
				{/if}

				<ImpoundFormFields
					{reasons} {lots} {durations} {defaultDuration} {storage} {maxFee}
					bind:reason bind:fee bind:lot bind:duration bind:notes bind:photo
				/>

				{#if error}
					<div class="form-error form-full">{error}</div>
				{/if}
			</div>

			<div class="modal-footer">
				<span class="modal-hint">
					{fee > 0
						? `${money(fee)} is charged to the owner on release`
						: "No fee will be charged"}
				</span>
				<div class="modal-footer-right">
					<button class="cancel-btn" disabled={busy} onclick={close}>Cancel</button>
					<button class="danger-btn" disabled={busy || !reason} onclick={submit}>
						{busy ? "Impounding…" : "Impound"}
					</button>
				</div>
			</div>
		</div>
	</div>
{/if}

<style>
	.modal-backdrop {
		position: fixed;
		inset: 0;
		/* No backdrop-filter: CEF paints it as solid black instead of blurring, which
		   is what turned everything around the form into a black box. A plain
		   translucent scrim keeps the vehicle visible behind the form. */
		background: rgba(0, 0, 0, 0.45);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 1200;
	}
	.modal {
		/* Not --card-dark-bg: that is nearly black, which works inside the MDT's own
		   chrome but reads as a void when it floats over the game world. */
		background: rgba(26, 28, 33, 0.97);
		border: 1px solid rgba(255, 255, 255, 0.1);
		border-radius: 6px;
		/* Roomier than the MDT's modals on purpose: this one floats over the game at
		   native resolution rather than sitting inside a full-screen tablet, so the
		   type that reads fine in the MDT is cramped out here. */
		width: min(720px, 94vw);
		max-height: 88vh;
		overflow: hidden;
		display: flex;
		flex-direction: column;
		box-shadow: 0 24px 70px rgba(0, 0, 0, 0.65);
	}
	.modal-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 13px 20px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.09);
	}
	.modal-header h3 { margin: 0; font-size: 14px; font-weight: 600; color: rgba(255, 255, 255, 0.85); }
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
		transition: all 0.1s;
	}
	.close-btn:hover { color: rgba(255, 255, 255, 0.7); border-color: rgba(255, 255, 255, 0.1); }
	.modal-body { padding: 18px 20px; overflow-y: auto; }
	.form-body { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
	.form-full { grid-column: 1 / -1; }

	.vehicle-strip {
		display: flex;
		flex-direction: column;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 4px;
		padding: 7px 10px;
	}
	.alert-banner {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 9px 12px;
		border-radius: 4px;
		background: rgba(251, 191, 36, 0.09);
		border: 1px solid rgba(251, 191, 36, 0.25);
		color: rgba(252, 211, 77, 0.95);
		font-size: 12px;
		font-weight: 500;
	}
	.alert-banner svg { flex-shrink: 0; }
	.alert-banner.alert-stolen {
		background: rgba(239, 68, 68, 0.09);
		border-color: rgba(239, 68, 68, 0.28);
		color: rgba(252, 165, 165, 0.95);
	}

	.vs-head { display: flex; align-items: baseline; gap: 10px; }
	.vs-meta { display: flex; align-items: center; gap: 8px; margin-top: 3px; }
	.vs-owner { font-size: 11px; color: rgba(255, 255, 255, 0.45); }
	.vs-prior {
		border-radius: 3px;
		padding: 1px 6px;
		background: rgba(255, 255, 255, 0.05);
		font-size: 9px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.4);
	}
	/* A car that keeps coming back is the case for a longer hold. */
	.vs-repeat { background: rgba(251, 191, 36, 0.12); color: rgba(252, 211, 77, 0.9); }

	.vs-model { font-size: 13px; font-weight: 600; color: rgba(255, 255, 255, 0.85); text-transform: uppercase; }
	.vs-plate {
		font-family: 'Courier New', monospace;
		font-size: 11px;
		font-weight: 700;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.45);
	}

	.form-error {
		background: rgba(239, 68, 68, 0.08);
		border: 1px solid rgba(239, 68, 68, 0.2);
		border-radius: 4px;
		padding: 7px 10px;
		font-size: 10px;
		color: rgba(248, 113, 113, 0.95);
	}

	.modal-footer {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 12px;
		padding: 13px 20px;
		border-top: 1px solid rgba(255, 255, 255, 0.09);
	}
	.modal-footer-right { display: flex; gap: 8px; }
	.modal-hint { font-size: 11px; color: rgba(255, 255, 255, 0.35); }

	/* The shared form fields are sized for the MDT. Scale them up here — and only
	   here — so the on-site form is comfortable without touching the MDT modal. */
	.modal :global(.field-label) { font-size: 10px; }
	.modal :global(.form-input) { font-size: 12.5px; padding: 7px 10px; }
	.modal :global(.form-select) { font-size: 12px; }
	.modal :global(.fee-editor) { padding: 12px 15px; }
	.modal :global(.fee-value) { font-size: 26px; min-width: 118px; }
	.modal :global(.fee-currency) { font-size: 17px; }
	.modal :global(.fee-step) { width: 32px; height: 32px; }
	.modal :global(.fee-chip) { font-size: 10px; padding: 4px 9px; }
	.modal :global(.hold-chip) { font-size: 11px; padding: 5px 11px; }
	.modal :global(.hold-summary) { font-size: 11px; }
	.modal :global(.photo-thumb) { height: 190px; }
	.cancel-btn {
		background: transparent;
		color: rgba(255, 255, 255, 0.4);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 6px 14px;
		font-size: 11px;
		font-weight: 500;
		cursor: pointer;
		transition: all 0.1s;
	}
	.cancel-btn:hover:not(:disabled) { color: rgba(255, 255, 255, 0.7); border-color: rgba(255, 255, 255, 0.1); }
	.danger-btn {
		background: rgba(239, 68, 68, 0.06);
		color: rgba(248, 113, 113, 0.75);
		border: 1px solid rgba(239, 68, 68, 0.12);
		border-radius: 3px;
		padding: 6px 16px;
		font-size: 11px;
		font-weight: 600;
		cursor: pointer;
		transition: all 0.1s;
	}
	.danger-btn:hover:not(:disabled) { background: rgba(239, 68, 68, 0.13); color: rgba(252, 165, 165, 0.95); }
	.cancel-btn:disabled, .danger-btn:disabled { opacity: 0.4; cursor: not-allowed; }
</style>