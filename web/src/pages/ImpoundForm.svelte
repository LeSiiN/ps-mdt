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
	import type { ImpoundReason, ImpoundLot } from "../interfaces/IImpound";

	let { show = false, vehicle = null, onClose = () => {} }: {
		show: boolean;
		vehicle: { plate: string; model?: string; netId: number } | null;
		onClose: () => void;
	} = $props();

	let reasons = $state<ImpoundReason[]>([]);
	let lots = $state<ImpoundLot[]>([]);
	let maxFee = $state(50000);
	let loaded = $state(false);

	let reason = $state("");
	let fee = $state(0);
	let lot = $state("");
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
			return;
		}

		(async () => {
			try {
				const res = await fetchNui<{
					reasons: ImpoundReason[]; lots: ImpoundLot[]; maxFee: number;
				}>("getImpoundFormConfig", {}, { reasons: [], lots: [], maxFee: 50000 });
				reasons = res?.reasons ?? [];
				lots = res?.lots ?? [];
				if (typeof res?.maxFee === "number") maxFee = res.maxFee;
				reason = reasons[0]?.label ?? "";
				fee = reasons[0]?.fee ?? 0;
				lot = lots[0]?.id ?? "";
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
				{#if vehicle.model}
					<div class="vehicle-strip form-full">
						<span class="vs-model">{vehicle.model}</span>
						<span class="vs-plate">{vehicle.plate}</span>
					</div>
				{/if}

				<ImpoundFormFields
					{reasons} {lots} {maxFee}
					bind:reason bind:fee bind:lot bind:notes bind:photo
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
		width: min(540px, 92vw);
		max-height: 85vh;
		overflow: hidden;
		display: flex;
		flex-direction: column;
		box-shadow: 0 24px 70px rgba(0, 0, 0, 0.65);
	}
	.modal-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 10px 16px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.09);
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
		transition: all 0.1s;
	}
	.close-btn:hover { color: rgba(255, 255, 255, 0.7); border-color: rgba(255, 255, 255, 0.1); }
	.modal-body { padding: 14px 16px; overflow-y: auto; }
	.form-body { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
	.form-full { grid-column: 1 / -1; }

	.vehicle-strip {
		display: flex;
		align-items: baseline;
		gap: 10px;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 4px;
		padding: 7px 10px;
	}
	.vs-model { font-size: 12px; font-weight: 600; color: rgba(255, 255, 255, 0.85); text-transform: uppercase; }
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
		gap: 10px;
		padding: 10px 16px;
		border-top: 1px solid rgba(255, 255, 255, 0.09);
	}
	.modal-footer-right { display: flex; gap: 6px; }
	.modal-hint { font-size: 10px; color: rgba(255, 255, 255, 0.35); }
	.cancel-btn {
		background: transparent;
		color: rgba(255, 255, 255, 0.4);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 4px 10px;
		font-size: 10px;
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
		padding: 4px 12px;
		font-size: 10px;
		font-weight: 600;
		cursor: pointer;
		transition: all 0.1s;
	}
	.danger-btn:hover:not(:disabled) { background: rgba(239, 68, 68, 0.13); color: rgba(252, 165, 165, 0.95); }
	.cancel-btn:disabled, .danger-btn:disabled { opacity: 0.4; cursor: not-allowed; }
</style>