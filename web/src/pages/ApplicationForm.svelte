<script lang="ts">
	/**
	 * Job application form.
	 *
	 * Standalone: opened with /applypolice, /applyems, /applydoj (one command per
	 * department, from config), outside the MDT — any civilian can apply. The questions
	 * are not hard-coded here; they're fetched per department and rendered by type, so a
	 * department changes what it asks entirely from the in-MDT editor.
	 *
	 * Styled to match the complaint form so it reads as part of the same product.
	 */
	import { fetchNui } from "../utils/fetchNui";

	let {
		show = false,
		department = "",
		onClose = () => {},
	}: { show: boolean; department: string; onClose: () => void } = $props();

	interface Question {
		id: number;
		label: string;
		type: "short" | "long" | "choice" | "boolean" | "number" | "link";
		options?: string[] | null;
		required: boolean;
	}

	let loading = $state(false);
	let loadError = $state("");
	let title = $state("Application");
	let questions = $state<Question[]>([]);

	// Answers keyed by question id (as string, matching the server's snapshot lookup).
	let answers = $state<Record<string, string | boolean>>({});

	let submitting = $state(false);
	let submitted = $state(false);
	let applicationNumber = $state("");
	let errorMessage = $state("");

	// Fixed accent per department, using the project's established colors: police blue
	// (#60a5fa, the "court"/LEO blue used on the dashboard), EMS red (#ef4444, the medic
	// danger red), DOJ gold (#f59e0b, the amber used for court/warrants). Setting
	// --accent-rgb locally on the modal re-tints every accent-driven style at once, so the
	// whole form takes on the department's identity without touching the global theme.
	const DOMAIN_ACCENT: Record<string, string> = {
		police: "96, 165, 250",
		ambulance: "239, 68, 68",
		ems: "239, 68, 68",
		doj: "245, 158, 11",
	};
	let accentRgb = $derived(DOMAIN_ACCENT[department] ?? "96, 165, 250");

	// Shared lightbox for image-link previews.
	let lightboxSrc = $state<string | null>(null);
	function openLightbox(src: string) {
		if (src && src.trim() !== "") lightboxSrc = src;
	}

	// Load the form whenever it's shown for a department.
	$effect(() => {
		if (show && department) {
			loadForm();
		}
	});

	async function loadForm() {
		loading = true;
		loadError = "";
		submitted = false;
		errorMessage = "";
		answers = {};
		try {
			const res = await fetchNui<{
				success: boolean;
				label?: string;
				questions?: Question[];
				message?: string;
			}>("getApplicationForm", { department });

			if (!res?.success) {
				loadError = res?.message || "Could not load the application form.";
				questions = [];
				return;
			}
			title = res.label || "Application";
			questions = res.questions || [];

			// Seed defaults so booleans have a concrete value.
			const seed: Record<string, string | boolean> = {};
			for (const q of questions) {
				seed[String(q.id)] = q.type === "boolean" ? false : "";
			}
			answers = seed;
		} catch (e) {
			loadError = "Could not load the application form.";
			questions = [];
		} finally {
			loading = false;
		}
	}

	function isValidLink(v: string): boolean {
		const s = v.trim();
		return s === "" || /^https?:\/\/\S+$/i.test(s);
	}

	// Every required field answered, every link well-formed.
	let isFormValid = $derived.by(() => {
		for (const q of questions) {
			const val = answers[String(q.id)];
			if (q.required && q.type !== "boolean") {
				if (val === undefined || val === null || String(val).trim() === "") return false;
			}
			if (q.type === "link" && typeof val === "string" && !isValidLink(val)) return false;
		}
		return true;
	});

	// Progress readout in the footer. Booleans always count as answered.
	let requiredCount = $derived(questions.filter((q) => q.required).length);
	let answeredCount = $derived(
		questions.filter((q) => {
			if (!q.required) return false;
			if (q.type === "boolean") return true;
			const v = answers[String(q.id)];
			return v !== undefined && v !== null && String(v).trim() !== "";
		}).length,
	);

	async function submit() {
		if (!isFormValid || submitting) return;
		submitting = true;
		errorMessage = "";
		try {
			const res = await fetchNui<{ success: boolean; number?: string; message?: string }>(
				"submitApplication",
				{ department, answers },
			);
			if (res?.success) {
				submitted = true;
				applicationNumber = res.number || "";
			} else {
				errorMessage = res?.message || "Could not submit your application.";
			}
		} catch (e) {
			errorMessage = "Could not submit your application.";
		} finally {
			submitting = false;
		}
	}

	function close() {
		fetchNui("closeApplication", {}).catch(() => {});
		onClose();
	}
</script>

{#if show}
	<div class="modal-backdrop">
		<div class="modal" style="--accent-rgb: {accentRgb};">
			<div class="modal-header">
				<div class="mh-left">
					<span class="mh-icon material-icons">badge</span>
					<div>
						<h3>{title}</h3>
						<span class="mh-sub">Recruitment application</span>
					</div>
				</div>
				<button class="close-btn" onclick={close} aria-label="Close">
					<span class="material-icons">close</span>
				</button>
			</div>

			<div class="modal-body">
				{#if loading}
					<div class="state-msg">Loading application…</div>
				{:else if loadError}
					<div class="state-msg error">{loadError}</div>
				{:else if submitted}
					<div class="success-box">
						<span class="material-icons">check_circle</span>
						<div class="success-text">
							<div class="success-title">Application submitted</div>
							<div class="success-sub">
								Your reference is <strong>{applicationNumber}</strong>. You'll be
								contacted with a decision.
							</div>
						</div>
					</div>
				{:else if questions.length === 0}
					<div class="state-msg">
						This department isn't accepting applications right now.
					</div>
				{:else}
					{#each questions as q, i (q.id)}
						<div class="q-card">
							<div class="q-head">
								<span class="q-num">{i + 1}</span>
								<span class="q-label">{q.label}</span>
								{#if q.required}<span class="q-req">Required</span>{/if}
							</div>

							{#if q.type === "short"}
								<input class="form-input" type="text" placeholder="Your answer…" bind:value={answers[String(q.id)]} />
							{:else if q.type === "long"}
								<textarea class="form-input" rows="4" placeholder="Your answer…" bind:value={answers[String(q.id)]}
								></textarea>
							{:else if q.type === "number"}
								<input class="form-input" type="number" placeholder="0" bind:value={answers[String(q.id)]} />
							{:else if q.type === "link"}
								<input
									class="form-input"
									type="text"
									placeholder="https://… (image link)"
									bind:value={answers[String(q.id)]}
								/>
								{#if typeof answers[String(q.id)] === "string" && !isValidLink(answers[String(q.id)] as string)}
									<span class="field-warn">
										<span class="material-icons">error_outline</span>
										Enter a full URL starting with http(s)://
									</span>
								{:else if typeof answers[String(q.id)] === "string" && (answers[String(q.id)] as string).trim() !== ""}
									<!-- Live preview so the applicant sees the image loaded immediately.
									     Clicking enlarges it. Falls back to a plain link if it isn't an image. -->
									<button
										type="button"
										class="img-preview"
										onclick={() => openLightbox(answers[String(q.id)] as string)}
										title="Click to enlarge"
									>
										<img
											src={answers[String(q.id)] as string}
											alt="Preview"
											onerror={(e) => ((e.currentTarget as HTMLImageElement).style.display = "none")}
										/>
										<span class="img-zoom material-icons">zoom_in</span>
									</button>
								{/if}
							{:else if q.type === "choice"}
								<select class="form-input form-select" bind:value={answers[String(q.id)]}>
									<option value="">Select an option…</option>
									{#each q.options || [] as opt}
										<option value={opt}>{opt}</option>
									{/each}
								</select>
							{:else if q.type === "boolean"}
								<div class="bool-toggle">
									<button
										type="button"
										class="bool-opt"
										class:active={answers[String(q.id)] === true}
										onclick={() => (answers[String(q.id)] = true)}
									>Yes</button>
									<button
										type="button"
										class="bool-opt"
										class:active={answers[String(q.id)] !== true}
										onclick={() => (answers[String(q.id)] = false)}
									>No</button>
								</div>
							{/if}
						</div>
					{/each}
				{/if}
			</div>

			{#if !submitted && !loading && questions.length > 0}
				<div class="modal-footer">
					{#if errorMessage}
						<span class="modal-error">{errorMessage}</span>
					{:else}
						<span class="modal-hint">{answeredCount} of {requiredCount} required answered</span>
					{/if}
					<div class="modal-footer-right">
						<button class="cancel-btn" onclick={close}>Cancel</button>
						<button class="submit-btn" disabled={!isFormValid || submitting} onclick={submit}>
							{submitting ? "Submitting…" : "Submit application"}
						</button>
					</div>
				</div>
			{/if}
		</div>
	</div>
{/if}

{#if lightboxSrc}
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="lightbox-overlay" onclick={() => (lightboxSrc = null)}>
		<div class="lightbox-card" onclick={(e) => e.stopPropagation()}>
			<button class="lightbox-close" aria-label="Close" onclick={() => (lightboxSrc = null)}>
				<span class="material-icons">close</span>
			</button>
			<img class="lightbox-img" src={lightboxSrc} alt="Preview" />
		</div>
	</div>
{/if}

<style>
	/* Built to match the on-site impound form: solid translucent scrim (no
	   backdrop-filter — CEF paints blur as a black block), a roomy panel that reads at
	   native resolution over the game world, fine 1px borders, small uppercase labels. */
	.modal-backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 1200;
	}
	.modal {
		/* A dark base with a faint department-coloured wash layered on top, so the whole
		   form reads in the department's colour rather than just the icons. */
		background:
			linear-gradient(rgba(var(--accent-rgb, 56, 189, 248), 0.05), rgba(var(--accent-rgb, 56, 189, 248), 0.02)),
			rgba(26, 28, 33, 0.97);
		border: 1px solid rgba(var(--accent-rgb, 56, 189, 248), 0.3);
		border-radius: 6px;
		width: min(600px, 94vw);
		max-height: 88vh;
		overflow: hidden;
		display: flex;
		flex-direction: column;
		box-shadow:
			0 24px 70px rgba(0, 0, 0, 0.65),
			0 0 0 1px rgba(var(--accent-rgb, 56, 189, 248), 0.06);
	}

	.modal-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 13px 20px;
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.08);
		border-bottom: 1px solid rgba(var(--accent-rgb, 56, 189, 248), 0.2);
	}
	.mh-left { display: flex; align-items: center; gap: 12px; }
	.mh-icon {
		font-size: 22px;
		color: rgba(var(--accent-rgb, 56, 189, 248), 0.85);
	}
	.modal-header h3 { margin: 0; font-size: 14px; font-weight: 600; color: rgba(255, 255, 255, 0.85); }
	.mh-sub {
		font-size: 10px;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.35);
	}
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
	.close-btn .material-icons { font-size: 16px; }

	.modal-body {
		padding: 16px 20px;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 12px;
	}
	.modal-body::-webkit-scrollbar { width: 6px; }
	.modal-body::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.1); border-radius: 3px; }

	/* Each question is its own quiet card, so a long form reads as a sequence of steps
	   rather than one dense wall of inputs. */
	.q-card {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 12px 14px;
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.03);
		border: 1px solid rgba(var(--accent-rgb, 56, 189, 248), 0.1);
		border-radius: 5px;
	}
	.q-head { display: flex; align-items: center; gap: 9px; }
	.q-num {
		display: grid;
		place-items: center;
		flex-shrink: 0;
		width: 18px;
		height: 18px;
		border-radius: 4px;
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.12);
		color: rgba(var(--accent-rgb, 56, 189, 248), 0.9);
		font-size: 10px;
		font-weight: 700;
	}
	.q-label {
		flex: 1;
		font-size: 12px;
		font-weight: 500;
		color: rgba(255, 255, 255, 0.82);
	}
	.q-req {
		flex-shrink: 0;
		font-size: 8px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.5px;
		color: rgba(251, 146, 60, 0.9);
		background: rgba(251, 146, 60, 0.1);
		border: 1px solid rgba(251, 146, 60, 0.2);
		border-radius: 3px;
		padding: 2px 6px;
	}

	/* Same field language as the shared impound fields. */
	.form-input {
		width: 100%;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 7px 10px;
		color: rgba(255, 255, 255, 0.85);
		font-size: 12px;
		font-family: inherit;
		box-sizing: border-box;
		transition: border-color 0.1s;
	}
	.form-input:focus { outline: none; border-color: rgba(var(--accent-rgb, 56, 189, 248), 0.4); }
	.form-input::placeholder { color: rgba(255, 255, 255, 0.2); }
	.form-input option { background: #1a1d23; }
	.form-select { cursor: pointer; }
	textarea.form-input { resize: vertical; line-height: 1.45; min-height: 84px; }

	.field-warn {
		display: flex;
		align-items: center;
		gap: 5px;
		font-size: 10px;
		color: rgba(251, 191, 36, 0.9);
	}
	.field-warn .material-icons { font-size: 13px; }

	/* Yes/No as a two-segment pill, matching the hold-chip control in the impound form. */
	.bool-toggle {
		display: inline-flex;
		gap: 4px;
		padding: 3px;
		background: rgba(0, 0, 0, 0.25);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 5px;
		align-self: flex-start;
	}
	.bool-opt {
		padding: 5px 18px;
		border: none;
		border-radius: 3px;
		background: transparent;
		color: rgba(255, 255, 255, 0.5);
		font-size: 11px;
		font-weight: 600;
		cursor: pointer;
		transition: all 0.1s;
	}
	.bool-opt.active {
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.15);
		color: rgba(255, 255, 255, 0.92);
	}

	.state-msg {
		padding: 34px 0;
		text-align: center;
		font-size: 12px;
		color: rgba(255, 255, 255, 0.4);
	}
	.state-msg.error { color: rgba(248, 113, 113, 0.95); }

	.success-box {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 18px;
		border-radius: 5px;
		background: rgba(16, 185, 129, 0.08);
		border: 1px solid rgba(16, 185, 129, 0.25);
	}
	.success-box .material-icons { font-size: 30px; color: rgb(16, 185, 129); flex-shrink: 0; }
	.success-title { font-size: 13px; font-weight: 600; color: rgba(255, 255, 255, 0.9); }
	.success-sub { margin-top: 3px; font-size: 11px; line-height: 1.5; color: rgba(255, 255, 255, 0.6); }

	.modal-footer {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 12px;
		padding: 13px 20px;
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.05);
		border-top: 1px solid rgba(var(--accent-rgb, 56, 189, 248), 0.15);
	}
	.modal-footer-right { display: flex; gap: 8px; }
	.modal-hint { font-size: 11px; color: rgba(255, 255, 255, 0.35); }
	.modal-error { font-size: 11px; color: rgba(248, 113, 113, 0.95); }

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
	.cancel-btn:hover { color: rgba(255, 255, 255, 0.7); border-color: rgba(255, 255, 255, 0.1); }
	.submit-btn {
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.15);
		color: rgba(255, 255, 255, 0.92);
		border: 1px solid rgba(var(--accent-rgb, 56, 189, 248), 0.3);
		border-radius: 3px;
		padding: 6px 16px;
		font-size: 11px;
		font-weight: 600;
		cursor: pointer;
		transition: all 0.1s;
	}
	.submit-btn:hover:not(:disabled) {
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.25);
	}
	.submit-btn:disabled { opacity: 0.4; cursor: not-allowed; }
	/* Image-link preview: a compact thumbnail that loads the linked image immediately and
	   opens the lightbox on click. */
	.img-preview {
		position: relative;
		margin-top: 2px;
		width: 120px;
		height: 80px;
		padding: 0;
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 4px;
		overflow: hidden;
		background: rgba(0, 0, 0, 0.3);
		cursor: pointer;
		align-self: flex-start;
	}
	.img-preview img { width: 100%; height: 100%; object-fit: cover; display: block; }
	.img-zoom {
		position: absolute;
		inset: 0;
		display: grid;
		place-items: center;
		background: rgba(0, 0, 0, 0.45);
		color: #fff;
		font-size: 20px;
		opacity: 0;
		transition: opacity 0.12s;
	}
	.img-preview:hover .img-zoom { opacity: 1; }

	.lightbox-overlay {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.85);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 2000;
	}
	.lightbox-card { position: relative; max-width: 90vw; max-height: 90vh; padding-top: 40px; }
	.lightbox-close {
		position: absolute;
		top: 0;
		right: 0;
		display: grid;
		place-items: center;
		background: rgba(255, 255, 255, 0.1);
		border: 1px solid rgba(255, 255, 255, 0.12);
		border-radius: 4px;
		color: rgba(255, 255, 255, 0.7);
		cursor: pointer;
		padding: 5px;
	}
	.lightbox-close:hover { background: rgba(255, 255, 255, 0.2); color: #fff; }
	.lightbox-close .material-icons { font-size: 16px; }
	.lightbox-img { max-width: 90vw; max-height: calc(90vh - 40px); object-fit: contain; display: block; border-radius: 4px; }
</style>