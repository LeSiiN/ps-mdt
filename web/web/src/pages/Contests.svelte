<script lang="ts">
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";

	let { authService }: { authService: any } = $props();

	type Contested = {
		citation_number: string;
		type: "citation" | "parking" | "warning";
		recipient_name?: string;
		plate?: string;
		vehicle?: string;
		officer_name: string;
		officer_callsign?: string;
		officer_job?: string;
		location?: string;
		speed_measured?: number;
		speed_limit?: number;
		notes?: string;
		charges: Array<{ code: string; label: string; fine: number }>;
		fine_total: number;
		signed_at?: string;
		contest_reason?: string;
		officer_statement?: string;
		issued_at?: string;
		contested_at?: string;
		statement_at?: string;
		contest_deadline?: string;
		hours_left?: number;
	};

	let rows = $state<Contested[]>([]);
	let loading = $state(true);
	let selected = $state<string | null>(null);
	let busy = $state(false);
	let msg = $state("");

	// Statement is the officer's; verdict is the court's. One page, two roles —
	// an officer needs to answer the challenge, a judge needs to decide it, and
	// both are looking at exactly the same file.
	let isDoj = $derived(authService?.jobType === "doj");
	let myCitizenId = $derived(authService?.playerData?.citizenid ?? "");

	let statementDraft = $state("");
	let verdictNote = $state("");
	let reducedFine = $state<number | null>(null);

	let current = $derived(rows.find(r => r.citation_number === selected) ?? null);

	async function load() {
		loading = true;
		try {
			rows = (await fetchNui<Contested[]>(NUI_EVENTS.CITATION.GET_CONTESTED, {})) ?? [];
		} catch { rows = []; }
		loading = false;
		if (selected && !rows.some(r => r.citation_number === selected)) selected = null;
	}

	$effect(() => { load(); });

	function pick(r: Contested) {
		selected = r.citation_number;
		statementDraft = r.officer_statement ?? "";
		verdictNote = "";
		reducedFine = Number(r.fine_total) || 0;
		msg = "";
	}

	async function fileStatement() {
		if (!current) return;
		busy = true; msg = "";
		try {
			const res: any = await fetchNui(NUI_EVENTS.CITATION.CITATION_STATEMENT, {
				number: current.citation_number, statement: statementDraft,
			});
			if (res?.success) await load();
			else msg = res?.error ?? "Could not file the statement.";
		} catch { msg = "Could not file the statement."; }
		busy = false;
	}

	async function rule(verdict: "upheld" | "dismissed" | "reduced") {
		if (!current) return;
		busy = true; msg = "";
		try {
			const res: any = await fetchNui(NUI_EVENTS.CITATION.CITATION_VERDICT, {
				number: current.citation_number,
				verdict,
				fine: verdict === "reduced" ? reducedFine : undefined,
				note: verdictNote.trim() || undefined,
			});
			if (res?.success) { selected = null; await load(); }
			else msg = res?.error ?? "Could not record the verdict.";
		} catch { msg = "Could not record the verdict."; }
		busy = false;
	}

	// Hours rather than a date: what matters is how close this is to lapsing,
	// and a lapsed challenge is dismissed.
	function leftLabel(r: Contested): string {
		const h = Number(r.hours_left);
		if (!isFinite(h)) return "";
		if (h <= 0) return "lapsing now";
		if (h < 24) return `${h}h left`;
		return `${Math.floor(h / 24)}d left`;
	}
	const urgent = (r: Contested) => Number(r.hours_left) < 24;
</script>

<div class="ct-page">
	<!-- Left: the queue, closest to lapsing first -->
	<div class="ct-list">
		<div class="ct-head">
			<span class="material-icons ct-hicon">gavel</span>
			<div class="ct-htext">
				<span class="ct-title">Contested</span>
				<span class="ct-hsub">unheard challenges lapse</span>
			</div>
			<span class="ct-count" class:zero={rows.length === 0}>{rows.length}</span>
		</div>

		{#if loading}
			<div class="ct-empty"><span class="material-icons">hourglass_empty</span>Loading…</div>
		{:else if rows.length === 0}
			<div class="ct-empty">
				<span class="material-icons">task_alt</span>
				Nothing under challenge
				<span class="ct-esub">Every ticket has been settled or heard.</span>
			</div>
		{:else}
			{#each rows as r (r.citation_number)}
				<button class="ct-item" class:sel={selected === r.citation_number}
					class:urgent={urgent(r)} onclick={() => pick(r)}>
					<div class="ct-item-top">
						<span class="ct-no">{r.citation_number}</span>
						<span class="ct-left" class:late={urgent(r)}>{leftLabel(r)}</span>
					</div>
					<div class="ct-who">{r.recipient_name ?? r.plate ?? "—"}</div>
					<div class="ct-sub">
						${Number(r.fine_total).toLocaleString()} ·
						{#if r.officer_statement}statement filed{:else}<span class="ct-missing">no statement</span>{/if}
					</div>
				</button>
			{/each}
		{/if}
	</div>

	<!-- Right: the whole file. Ticket, both accounts, timeline. -->
	<div class="ct-detail">
		{#if !current}
			<div class="ct-empty tall">
				<span class="material-icons">folder_open</span>
				Pick a case to review
				<span class="ct-esub">Both accounts and the timeline are on the right.</span>
			</div>
		{:else}
			<div class="ct-dhead">
				<span class="ct-dno">{current.citation_number}</span>
				<span class="ct-dtype">{current.type === "parking" ? "Parking violation" : "Citation"}</span>
				<span class="ct-damount">${Number(current.fine_total).toLocaleString()}</span>
			</div>

			<div class="ct-grid">
				<div><span class="ct-l">Recipient</span>{current.recipient_name ?? "—"}</div>
				<div><span class="ct-l">Issued by</span>{current.officer_callsign ? current.officer_callsign + " " : ""}{current.officer_name}</div>
				<div><span class="ct-l">Location</span>{current.location ?? "—"}</div>
				{#if current.plate}<div><span class="ct-l">Vehicle</span>{current.plate} · {current.vehicle ?? "—"}</div>{/if}
				{#if current.speed_measured}
					<div><span class="ct-l">Speed</span>{current.speed_measured} in a {current.speed_limit ?? "—"}</div>
				{/if}
			</div>

			<div class="ct-sec">
				<span class="ct-l"><span class="material-icons">balance</span>Charges</span>
				{#each current.charges ?? [] as c}
					<div class="ct-charge"><span class="ct-code">{c.code}</span>{c.label}<span class="ct-fine">${Number(c.fine).toLocaleString()}</span></div>
				{/each}
			</div>

			{#if current.notes}
				<div class="ct-sec">
					<span class="ct-l"><span class="material-icons">sticky_note_2</span>Remark at the time</span>
					<div class="ct-quote">{current.notes}</div>
				</div>
			{/if}

			<!-- The timeline, from data we already hold. Not signing is itself
			     part of the account. -->
			<div class="ct-sec">
				<span class="ct-l"><span class="material-icons">schedule</span>Timeline</span>
				<div class="ct-time">
					<span>Issued {current.issued_at ?? "—"}</span>
					<span>{current.signed_at ? "Signed " + current.signed_at : "Never signed"}</span>
					<span>Contested {current.contested_at ?? "—"}</span>
					<span class:late={urgent(current)}>Decide by {current.contest_deadline ?? "—"}</span>
				</div>
			</div>

			<div class="ct-sec">
				<span class="ct-l"><span class="material-icons">person</span>The recipient's case</span>
				<div class="ct-quote">{current.contest_reason ?? "—"}</div>
			</div>

			<div class="ct-sec">
				<span class="ct-l"><span class="material-icons">local_police</span>The officer's account</span>
				{#if isDoj || current.officer_statement}
					<div class="ct-quote" class:missing={!current.officer_statement}>
						{current.officer_statement ?? "No statement filed. The officer was asked and has not answered."}
					</div>
				{/if}

				{#if !isDoj}
					<!-- Only the officer who wrote it can answer; the server
					     enforces that, this just avoids offering it to others. -->
					<textarea class="ct-area" rows="4" bind:value={statementDraft}
						placeholder="How did the stop go? The court reads this."></textarea>
					<button class="ct-btn" disabled={busy || !statementDraft.trim()} onclick={fileStatement}>
						{current.officer_statement ? "Update statement" : "File statement"}
					</button>
				{/if}
			</div>

			{#if isDoj}
				<div class="ct-verdict">
					<span class="ct-l"><span class="material-icons">gavel</span>Ruling</span>
					<textarea class="ct-area" rows="2" bind:value={verdictNote}
						placeholder="Reasoning (optional, shown on the citation)"></textarea>

					<div class="ct-reduce">
						<span class="ct-l">Reduced amount</span>
						<input class="ct-inp" type="number" bind:value={reducedFine} />
						<span class="ct-hint">a court may lower a fine, never raise it</span>
					</div>

					<div class="ct-acts">
						<button class="ct-btn dismiss" disabled={busy} onclick={() => rule("dismissed")}>Dismiss</button>
						<button class="ct-btn reduce" disabled={busy} onclick={() => rule("reduced")}>Reduce</button>
						<button class="ct-btn uphold" disabled={busy} onclick={() => rule("upheld")}>Uphold</button>
					</div>
				</div>
			{/if}

			{#if msg}<div class="ct-msg">{msg}</div>{/if}
		{/if}
	</div>
</div>

<style>
	/* Built from the MDT's own pieces — card surfaces, the same borders, the
	   accent variables — so it reads as part of the tablet rather than a page
	   that arrived from somewhere else. */
	.ct-page { display: flex; height: 100%; gap: 14px; padding: 14px; box-sizing: border-box; }

	/* ── The queue ──────────────────────────────────────────────────────── */
	.ct-list {
		width: 300px; flex-shrink: 0;
		display: flex; flex-direction: column;
		background: rgba(255, 255, 255, 0.022);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 10px; overflow: hidden;
	}
	.ct-list :global(> *:last-child) { overflow-y: auto; }
	.ct-head {
		display: flex; align-items: center; gap: 10px;
		padding: 13px 15px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		background: rgba(255, 255, 255, 0.015);
	}
	.ct-hicon { font-size: 19px; color: rgba(var(--accent-text-rgb), 0.8); }
	.ct-htext { display: flex; flex-direction: column; min-width: 0; }
	.ct-title { font-size: 13px; font-weight: 700; letter-spacing: 0.2px; color: rgba(255, 255, 255, 0.92); }
	.ct-hsub { font-size: 9px; color: rgba(255, 255, 255, 0.3); }
	.ct-count {
		margin-left: auto; min-width: 22px; padding: 3px 8px;
		border-radius: 10px;
		background: rgba(239, 68, 68, 0.18);
		border: 1px solid rgba(239, 68, 68, 0.3);
		color: #f87171; font-size: 11px; font-weight: 700; text-align: center;
	}
	.ct-count.zero {
		background: rgba(255, 255, 255, 0.05);
		border-color: rgba(255, 255, 255, 0.08);
		color: rgba(255, 255, 255, 0.35);
	}

	.ct-item {
		display: block; width: 100%; padding: 11px 15px;
		background: none; border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.04);
		text-align: left; cursor: pointer; transition: background 0.12s;
	}
	.ct-item:hover { background: rgba(255, 255, 255, 0.03); }
	.ct-item.sel { background: rgba(var(--accent-rgb), 0.1); box-shadow: inset 3px 0 0 rgba(var(--accent-rgb), 0.9); }
	/* Under a day. A lapsed challenge is dismissed, so this is the one the
	   court has to reach first — an edge says that faster than a word. */
	.ct-item.urgent { box-shadow: inset 3px 0 0 rgb(239, 68, 68); }
	.ct-item.urgent.sel { background: rgba(239, 68, 68, 0.08); }

	.ct-item-top { display: flex; align-items: baseline; gap: 8px; }
	.ct-no { font-family: "Courier New", monospace; font-size: 10px; letter-spacing: 0.4px; color: rgba(255, 255, 255, 0.4); }
	.ct-left {
		margin-left: auto; padding: 1px 6px; border-radius: 3px;
		background: rgba(var(--accent-rgb), 0.12);
		color: rgba(var(--accent-text-rgb), 0.9);
		font-size: 9px; font-weight: 700;
	}
	.ct-left.late { background: rgba(239, 68, 68, 0.16); color: #f87171; }
	.ct-who {
		margin-top: 3px; font-size: 13px; font-weight: 600;
		color: rgba(255, 255, 255, 0.9);
		overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
	}
	.ct-sub { margin-top: 1px; font-size: 10px; color: rgba(255, 255, 255, 0.35); }
	.ct-missing { color: rgba(251, 191, 36, 0.85); font-weight: 600; }

	/* ── The file ───────────────────────────────────────────────────────── */
	.ct-detail {
		flex: 1; min-width: 0; overflow-y: auto;
		padding: 18px 22px;
		background: rgba(255, 255, 255, 0.022);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 10px;
	}
	.ct-dhead {
		display: flex; align-items: baseline; gap: 12px;
		padding-bottom: 14px; margin-bottom: 18px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.07);
	}
	.ct-dno { font-family: "Courier New", monospace; font-size: 16px; font-weight: 700; letter-spacing: 0.5px; color: rgba(255, 255, 255, 0.92); }
	.ct-dtype { padding: 2px 8px; border-radius: 3px; background: rgba(255, 255, 255, 0.05); font-size: 10px; color: rgba(255, 255, 255, 0.45); }
	.ct-damount { margin-left: auto; font-size: 20px; font-weight: 700; color: rgba(255, 255, 255, 0.92); }

	.ct-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px 20px; margin-bottom: 20px; font-size: 12px; color: rgba(255, 255, 255, 0.85); }
	.ct-l {
		display: flex; align-items: center; gap: 5px; margin-bottom: 5px;
		font-size: 9px; font-weight: 700;
		text-transform: uppercase; letter-spacing: 0.9px;
		color: rgba(255, 255, 255, 0.32);
	}
	.ct-l :global(.material-icons) { font-size: 13px; opacity: 0.8; }

	.ct-sec { margin-bottom: 20px; }
	.ct-charge {
		display: flex; align-items: center; gap: 10px;
		padding: 6px 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.04);
		font-size: 12px; color: rgba(255, 255, 255, 0.85);
	}
	.ct-charge:last-child { border-bottom: none; }
	.ct-code {
		min-width: 76px; padding: 2px 7px; border-radius: 3px;
		background: rgba(255, 255, 255, 0.05);
		font-family: "Courier New", monospace; font-size: 9px; color: rgba(255, 255, 255, 0.55);
	}
	.ct-fine { margin-left: auto; font-weight: 600; color: rgba(255, 255, 255, 0.7); }

	/* Quoted, not paraphrased: both sides keep their own words on the record,
	   line breaks included. */
	.ct-quote {
		padding: 11px 13px;
		background: rgba(255, 255, 255, 0.028);
		border-left: 2px solid rgba(255, 255, 255, 0.14);
		border-radius: 0 4px 4px 0;
		font-size: 12px; line-height: 1.55;
		color: rgba(255, 255, 255, 0.82);
		white-space: pre-wrap;
	}
	.ct-quote.missing {
		border-left-color: rgba(251, 191, 36, 0.5);
		background: rgba(251, 191, 36, 0.05);
		color: rgba(251, 191, 36, 0.8);
		font-style: italic;
	}

	.ct-time { display: flex; flex-wrap: wrap; gap: 8px; }
	.ct-time span { padding: 4px 9px; border-radius: 4px; background: rgba(255, 255, 255, 0.04); font-size: 10px; color: rgba(255, 255, 255, 0.5); }
	.ct-time .late { background: rgba(239, 68, 68, 0.12); color: #f87171; font-weight: 700; }

	.ct-area {
		width: 100%; box-sizing: border-box; margin: 8px 0;
		padding: 10px; resize: vertical; min-height: 62px;
		background: rgba(0, 0, 0, 0.25);
		border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 5px;
		color: rgba(255, 255, 255, 0.9);
		font-family: inherit; font-size: 12px; line-height: 1.5;
		outline: none; transition: border-color 0.12s;
	}
	.ct-area:focus { border-color: rgba(var(--accent-rgb), 0.45); }
	.ct-area::placeholder { color: rgba(255, 255, 255, 0.22); }
	.ct-inp {
		width: 130px; padding: 7px 10px;
		background: rgba(0, 0, 0, 0.25);
		border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 5px;
		color: rgba(255, 255, 255, 0.9); font-size: 13px; font-weight: 600; outline: none;
	}
	.ct-inp:focus { border-color: rgba(var(--accent-rgb), 0.45); }
	.ct-hint { margin-left: 10px; font-size: 10px; color: rgba(255, 255, 255, 0.3); }

	.ct-verdict {
		margin-top: 4px; padding: 16px;
		background: rgba(0, 0, 0, 0.18);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 8px;
	}
	.ct-reduce { display: flex; align-items: center; margin: 10px 0 16px; }
	.ct-reduce .ct-l { margin: 0 10px 0 0; }
	.ct-acts { display: flex; gap: 8px; }
	.ct-btn {
		padding: 9px 20px;
		background: rgba(255, 255, 255, 0.06);
		border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 6px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 12px; font-weight: 700; cursor: pointer; transition: all 0.12s;
	}
	.ct-btn:hover:not(:disabled) { background: rgba(255, 255, 255, 0.1); }
	.ct-btn:disabled { opacity: 0.35; cursor: not-allowed; }
	.ct-btn.dismiss { background: rgba(16, 185, 129, 0.13); border-color: rgba(16, 185, 129, 0.3); color: #34d399; }
	.ct-btn.dismiss:hover:not(:disabled) { background: rgba(16, 185, 129, 0.22); }
	.ct-btn.reduce { background: rgba(251, 191, 36, 0.11); border-color: rgba(251, 191, 36, 0.28); color: #fcd34d; }
	.ct-btn.reduce:hover:not(:disabled) { background: rgba(251, 191, 36, 0.2); }
	/* Set apart on the right: dismissing and reducing are concessions, upholding
	   is the opposite, and it should not be hit by reflex. */
	.ct-btn.uphold { margin-left: auto; background: rgba(239, 68, 68, 0.11); border-color: rgba(239, 68, 68, 0.28); color: #f87171; }
	.ct-btn.uphold:hover:not(:disabled) { background: rgba(239, 68, 68, 0.2); }

	.ct-empty {
		display: flex; flex-direction: column; align-items: center; gap: 6px;
		padding: 34px 20px; text-align: center;
		font-size: 12px; color: rgba(255, 255, 255, 0.35);
	}
	.ct-empty.tall { padding-top: 90px; }
	.ct-empty :global(.material-icons) { font-size: 30px; opacity: 0.3; }
	.ct-esub { font-size: 10px; color: rgba(255, 255, 255, 0.22); }

	.ct-msg { margin-top: 12px; padding: 9px 12px; border-radius: 5px; background: rgba(239, 68, 68, 0.1); font-size: 11px; color: #f87171; }
</style>
