<script lang="ts">
	/**
	 * Roster → Applications: officers review civilian job applications for their own
	 * domain. A list on the left, the selected application's answers on the right, and an
	 * accept/reject action with an optional note that travels to the applicant.
	 */
	import { fetchNui } from "../utils/fetchNui";
	import { formatDate } from "../utils/datetime";

	// tabService lets us deep-link into a citizen's file — same mechanism Citizens
	// consumes via openWithTarget.
	let { tabService }: { tabService?: any } = $props();

	interface AppRow {
		id: number;
		application_number: string;
		department: string;
		applicant_name: string;
		applicant_citizenid: string;
		status: "pending" | "accepted" | "rejected";
		reviewed_by_name?: string | null;
		created_at: string;
	}

	interface Answer {
		label: string;
		type: string;
		answer: string;
	}

	interface AppDetail extends AppRow {
		applicant_phone?: string | null;
		applicant_image?: string | null;
		answers: Answer[];
		review_note?: string | null;
	}

	let statusFilter = $state<"pending" | "accepted" | "rejected" | "">("pending");
	let applications = $state<AppRow[]>([]);
	let loading = $state(false);

	let selectedId = $state<number | null>(null);
	let detail = $state<AppDetail | null>(null);
	let detailLoading = $state(false);

	// Lightbox for any image — the applicant portrait or an image-link answer.
	let lightboxSrc = $state<string | null>(null);
	let imageBroken = $state(false);
	function openImageLightbox(src: string) {
		if (src && src.trim() !== "") lightboxSrc = src;
	}

	let note = $state("");
	let deciding = $state(false);
	let actionError = $state("");

	const STATUS_LABEL: Record<string, string> = {
		pending: "Pending",
		accepted: "Accepted",
		rejected: "Rejected",
	};

	$effect(() => {
		// re-list whenever the filter changes
		statusFilter;
		loadList();
	});

	async function loadList() {
		loading = true;
		try {
			const res = await fetchNui<{ success: boolean; applications?: AppRow[] }>(
				"getApplications",
				{ status: statusFilter || undefined },
			);
			applications = res?.applications ?? [];
		} catch {
			applications = [];
		} finally {
			loading = false;
		}
	}

	async function open(row: AppRow) {
		selectedId = row.id;
		detail = null;
		note = "";
		actionError = "";
		lightboxSrc = null;
		imageBroken = false;
		detailLoading = true;
		try {
			const res = await fetchNui<{ success: boolean; application?: AppDetail }>(
				"getApplication",
				{ id: row.id },
			);
			detail = res?.success ? (res.application ?? null) : null;
		} catch {
			detail = null;
		} finally {
			detailLoading = false;
		}
	}

	// Deep-link into the applicant's citizen file (Citizens tab consumes the target).
	function openCitizenFile() {
		if (!detail || !tabService) return;
		tabService.openWithTarget("Citizens", detail.applicant_citizenid);
	}

	async function decide(status: "accepted" | "rejected") {
		if (!detail || deciding) return;
		deciding = true;
		actionError = "";
		try {
			const res = await fetchNui<{ success: boolean; message?: string }>(
				"decideApplication",
				{ id: detail.id, status, note: note.trim() || undefined },
			);
			if (res?.success) {
				// Reflect the decision locally and refresh the list.
				detail = { ...detail, status, review_note: note.trim() || null };
				await loadList();
			} else {
				actionError = res?.message || "Could not save the decision.";
			}
		} catch {
			actionError = "Could not save the decision.";
		} finally {
			deciding = false;
		}
	}

	function fmtDate(s: unknown): string {
		// created_at can arrive from oxmysql as a string, a number, or a Date depending
		// on driver/column — the project's formatDate takes `unknown` and handles all of
		// them. A local `s.replace(...)` assumed a string and threw on the others.
		return formatDate(s);
	}

	// Two-letter monogram for the header avatar (first + last initial).
	function initials(name: string): string {
		const parts = (name || "").trim().split(/\s+/).filter(Boolean);
		if (parts.length === 0) return "?";
		if (parts.length === 1) return parts[0].charAt(0).toUpperCase();
		return (parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase();
	}
</script>

<div class="apps">
	<div class="list-col">
		<div class="filters">
			{#each [["pending", "Pending"], ["accepted", "Accepted"], ["rejected", "Rejected"], ["", "All"]] as [val, lbl]}
				<button class="filter" class:active={statusFilter === val} onclick={() => (statusFilter = val as any)}>
					{lbl}
				</button>
			{/each}
		</div>

		<div class="list">
			{#if loading}
				<div class="empty">Loading…</div>
			{:else if applications.length === 0}
				<div class="empty">No applications.</div>
			{:else}
				{#each applications as app (app.id)}
					<button class="app-row" class:active={selectedId === app.id} onclick={() => open(app)}>
						<div class="row-top">
							<span class="app-name">{app.applicant_name}</span>
							<span class="badge {app.status}">{STATUS_LABEL[app.status]}</span>
						</div>
						<div class="row-sub">
							<span class="app-num">{app.application_number}</span>
							<span class="app-date">{fmtDate(app.created_at)}</span>
						</div>
					</button>
				{/each}
			{/if}
		</div>
	</div>

	<div class="detail-col">
		{#if !selectedId}
			<div class="detail-empty">Select an application to review.</div>
		{:else if detailLoading}
			<div class="detail-empty">Loading…</div>
		{:else if !detail}
			<div class="detail-empty">Could not load this application.</div>
		{:else}
			<div class="detail-head">
				<div class="dh-left">
					{#if detail.applicant_image && !imageBroken}
						<button
							class="dh-avatar dh-avatar-img"
							type="button"
							onclick={() => detail?.applicant_image && openImageLightbox(detail.applicant_image)}
							title="Click to enlarge"
						>
							<img
								src={detail.applicant_image}
								alt={detail.applicant_name}
								onerror={() => (imageBroken = true)}
							/>
							<span class="dh-zoom material-icons">zoom_in</span>
						</button>
					{:else}
						<div class="dh-avatar">{initials(detail.applicant_name)}</div>
					{/if}
					<div class="dh-id">
						<div class="d-name">{detail.applicant_name}</div>
						<div class="dh-chips">
							<span class="dh-chip mono">{detail.application_number}</span>
							<span class="dh-chip">{fmtDate(detail.created_at)}</span>
							{#if detail.applicant_phone}
								<span class="dh-chip">
									<span class="material-icons">call</span>{detail.applicant_phone}
								</span>
							{/if}
						</div>
					</div>
				</div>
				<div class="dh-right">
					<span class="badge {detail.status}">{STATUS_LABEL[detail.status]}</span>
					{#if tabService}
						<button class="dh-action" onclick={openCitizenFile} title="Open citizen file">
							<span class="material-icons">folder_shared</span>
							Open file
						</button>
					{/if}
				</div>
			</div>

			<div class="answers">
				<div class="answers-inner">
					<div class="answers-count">
						{detail.answers.length} {detail.answers.length === 1 ? "response" : "responses"}
					</div>
					{#each detail.answers as a, i (a.label)}
						<div class="answer">
							<div class="a-head">
								<span class="a-num">{i + 1}</span>
								<span class="a-label">{a.label}</span>
							</div>
							{#if a.type === "link" && a.answer}
								<!-- Image links load inline and enlarge on click. If the URL isn't an
								     image it collapses to a plain "open" link. -->
								<div class="a-image-wrap">
									<button
										type="button"
										class="a-image"
										onclick={() => openImageLightbox(a.answer)}
										title="Click to enlarge"
									>
										<img
											src={a.answer}
											alt={a.label}
											onerror={(e) => {
												const img = e.currentTarget as HTMLImageElement;
												img.style.display = "none";
												(img.parentElement as HTMLElement).classList.add("failed");
											}}
										/>
										<span class="a-image-zoom material-icons">zoom_in</span>
									</button>
								</div>
							{:else if a.type === "boolean"}
								<div class="a-bool" class:yes={a.answer === "Yes"}>
									<span class="material-icons">{a.answer === "Yes" ? "check_circle" : "cancel"}</span>
									{a.answer || "—"}
								</div>
							{:else}
								<div class="a-value" class:empty={!a.answer}>{a.answer || "— no answer —"}</div>
							{/if}
						</div>
					{/each}
				</div>
			</div>

			{#if detail.status === "pending"}
				<div class="decision">
					<textarea
						class="note"
						rows="2"
						placeholder="Optional note to the applicant…"
						bind:value={note}
					></textarea>
					{#if actionError}<div class="action-error">{actionError}</div>{/if}
					<div class="decision-actions">
						<button class="btn reject" disabled={deciding} onclick={() => decide("rejected")}>
							Reject
						</button>
						<button class="btn accept" disabled={deciding} onclick={() => decide("accepted")}>
							Accept
						</button>
					</div>
				</div>
			{:else}
				<div class="decided">
					<span class="material-icons">{detail.status === "accepted" ? "check_circle" : "cancel"}</span>
					<div>
						<div class="decided-title">
							{detail.status === "accepted" ? "Accepted" : "Rejected"}
							{#if detail.reviewed_by_name}by {detail.reviewed_by_name}{/if}
						</div>
						{#if detail.review_note}<div class="decided-note">"{detail.review_note}"</div>{/if}
					</div>
				</div>
			{/if}
		{/if}
	</div>
</div>

{#if lightboxSrc}
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="lightbox-overlay" onclick={() => (lightboxSrc = null)}>
		<div class="lightbox-card" onclick={(e) => e.stopPropagation()}>
			<button class="lightbox-close" aria-label="Close" onclick={() => (lightboxSrc = null)}>
				<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
			</button>
			<img class="lightbox-img" src={lightboxSrc} alt="Preview" />
		</div>
	</div>
{/if}

<style>
	/* Built to match the Bolos/Warrants list views: underline-tab filters, flat rows with
	   hairline separators, 9px uppercase status pills, a split list/detail layout. */
	.apps {
		display: flex;
		gap: 0;
		height: 100%;
		min-height: 0;
	}

	/* ── Left: filter + list ── */
	.list-col {
		display: flex;
		flex-direction: column;
		width: 300px;
		flex-shrink: 0;
		min-height: 0;
		border-right: 1px solid rgba(255, 255, 255, 0.06);
	}
	.filters {
		display: flex;
		gap: 2px;
		padding: 0 12px;
		height: 40px;
		align-items: center;
		flex-shrink: 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}
	.filter {
		background: transparent;
		border: none;
		border-radius: 0;
		padding: 4px 9px;
		color: rgba(255, 255, 255, 0.3);
		font-size: 10px;
		font-weight: 500;
		cursor: pointer;
		transition: all 0.1s;
		border-bottom: 2px solid transparent;
	}
	.filter:hover { color: rgba(255, 255, 255, 0.6); }
	.filter.active {
		color: rgba(96, 165, 250, 0.9);
		border-bottom-color: rgba(var(--accent-rgb), 0.5);
	}

	.list {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.06) transparent;
	}
	.list::-webkit-scrollbar { width: 4px; }
	.list::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.06); border-radius: 2px; }

	.empty {
		padding: 30px 16px;
		text-align: center;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.3);
	}

	.app-row {
		display: flex;
		flex-direction: column;
		gap: 4px;
		width: 100%;
		padding: 9px 14px;
		background: transparent;
		border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
		border-left: 2px solid transparent;
		border-radius: 0;
		cursor: pointer;
		transition: background 0.1s;
		text-align: left;
		font: inherit;
		color: inherit;
	}
	.app-row:hover { background: rgba(255, 255, 255, 0.02); }
	.app-row.active {
		background: rgba(var(--accent-rgb), 0.05);
		border-left-color: rgba(var(--accent-rgb), 0.6);
	}
	.row-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
	.app-name { font-size: 11px; font-weight: 600; color: rgba(255, 255, 255, 0.85); }
	.row-sub { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
	.app-num { font-family: "Courier New", monospace; font-size: 9px; color: rgba(255, 255, 255, 0.35); }
	.app-date { font-size: 9px; color: rgba(255, 255, 255, 0.3); }

	/* Status pills identical to the Bolos convention. */
	.badge {
		padding: 1px 6px;
		border-radius: 3px;
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.3px;
		flex-shrink: 0;
	}
	.badge.pending {
		background: rgba(245, 158, 11, 0.08);
		color: rgba(251, 191, 36, 0.85);
		border: 1px solid rgba(245, 158, 11, 0.12);
	}
	.badge.accepted {
		background: rgba(16, 185, 129, 0.08);
		color: rgba(52, 211, 153, 0.85);
		border: 1px solid rgba(16, 185, 129, 0.12);
	}
	.badge.rejected {
		background: rgba(239, 68, 68, 0.08);
		color: rgba(248, 113, 113, 0.85);
		border: 1px solid rgba(239, 68, 68, 0.12);
	}

	/* ── Right: detail ── */
	.detail-col {
		flex: 1;
		min-width: 0;
		min-height: 0;
		display: flex;
		flex-direction: column;
	}
	.detail-empty {
		display: grid;
		place-items: center;
		height: 100%;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.3);
	}

	.detail-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 16px 22px;
		flex-shrink: 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		background: rgba(255, 255, 255, 0.015);
	}
	.dh-left { display: flex; align-items: center; gap: 13px; min-width: 0; }
	.dh-avatar {
		display: grid;
		place-items: center;
		width: 42px;
		height: 42px;
		flex-shrink: 0;
		border-radius: 8px;
		background: rgba(var(--accent-rgb), 0.12);
		border: 1px solid rgba(var(--accent-rgb), 0.2);
		color: rgba(var(--accent-rgb), 0.95);
		font-size: 15px;
		font-weight: 700;
		letter-spacing: 0.5px;
	}
	/* When there's a real portrait, the avatar becomes a clickable thumbnail that opens
	   the lightbox — same affordance as the impound photo. */
	.dh-avatar-img {
		position: relative;
		padding: 0;
		overflow: hidden;
		cursor: pointer;
		background: rgba(0, 0, 0, 0.3);
	}
	.dh-avatar-img img { width: 100%; height: 100%; object-fit: cover; display: block; }
	.dh-zoom {
		position: absolute;
		inset: 0;
		display: grid;
		place-items: center;
		background: rgba(0, 0, 0, 0.5);
		color: #fff;
		font-size: 18px;
		opacity: 0;
		transition: opacity 0.12s;
	}
	.dh-avatar-img:hover .dh-zoom { opacity: 1; }

	.dh-right { display: flex; align-items: center; gap: 10px; flex-shrink: 0; }
	.dh-action {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 6px 12px;
		border-radius: 3px;
		background: rgba(var(--accent-rgb), 0.08);
		border: 1px solid rgba(var(--accent-rgb), 0.18);
		color: rgba(255, 255, 255, 0.8);
		font-size: 10px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.4px;
		cursor: pointer;
		transition: all 0.1s;
	}
	.dh-action:hover { background: rgba(var(--accent-rgb), 0.16); color: rgba(255, 255, 255, 0.95); }
	.dh-action .material-icons { font-size: 14px; }
	.dh-id { min-width: 0; }
	.d-name { font-size: 15px; font-weight: 600; color: rgba(255, 255, 255, 0.95); }
	.dh-chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 5px; }
	.dh-chip {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 2px 8px;
		border-radius: 3px;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.05);
		font-size: 10px;
		color: rgba(255, 255, 255, 0.5);
	}
	.dh-chip.mono { font-family: "Courier New", monospace; letter-spacing: 0.3px; }
	.dh-chip .material-icons { font-size: 11px; }

	.answers {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		padding: 22px;
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.06) transparent;
	}
	.answers::-webkit-scrollbar { width: 5px; }
	.answers::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.08); border-radius: 3px; }

	/* The detail pane is very wide; answers left to fill it become long unreadable lines
	   in a sea of empty space (the blank look in the screenshot). Cap and center them into
	   a readable column instead. */
	.answers-inner {
		max-width: 620px;
		margin: 0 auto;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}
	.answers-count {
		font-size: 9px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.3);
		margin-bottom: 2px;
	}

	/* Each answer is a card, so the form reads as discrete responses rather than a wall. */
	.answer {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 13px 15px;
		border-radius: 5px;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.05);
	}
	.a-head { display: flex; align-items: center; gap: 9px; }
	.a-num {
		display: grid;
		place-items: center;
		flex-shrink: 0;
		width: 18px;
		height: 18px;
		border-radius: 4px;
		background: rgba(var(--accent-rgb), 0.1);
		color: rgba(var(--accent-rgb), 0.85);
		font-size: 10px;
		font-weight: 700;
	}
	.a-label {
		font-size: 11px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.6);
	}
	.a-value {
		font-size: 12.5px;
		line-height: 1.55;
		color: rgba(255, 255, 255, 0.85);
		white-space: pre-wrap;
		word-break: break-word;
		padding-left: 27px;
	}
	.a-value.empty { font-style: italic; color: rgba(255, 255, 255, 0.28); }
	/* Image-link answers render as a thumbnail that enlarges on click, with a small
	   fallback "open link" beneath in case the URL isn't an image. */
	.a-image-wrap { display: flex; flex-direction: column; gap: 6px; padding-left: 27px; }
	.a-image {
		position: relative;
		width: 180px;
		height: 120px;
		padding: 0;
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 5px;
		overflow: hidden;
		background: rgba(0, 0, 0, 0.3);
		cursor: pointer;
		align-self: flex-start;
	}
	.a-image img { width: 100%; height: 100%; object-fit: cover; display: block; }
	.a-image-zoom {
		position: absolute;
		inset: 0;
		display: grid;
		place-items: center;
		background: rgba(0, 0, 0, 0.4);
		color: #fff;
		font-size: 22px;
		opacity: 0;
		transition: opacity 0.12s;
	}
	.a-image:hover .a-image-zoom { opacity: 1; }
	/* When the image fails to load we hide the <img>; mark the button so it doesn't sit
	   as an empty black box. */
	.a-image.failed { width: auto; height: auto; border: none; background: none; }
	.a-open {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		font-size: 11px;
		color: rgba(96, 165, 250, 0.85);
		text-decoration: none;
		align-self: flex-start;
	}
	.a-open:hover { color: rgba(147, 197, 253, 1); text-decoration: underline; }

	/* Yes/No answers get an icon so the verdict is readable at a glance. */
	.a-bool {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		margin-left: 27px;
		padding: 4px 12px;
		border-radius: 4px;
		width: fit-content;
		font-size: 12px;
		font-weight: 600;
		background: rgba(239, 68, 68, 0.08);
		border: 1px solid rgba(239, 68, 68, 0.15);
		color: rgba(248, 113, 113, 0.9);
	}
	.a-bool.yes {
		background: rgba(16, 185, 129, 0.08);
		border-color: rgba(16, 185, 129, 0.2);
		color: rgba(52, 211, 153, 0.9);
	}
	.a-bool .material-icons { font-size: 14px; }

	.decision {
		padding: 13px 22px;
		flex-shrink: 0;
		border-top: 1px solid rgba(255, 255, 255, 0.06);
		display: flex;
		flex-direction: column;
		gap: 9px;
		max-width: 664px;
		margin: 0 auto;
		width: 100%;
		box-sizing: border-box;
	}
	.note {
		width: 100%;
		padding: 7px 10px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.85);
		font-size: 11px;
		font-family: inherit;
		resize: vertical;
		box-sizing: border-box;
		transition: border-color 0.1s;
	}
	.note:focus { outline: none; border-color: rgba(var(--accent-rgb), 0.4); }
	.note::placeholder { color: rgba(255, 255, 255, 0.2); }
	.action-error { font-size: 10px; color: rgba(248, 113, 113, 0.95); }
	.decision-actions { display: flex; justify-content: flex-end; gap: 6px; }

	.btn {
		padding: 6px 18px;
		border-radius: 3px;
		font-size: 10px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.4px;
		cursor: pointer;
		border: 1px solid transparent;
		transition: all 0.1s;
	}
	.btn:disabled { opacity: 0.4; cursor: not-allowed; }
	.btn.reject {
		background: rgba(239, 68, 68, 0.06);
		border-color: rgba(239, 68, 68, 0.15);
		color: rgba(248, 113, 113, 0.8);
	}
	.btn.reject:hover:not(:disabled) { background: rgba(239, 68, 68, 0.13); color: rgba(252, 165, 165, 0.95); }
	.btn.accept {
		background: rgba(16, 185, 129, 0.1);
		border-color: rgba(16, 185, 129, 0.25);
		color: rgba(52, 211, 153, 0.9);
	}
	.btn.accept:hover:not(:disabled) { background: rgba(16, 185, 129, 0.18); color: rgba(110, 231, 183, 1); }

	.decided {
		display: flex;
		align-items: flex-start;
		gap: 10px;
		padding: 13px 22px;
		flex-shrink: 0;
		border-top: 1px solid rgba(255, 255, 255, 0.06);
		max-width: 664px;
		margin: 0 auto;
		width: 100%;
		box-sizing: border-box;
	}
	.decided .material-icons { font-size: 18px; color: rgba(255, 255, 255, 0.35); }
	.decided-title { font-size: 11px; font-weight: 600; color: rgba(255, 255, 255, 0.78); }
	.decided-note { margin-top: 4px; font-size: 11px; font-style: italic; color: rgba(255, 255, 255, 0.5); }
	/* Lightbox — identical to the impound form's. */
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
	}
	.lightbox-close:hover { background: rgba(255, 255, 255, 0.2); color: #fff; }
	.lightbox-img {
		max-width: 90vw;
		max-height: calc(90vh - 40px);
		object-fit: contain;
		display: block;
		border-radius: 4px;
	}
</style>