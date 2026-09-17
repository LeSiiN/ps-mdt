<script lang="ts">
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";
	import { formatDateTime } from "../utils/datetime";

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
	let hearingMsg = $state("");
	let hearingDate = $state("");
	let hearingTime = $state("10:00");

	// The server's format, not the browser's: MySQL wants one shape and the
	// display follows Config.TimeFormat / DateFormat like the rest of the MDT.
	let hearingPreview = $derived(
		hearingDate && hearingTime ? formatDateTime(`${hearingDate}T${hearingTime}:00`) : "",
	);

	// Suggested, not imposed: a day before the challenge lapses, because after
	// that the hearing would rule on something already decided.
	function suggestSlot(r: Contested) {
		const raw = r.contest_deadline;
		if (!raw) { hearingDate = ""; return; }
		const d = new Date(String(raw).replace(" ", "T"));
		if (isNaN(d.getTime())) { hearingDate = ""; return; }
		d.setDate(d.getDate() - 1);
		hearingDate = d.toISOString().slice(0, 10);
		hearingTime = "10:00";
	}

	// Both parties are already on the record, so listing a hearing should not
	// mean re-typing their names — a mistyped one is a hearing the wrong person
	// is summoned to.
	async function scheduleHearing() {
		if (!current) return;
		busy = true; hearingMsg = "";
		try {
			const res: any = await fetchNui(NUI_EVENTS.CITATION.HEARING_FROM_CONTEST, {
				number: current.citation_number,
				scheduled_at: `${hearingDate} ${hearingTime}:00`,
			});
			hearingMsg = res?.success
				? `Listed for ${formatDateTime(res.scheduledAt) || hearingPreview}`
				: (res?.error ?? "Could not list a hearing.");
		} catch { hearingMsg = "Could not list a hearing."; }
		busy = false;
		setTimeout(() => (hearingMsg = ""), 4000);
	}

	let current = $derived(rows.find(r => r.citation_number === selected) ?? null);

	// Anything that changes the queue tells the shell, so the tab badge follows
	// without waiting for its own poll. A count that lags behind the action you
	// just took reads as broken.
	function announce() {
		window.dispatchEvent(new CustomEvent("mdt:contests", { detail: rows.length }));
	}

	async function load() {
		loading = true;
		try {
			rows = (await fetchNui<Contested[]>(NUI_EVENTS.CITATION.GET_CONTESTED, {})) ?? [];
		} catch { rows = []; }
		loading = false;
		announce();
		if (selected && !rows.some(r => r.citation_number === selected)) selected = null;
	}

	$effect(() => { load(); });

	function pick(r: Contested) {
		selected = r.citation_number;
		statementDraft = r.officer_statement ?? "";
		verdictNote = "";
		reducedFine = Number(r.fine_total) || 0;
		suggestSlot(r);
		hearingMsg = "";
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
			<span class="material-icons ct-hicon">front_hand</span>
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

			<!-- The two accounts side by side. They answer the same question, and
			     a judge comparing them should not have to scroll between them. -->
			<div class="ct-both">
				<div class="ct-side">
					<span class="ct-l"><span class="material-icons">person</span>The recipient's case</span>
					<div class="ct-quote">{current.contest_reason ?? "—"}</div>
				</div>

				<div class="ct-side">
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

					<!-- Listing comes before ruling: a court that wants to hear
					     both sides schedules first and decides after. -->
					<div class="ct-hearing">
						<input class="ct-date" type="date" bind:value={hearingDate} />
						<input class="ct-date" type="time" bind:value={hearingTime} step="900" />
						<button class="ct-btn hearing" disabled={busy || !hearingDate} onclick={scheduleHearing}>
							<span class="material-icons">event</span> Schedule hearing
						</button>
						{#if hearingPreview && !hearingMsg}
							<span class="ct-hmsg">{hearingPreview}</span>
						{/if}
						{#if hearingMsg}<span class="ct-hmsg">{hearingMsg}</span>{/if}
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
	/* Surfaces come from the MDT's own variables. The earlier pass invented
	   translucent whites, which sat on whatever was behind them and made the
	   page look like it belonged to a different app. */
	.ct-page {
		display: flex; height: 100%;
		background: var(--card-dark-bg);
		color: rgba(255, 255, 255, 0.9);
	}

	/* ── The queue ──────────────────────────────────────────────────────── */
	.ct-list {
		width: 310px; flex-shrink: 0;
		display: flex; flex-direction: column;
		border-right: 1px solid rgba(255, 255, 255, 0.06);
		overflow-y: auto;
	}
	.ct-head {
		display: flex; align-items: center; gap: 11px;
		padding: 16px 18px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}
	.ct-hicon { font-size: 20px; color: var(--accent); }
	.ct-htext { display: flex; flex-direction: column; min-width: 0; }
	.ct-title { font-size: 14px; font-weight: 700; letter-spacing: -0.1px; color: #fff; }
	.ct-hsub { font-size: 10px; color: rgba(255, 255, 255, 0.3); }
	.ct-count {
		margin-left: auto; min-width: 24px; padding: 4px 9px;
		border-radius: 11px;
		background: rgba(239, 68, 68, 0.16);
		border: 1px solid rgba(239, 68, 68, 0.28);
		color: #f87171; font-size: 11px; font-weight: 700; text-align: center;
	}
	.ct-count.zero {
		background: rgba(255, 255, 255, 0.04);
		border-color: rgba(255, 255, 255, 0.07);
		color: rgba(255, 255, 255, 0.3);
	}

	.ct-item {
		position: relative; display: block; width: 100%;
		padding: 14px 18px 14px 21px;
		background: none; border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.04);
		text-align: left; cursor: pointer;
		transition: background 0.14s;
	}
	/* The urgency stripe is its own element rather than a box-shadow, so it can
	   sit flush and the selected state can change the fill behind it. */
	.ct-item::before {
		content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
		background: rgba(255, 255, 255, 0.08);
		transition: background 0.14s;
	}
	.ct-item:hover { background: rgba(255, 255, 255, 0.025); }
	.ct-item.sel { background: var(--accent-06); }
	.ct-item.sel::before { background: var(--accent); }
	/* Under a day left. A lapsed challenge is dismissed, so this is the one the
	   court has to reach first. */
	.ct-item.urgent::before { background: rgb(239, 68, 68); }

	.ct-item-top { display: flex; align-items: center; gap: 8px; }
	.ct-no {
		font-family: "Courier New", monospace;
		font-size: 10px; letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.35);
	}
	.ct-left {
		margin-left: auto; padding: 2px 7px; border-radius: 10px;
		background: var(--pill-blue-bg); border: 1px solid var(--pill-blue-border);
		color: rgba(var(--accent-text-rgb), 1);
		font-size: 9px; font-weight: 700; letter-spacing: 0.2px;
	}
	.ct-left.late { background: rgba(239, 68, 68, 0.16); border-color: rgba(239, 68, 68, 0.3); color: #f87171; }
	.ct-who {
		margin-top: 5px; font-size: 14px; font-weight: 600; letter-spacing: -0.1px;
		color: rgba(255, 255, 255, 0.92);
		overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
	}
	.ct-sub { margin-top: 2px; font-size: 11px; color: rgba(255, 255, 255, 0.32); }
	.ct-missing { color: #fbbf24; font-weight: 600; }

	/* ── The file ───────────────────────────────────────────────────────── */
	.ct-detail { flex: 1; min-width: 0; overflow-y: auto; padding: 22px 26px 30px; }

	.ct-dhead {
		display: flex; align-items: center; gap: 12px;
		padding-bottom: 18px; margin-bottom: 22px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.07);
	}
	.ct-dno {
		font-family: "Courier New", monospace;
		font-size: 17px; font-weight: 700; letter-spacing: 0.5px; color: #fff;
	}
	.ct-dtype {
		padding: 3px 9px; border-radius: 11px;
		background: rgba(255, 255, 255, 0.05);
		font-size: 10px; font-weight: 600; color: rgba(255, 255, 255, 0.45);
	}
	.ct-damount {
		margin-left: auto;
		font-size: 24px; font-weight: 700; letter-spacing: -0.5px; color: #fff;
	}

	/* Facts read as a row of small labelled values, not as prose. */
	.ct-grid {
		display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
		gap: 1px; margin-bottom: 22px;
		background: rgba(255, 255, 255, 0.05);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 8px; overflow: hidden;
	}
	.ct-grid > div {
		padding: 11px 14px;
		background: var(--card-dark-bg);
		font-size: 13px; color: rgba(255, 255, 255, 0.88);
	}
	.ct-l {
		display: flex; align-items: center; gap: 6px; margin-bottom: 6px;
		font-size: 9px; font-weight: 700;
		text-transform: uppercase; letter-spacing: 1px;
		color: rgba(255, 255, 255, 0.3);
	}
	.ct-l :global(.material-icons) { font-size: 13px; }

	.ct-sec { margin-bottom: 22px; }
	.ct-charge {
		display: flex; align-items: center; gap: 12px;
		padding: 9px 12px; margin-bottom: 4px;
		background: rgba(255, 255, 255, 0.022);
		border-radius: 6px;
		font-size: 13px; color: rgba(255, 255, 255, 0.88);
	}
	.ct-code {
		min-width: 78px; padding: 3px 8px; border-radius: 4px;
		background: rgba(0, 0, 0, 0.3);
		font-family: "Courier New", monospace; font-size: 9px;
		color: rgba(255, 255, 255, 0.5);
	}
	.ct-fine { margin-left: auto; font-weight: 700; color: rgba(255, 255, 255, 0.75); }

	/* The two accounts, side by side and equal height. They answer the same
	   question, and a judge comparing them should not have to scroll. */
	.ct-both { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 22px; }
	.ct-side { min-width: 0; display: flex; flex-direction: column; }
	.ct-quote {
		flex: 1; padding: 14px 16px;
		background: rgba(255, 255, 255, 0.022);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 8px;
		font-size: 13px; line-height: 1.6;
		color: rgba(255, 255, 255, 0.82);
		white-space: pre-wrap;
	}
	.ct-quote.missing {
		background: rgba(251, 191, 36, 0.05);
		border-color: rgba(251, 191, 36, 0.18);
		color: rgba(251, 191, 36, 0.8);
		font-style: italic;
	}

	/* The timeline is a track, because that is what it is. */
	.ct-time { display: flex; flex-wrap: wrap; align-items: center; gap: 0; }
	.ct-time span {
		position: relative; padding: 6px 16px 6px 0;
		font-size: 11px; color: rgba(255, 255, 255, 0.45);
	}
	.ct-time span:not(:last-child)::after {
		content: ""; position: absolute; right: 7px; top: 50%;
		width: 3px; height: 3px; border-radius: 50%;
		background: rgba(255, 255, 255, 0.2); transform: translateY(-50%);
	}
	.ct-time .late { color: #f87171; font-weight: 700; }

	.ct-area {
		width: 100%; box-sizing: border-box; margin: 10px 0;
		padding: 12px; resize: vertical; min-height: 84px;
		background: rgba(0, 0, 0, 0.28);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 8px;
		color: rgba(255, 255, 255, 0.9);
		font-family: inherit; font-size: 13px; line-height: 1.55;
		outline: none; transition: border-color 0.14s;
	}
	.ct-area:focus { border-color: rgba(var(--accent-rgb), 0.45); }
	.ct-area::placeholder { color: rgba(255, 255, 255, 0.2); }
	.ct-inp {
		width: 140px; padding: 9px 12px;
		background: rgba(0, 0, 0, 0.28);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 8px;
		color: #fff; font-size: 15px; font-weight: 700; outline: none;
	}
	.ct-inp:focus { border-color: rgba(var(--accent-rgb), 0.45); }
	.ct-hint { margin-left: 12px; font-size: 10px; color: rgba(255, 255, 255, 0.28); }

	.ct-verdict {
		margin-top: 8px; padding: 20px;
		background: rgba(0, 0, 0, 0.22);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 10px;
	}
	.ct-reduce { display: flex; align-items: center; margin: 12px 0 18px; }
	.ct-reduce .ct-l { margin: 0 12px 0 0; }
	.ct-hearing {
		display: flex; align-items: center; gap: 12px;
		padding-bottom: 16px; margin-bottom: 16px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}
	.ct-btn.hearing {
		gap: 7px;
		background: var(--pill-blue-bg);
		border-color: var(--pill-blue-border);
		color: rgba(var(--accent-text-rgb), 1);
	}
	.ct-btn.hearing:hover:not(:disabled) { background: rgba(var(--accent-rgb), 0.3); }
	.ct-btn.hearing :global(.material-icons) { font-size: 16px; }
	.ct-hmsg { font-size: 11px; color: rgba(255, 255, 255, 0.5); }
	.ct-date {
		padding: 9px 11px;
		background: rgba(0, 0, 0, 0.28);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 8px;
		color: #fff; font-family: inherit; font-size: 12px; font-weight: 600;
		outline: none; color-scheme: dark;
	}
	.ct-date:focus { border-color: rgba(var(--accent-rgb), 0.45); }

	.ct-acts { display: flex; gap: 10px; }
	.ct-btn {
		display: inline-flex; align-items: center; justify-content: center;
		padding: 11px 24px;
		background: rgba(255, 255, 255, 0.05);
		border: 1px solid rgba(255, 255, 255, 0.09);
		border-radius: 8px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 12px; font-weight: 700; letter-spacing: 0.2px;
		cursor: pointer; transition: all 0.14s;
	}
	.ct-btn:hover:not(:disabled) { background: rgba(255, 255, 255, 0.09); transform: translateY(-1px); }
	.ct-btn:disabled { opacity: 0.3; cursor: not-allowed; }
	.ct-btn.dismiss { background: rgba(16, 185, 129, 0.12); border-color: rgba(16, 185, 129, 0.28); color: #34d399; }
	.ct-btn.dismiss:hover:not(:disabled) { background: rgba(16, 185, 129, 0.2); }
	.ct-btn.reduce { background: rgba(251, 191, 36, 0.1); border-color: rgba(251, 191, 36, 0.26); color: #fcd34d; }
	.ct-btn.reduce:hover:not(:disabled) { background: rgba(251, 191, 36, 0.18); }
	/* Set apart on the right: dismissing and reducing are concessions,
	   upholding is the opposite, and it should not be hit by reflex. */
	.ct-btn.uphold { margin-left: auto; background: rgba(239, 68, 68, 0.1); border-color: rgba(239, 68, 68, 0.26); color: #f87171; }
	.ct-btn.uphold:hover:not(:disabled) { background: rgba(239, 68, 68, 0.18); }

	.ct-empty {
		display: flex; flex-direction: column; align-items: center; gap: 8px;
		padding: 40px 24px; text-align: center;
		font-size: 13px; color: rgba(255, 255, 255, 0.35);
	}
	.ct-empty.tall { padding-top: 120px; }
	.ct-empty :global(.material-icons) { font-size: 34px; opacity: 0.22; }
	.ct-esub { font-size: 11px; color: rgba(255, 255, 255, 0.22); }

	.ct-msg {
		margin-top: 14px; padding: 11px 14px; border-radius: 8px;
		background: rgba(239, 68, 68, 0.1);
		border: 1px solid rgba(239, 68, 68, 0.2);
		font-size: 12px; color: #f87171;
	}
</style>
