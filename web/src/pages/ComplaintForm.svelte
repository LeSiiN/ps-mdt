<script lang="ts">
	/**
	 * Internal Affairs complaint form.
	 *
	 * Standalone: opened with /complaint or the openComplaint export, outside the
	 * MDT, so civilians can file a complaint without any police access. Styled to
	 * match the modals inside the MDT so it doesn't look like a different product.
	 */
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";

	let { show = false, onClose = () => {} }: { show: boolean; onClose: () => void } = $props();

	interface EvidenceItem {
		url: string;
		broken: boolean;
	}

	let officerName = $state("");
	let officerBadge = $state("");
	let category = $state("other");
	let description = $state("");
	let incidentDate = $state("");
	let incidentLocation = $state("");
	let witnesses = $state("");
	let evidenceUrl = $state("");
	let evidenceList = $state<EvidenceItem[]>([]);

	let submitting = $state(false);
	let submitted = $state(false);
	let complaintNumber = $state("");
	let errorMessage = $state("");
	let lightboxUrl = $state<string | null>(null);

	const categories = [
		{ value: "misconduct", label: "Misconduct" },
		{ value: "excessive_force", label: "Excessive Force" },
		{ value: "corruption", label: "Corruption" },
		{ value: "negligence", label: "Negligence" },
		{ value: "discrimination", label: "Discrimination" },
		{ value: "other", label: "Other" },
	];

	const DESC_MAX = 2000;

	let isFormValid = $derived(
		officerName.trim() !== "" && category !== "" && description.trim().length >= 20,
	);

	// An incident can't have happened tomorrow.
	const today = new Date().toISOString().split("T")[0];

	function addEvidence() {
		const url = evidenceUrl.trim();
		if (url === "") return;
		if (evidenceList.some((e) => e.url === url)) {
			evidenceUrl = "";
			return;
		}
		evidenceList = [...evidenceList, { url, broken: false }];
		evidenceUrl = "";
	}

	function removeEvidence(index: number) {
		evidenceList = evidenceList.filter((_, i) => i !== index);
	}

	function markBroken(index: number) {
		evidenceList = evidenceList.map((e, i) => (i === index ? { ...e, broken: true } : e));
	}

	function resetForm() {
		officerName = "";
		officerBadge = "";
		category = "other";
		description = "";
		incidentDate = "";
		incidentLocation = "";
		witnesses = "";
		evidenceUrl = "";
		evidenceList = [];
		submitting = false;
		submitted = false;
		complaintNumber = "";
		errorMessage = "";
		lightboxUrl = null;
	}

	async function handleCancel() {
		resetForm();
		await fetchNui(NUI_EVENTS.IA.CLOSE_COMPLAINT, {}, { success: true });
		onClose();
	}

	async function handleSubmit() {
		if (!isFormValid || submitting) return;

		submitting = true;
		errorMessage = "";

		try {
			const res = await fetchNui<{ success?: boolean; complaintNumber?: string; error?: string }>(
				NUI_EVENTS.IA.SUBMIT_COMPLAINT,
				{
					officerName: officerName.trim(),
					officerBadge: officerBadge.trim(),
					category,
					description: description.trim(),
					incidentDate,
					incidentLocation: incidentLocation.trim(),
					witnesses: witnesses.trim(),
					evidence: evidenceList.map((e) => ({ url: e.url, label: e.url })),
				},
				{ success: true, complaintNumber: "IA-0000" },
			);

			if (res?.success === false) {
				errorMessage = res.error || "Failed to submit complaint. Please try again.";
				return;
			}

			complaintNumber = res?.complaintNumber || "IA-UNKNOWN";
			submitted = true;
		} catch {
			errorMessage = "Failed to submit complaint. Please try again.";
		} finally {
			submitting = false;
		}
	}
</script>

<svelte:window onkeydown={(e) => {
	if (!show) return;
	if (e.key === "Escape") {
		if (lightboxUrl) { lightboxUrl = null; return; }
		handleCancel();
	}
}} />

{#if show}
	<div class="modal-backdrop">
		<div class="modal" role="dialog" aria-modal="true" tabindex="-1">
			{#if submitted}
				<div class="modal-header">
					<h3>Complaint Filed</h3>
					<button class="close-btn" aria-label="Close" onclick={handleCancel}>
						<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
							<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
						</svg>
					</button>
				</div>

				<div class="modal-body success-body">
					<div class="success-mark">
						<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
							<polyline points="20 6 9 17 4 12"/>
						</svg>
					</div>
					<p class="success-lead">Your complaint has been filed with Internal Affairs.</p>

					<div class="success-number">
						<span class="field-label">Reference</span>
						<span class="ref-value">{complaintNumber}</span>
					</div>

					<p class="success-note">Write this number down — you'll need it to follow up. You'll be contacted if further information is needed.</p>
				</div>

				<div class="modal-footer">
					<span class="modal-hint">Filed under your own name</span>
					<div class="modal-footer-right">
						<button class="primary-btn" onclick={handleCancel}>Done</button>
					</div>
				</div>
			{:else}
				<div class="modal-header">
					<h3>Internal Affairs Complaint</h3>
					<button class="close-btn" aria-label="Close" onclick={handleCancel}>
						<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
							<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
						</svg>
					</button>
				</div>

				<div class="modal-body form-body">
					{#if errorMessage}
						<div class="form-error form-full">{errorMessage}</div>
					{/if}

					<div class="form-group">
						<span class="field-label">Officer <span class="req">*</span></span>
						<input class="form-input" bind:value={officerName} placeholder="Officer's name" />
					</div>

					<div class="form-group">
						<span class="field-label">Badge Number</span>
						<input class="form-input" bind:value={officerBadge} placeholder="If you know it" />
					</div>

					<div class="form-group">
						<span class="field-label">Category <span class="req">*</span></span>
						<select class="form-input form-select" bind:value={category}>
							{#each categories as cat}
								<option value={cat.value}>{cat.label}</option>
							{/each}
						</select>
					</div>

					<div class="form-group">
						<span class="field-label">Incident Date</span>
						<input class="form-input" type="date" max={today} bind:value={incidentDate} />
					</div>

					<div class="form-group form-full">
						<span class="field-label">Location</span>
						<input class="form-input" bind:value={incidentLocation} placeholder="Where did this happen?" />
					</div>

					<div class="form-group form-full">
						<span class="field-label">
							What happened? <span class="req">*</span>
							<span class="counter" class:counter-low={description.trim().length > 0 && description.trim().length < 20}>
								{description.length}/{DESC_MAX}
							</span>
						</span>
						<textarea class="form-input" rows="6" maxlength={DESC_MAX} bind:value={description}
							placeholder="Describe the incident in as much detail as you can — what happened, when, and who was involved."></textarea>
						{#if description.trim().length > 0 && description.trim().length < 20}
							<span class="hint-warn">Please give a bit more detail (at least 20 characters).</span>
						{/if}
					</div>

					<div class="form-group form-full">
						<span class="field-label">Witnesses</span>
						<textarea class="form-input" rows="2" bind:value={witnesses}
							placeholder="Anyone else who saw this"></textarea>
					</div>

					<div class="form-group form-full">
						<span class="field-label">Evidence <span class="optional">(image links)</span></span>
						<div class="evidence-row">
							<input class="form-input" bind:value={evidenceUrl}
								placeholder="https://…  paste a screenshot link"
								onkeydown={(e) => { if (e.key === "Enter") { e.preventDefault(); addEvidence(); } }} />
							<button class="add-btn" type="button" disabled={!evidenceUrl.trim()} onclick={addEvidence}>Add</button>
						</div>

						{#if evidenceList.length > 0}
							<div class="evidence-grid">
								{#each evidenceList as item, i (item.url)}
									<div class="evidence-tile" class:is-broken={item.broken}>
										{#if item.broken}
											<div class="evidence-broken">
												<span>Couldn't load</span>
												<span class="evidence-url">{item.url}</span>
											</div>
										{:else}
											<button class="evidence-open" type="button" title="Click to enlarge"
												onclick={() => (lightboxUrl = item.url)}>
												<img src={item.url} alt="Evidence" onerror={() => markBroken(i)} />
											</button>
										{/if}
										<button class="evidence-remove" type="button" aria-label="Remove"
											onclick={() => removeEvidence(i)}>
											<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
												<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
											</svg>
										</button>
									</div>
								{/each}
							</div>
						{/if}
					</div>
				</div>

				<div class="modal-footer">
					<span class="modal-hint">This is filed under your own name</span>
					<div class="modal-footer-right">
						<button class="cancel-btn" disabled={submitting} onclick={handleCancel}>Cancel</button>
						<button class="primary-btn" disabled={!isFormValid || submitting} onclick={handleSubmit}>
							{submitting ? "Submitting…" : "File Complaint"}
						</button>
					</div>
				</div>
			{/if}
		</div>
	</div>

	{#if lightboxUrl}
		<!-- svelte-ignore a11y_click_events_have_key_events -->
		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div class="lightbox-overlay" onclick={() => (lightboxUrl = null)}>
			<div class="lightbox-card" onclick={(e) => e.stopPropagation()}>
				<button class="lightbox-close" aria-label="Close" onclick={() => (lightboxUrl = null)}>
					<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
						<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
					</svg>
				</button>
				<img class="lightbox-img" src={lightboxUrl} alt="Evidence" />
			</div>
		</div>
	{/if}
{/if}

<style>
	/* Same language as the Add Weapon modal inside the MDT. No backdrop-filter:
	   CEF paints it solid black instead of blurring. */
	.modal-backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.6);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 1100;
	}
	.modal {
		/* Not --card-dark-bg: that's near-black, which works inside the MDT's own
		   chrome but reads as a void floating over the game world. */
		background: rgba(26, 28, 33, 0.97);
		border: 1px solid rgba(255, 255, 255, 0.1);
		border-radius: 6px;
		width: min(580px, 92vw);
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
	.modal-body::-webkit-scrollbar { width: 5px; }
	.modal-body::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.08); border-radius: 3px; }
	.form-body { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
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
	.req { color: rgba(248, 113, 113, 0.8); }
	.optional { color: rgba(255, 255, 255, 0.2); font-weight: 500; text-transform: none; letter-spacing: 0; }
	.counter { margin-left: auto; color: rgba(255, 255, 255, 0.25); font-variant-numeric: tabular-nums; }
	.counter-low { color: rgba(251, 191, 36, 0.8); }
	.hint-warn { font-size: 10px; color: rgba(251, 191, 36, 0.8); }

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

	.form-error {
		background: rgba(239, 68, 68, 0.08);
		border: 1px solid rgba(239, 68, 68, 0.2);
		border-radius: 4px;
		padding: 7px 10px;
		font-size: 10px;
		color: rgba(248, 113, 113, 0.95);
	}

	/* Evidence: the links render as pictures, so you can see what you attached. */
	.evidence-row { display: flex; gap: 6px; }
	.add-btn {
		flex-shrink: 0;
		background: rgba(255, 255, 255, 0.05);
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.7);
		font-size: 10px;
		font-weight: 600;
		padding: 4px 12px;
		cursor: pointer;
		transition: all 0.1s;
	}
	.add-btn:hover:not(:disabled) { background: rgba(255, 255, 255, 0.1); color: #fff; }
	.add-btn:disabled { opacity: 0.35; cursor: not-allowed; }

	.evidence-grid {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		margin-top: 6px;
	}
	.evidence-tile {
		position: relative;
		height: 92px;
		border-radius: 4px;
		border: 1px solid rgba(255, 255, 255, 0.08);
		background: rgba(255, 255, 255, 0.03);
		overflow: hidden;
	}
	.evidence-tile.is-broken { border-color: rgba(239, 68, 68, 0.25); }
	.evidence-open {
		display: block;
		height: 100%;
		padding: 0;
		border: none;
		background: none;
		cursor: zoom-in;
	}
	/* Fixed height, auto width: the tile hugs the picture instead of letterboxing it. */
	.evidence-open img { height: 100%; width: auto; max-width: 220px; object-fit: contain; display: block; }
	.evidence-broken {
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 3px;
		width: 150px;
		height: 100%;
		padding: 0 9px;
		font-size: 9px;
		color: rgba(248, 113, 113, 0.85);
	}
	.evidence-url {
		color: rgba(255, 255, 255, 0.3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.evidence-remove {
		position: absolute;
		top: 4px;
		right: 4px;
		display: flex;
		align-items: center;
		justify-content: center;
		width: 18px;
		height: 18px;
		border-radius: 3px;
		background: rgba(0, 0, 0, 0.65);
		border: 1px solid rgba(255, 255, 255, 0.15);
		color: rgba(255, 255, 255, 0.8);
		cursor: pointer;
		transition: all 0.1s;
	}
	.evidence-remove:hover { background: rgba(239, 68, 68, 0.8); color: #fff; }

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
	.primary-btn {
		background: rgba(16, 185, 129, 0.06);
		color: rgba(52, 211, 153, 0.7);
		border: 1px solid rgba(16, 185, 129, 0.1);
		border-radius: 3px;
		padding: 4px 12px;
		font-size: 10px;
		font-weight: 600;
		cursor: pointer;
		transition: all 0.1s;
	}
	.primary-btn:hover:not(:disabled) { background: rgba(16, 185, 129, 0.12); color: rgba(110, 231, 183, 0.9); }
	.primary-btn:disabled, .cancel-btn:disabled { opacity: 0.4; cursor: not-allowed; }

	/* Success */
	.success-body { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 26px 20px; text-align: center; }
	.success-mark {
		display: grid;
		place-items: center;
		width: 40px;
		height: 40px;
		border-radius: 50%;
		background: rgba(16, 185, 129, 0.1);
		border: 1px solid rgba(16, 185, 129, 0.25);
		color: rgba(52, 211, 153, 0.9);
	}
	.success-lead { margin: 0; font-size: 12px; color: rgba(255, 255, 255, 0.8); }
	.success-number {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 4px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 5px;
		padding: 9px 22px;
	}
	.ref-value {
		font-family: monospace;
		font-size: 17px;
		font-weight: 700;
		letter-spacing: 1px;
		color: rgba(252, 211, 77, 0.95);
	}
	.success-note { margin: 0; max-width: 340px; font-size: 10px; line-height: 1.5; color: rgba(255, 255, 255, 0.35); }

	/* Lightbox — same as the citizen profile's */
	.lightbox-overlay {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.85);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 2000;
	}
	.lightbox-card { position: relative; max-width: 90vw; max-height: 90vh; display: flex; flex-direction: column; padding-top: 40px; }
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
	.lightbox-img { max-width: 90vw; max-height: calc(90vh - 40px); object-fit: contain; display: block; border-radius: 4px; }
</style>