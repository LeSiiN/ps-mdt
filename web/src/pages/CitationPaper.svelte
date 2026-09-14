<script lang="ts">
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";

	// The carbon copy. Deliberately the same sheet the officer wrote on — an
	// officer should see exactly what the other person is holding.
	let {
		show = false,
		number = "",
		carbon = false,          // true = the officer's copy
		onClose = () => {},
	}: { show?: boolean; number?: string; carbon?: boolean; onClose?: () => void } = $props();

	type Row = {
		citation_number: string;
		type: "citation" | "parking" | "warning";
		recipient_name?: string;
		plate?: string;
		vehicle?: string;
		vehicle_color?: string;
		officer_name: string;
		officer_callsign?: string;
		officer_job?: string;
		location?: string;
		postal?: string;
		speed_measured?: number;
		speed_limit?: number;
		notes?: string;
		charges: Array<{ code: string; label: string; fine: number }>;
		fine_total: number;
		points_total: number;
		status: "open" | "paid" | "void" | "overdue";
		issued_at?: string;
		due_at?: string;
		signed_at?: string;
	};

	let row = $state<Row | null>(null);
	let busy = $state(false);
	let msg = $state("");
	let copied = $state(false);

	// Status is read fresh every time, never from item metadata. A slip written
	// yesterday must not claim "unpaid" after the fine was settled this morning.
	async function load() {
		row = null;
		msg = "";
		try {
			row = await fetchNui<Row>(NUI_EVENTS.CITATION.GET_CITATION, { number });
		} catch {
			msg = "Could not read this citation.";
		}
	}

	let wasShown = false;
	$effect(() => {
		if (show && !wasShown) {
			wasShown = true;
			load();
			fetchNui(NUI_EVENTS.CITATION.ANIM_READ, {}).catch(() => {});
		} else if (!show && wasShown) {
			wasShown = false;
			row = null;
			fetchNui(NUI_EVENTS.CITATION.ANIM_STOP, {}).catch(() => {});
		}
	});

	async function sign() {
		if (!row) return;
		busy = true;
		try {
			const res: any = await fetchNui(NUI_EVENTS.CITATION.SIGN_CITATION, { number });
			if (res?.success) await load();
			else msg = res?.error ?? "Could not sign.";
		} catch { msg = "Could not sign."; }
		busy = false;
	}


	function copyNote() {
		if (!row?.notes) return;
		try {
			const ta = document.createElement("textarea");
			ta.value = row.notes;
			ta.style.cssText = "position:fixed;opacity:0;";
			document.body.appendChild(ta);
			ta.select();
			document.execCommand("copy");
			ta.remove();
			copied = true;
			setTimeout(() => (copied = false), 1400);
		} catch { /* host blocked it */ }
	}

	function close() {
		fetchNui(NUI_EVENTS.CITATION.CLOSE_PAPER, {}).catch(() => {});
		onClose();
	}

	// Raw timestamps come back from the single-row query; the list query formats
	// them in SQL but this one does not, and a millisecond count is not a date.
	function fmt(v: any): string {
		if (!v) return "—";
		const d = typeof v === "number" ? new Date(v)
			: /^\d+$/.test(String(v)) ? new Date(Number(v))
			: new Date(String(v).replace(" ", "T"));
		if (isNaN(d.getTime())) return String(v);
		return d.toLocaleDateString() + " " +
			d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
	}

	// ESC closes it, the way every other overlay in the MDT does.
	function onKey(e: KeyboardEvent) {
		if (e.key === "Escape" && show) { e.preventDefault(); close(); }
	}
	$effect(() => {
		window.addEventListener("keydown", onKey);
		return () => window.removeEventListener("keydown", onKey);
	});

	const STATUS_LABEL: Record<string, string> = {
		open: "Unpaid", paid: "Paid", overdue: "Overdue", void: "Withdrawn",
	};
</script>

{#if show}
<div class="cc-overlay">
  <div class="cc-sheet" class:carbon={carbon}>
    <button class="cc-close" onclick={close}>✕</button>

    {#if carbon}
      <!-- Said out loud, because the two are the same sheet and an officer
           holding the wrong one would otherwise just find the buttons missing
           and assume it is broken. -->
      <div class="cc-kind">Carbon copy · department record · not the holder's copy</div>
    {/if}

    {#if !row}
      <div class="cc-empty">{msg || "Reading…"}</div>
    {:else}
      <!-- The one thing that decides whether this slip still matters. A
           warning has no money attached, so "unpaid" would be a lie — it says
           what it is instead. -->
      {#if row.type === "warning"}
        <div class="cc-status s-warning">Warning · no fine · recorded only</div>
      {:else}
        <div class="cc-status s-{row.status}">
          {STATUS_LABEL[row.status] ?? row.status}
          {#if row.status !== "paid" && row.due_at}· due {fmt(row.due_at)}{/if}
        </div>
      {/if}

      <div class="p-head">
        <div>
          <div class="p-state">STATE OF SAN ANDREAS</div>
          <div class="p-agency">{(row.officer_job ?? "Police Department").toUpperCase()}</div>
        </div>
        <div class="p-mid">
          <div class="p-title">{row.type === "parking" ? "PARKING VIOLATION" : row.type === "warning" ? "WRITTEN WARNING" : "NOTICE TO APPEAR"}</div>
          <div class="p-sub">Traffic Citation · Penal &amp; Vehicle Code</div>
        </div>
        <div class="p-no">
          <div class="p-no-l">CITATION NO.</div>
          <div class="p-no-v">{row.citation_number}</div>
          <div class="p-no-when">{fmt(row.issued_at)}</div>
        </div>
      </div>

      <div class="p-row">
        {#if row.type === "parking"}
          <div class="p-cell grow"><span class="p-l">Plate</span><span class="p-v mono">{row.plate || "—"}</span></div>
          {#if row.recipient_name}
            <div class="p-cell grow"><span class="p-l">Registered keeper</span><span class="p-v">{row.recipient_name}</span></div>
          {/if}
        {:else}
          <div class="p-cell grow"><span class="p-l">Name (last, first)</span><span class="p-v">{row.recipient_name || "—"}</span></div>
        {/if}
        <div class="p-cell"><span class="p-l">Date / time of violation</span><span class="p-v">{fmt(row.issued_at)}</span></div>
      </div>

      {#if row.vehicle || (row.type !== "parking" && row.plate)}
        <div class="p-row">
          {#if row.type !== "parking"}
            <div class="p-cell"><span class="p-l">Plate</span><span class="p-v mono">{row.plate || "—"}</span></div>
          {/if}
          <div class="p-cell grow"><span class="p-l">Make &amp; model</span><span class="p-v">{row.vehicle || "—"}</span></div>
          <div class="p-cell"><span class="p-l">Color</span><span class="p-v">{row.vehicle_color || "—"}</span></div>
        </div>
      {/if}

      <div class="p-row">
        <div class="p-cell grow"><span class="p-l">Location of violation</span><span class="p-v">{row.location || "—"}</span></div>
        {#if row.postal}<div class="p-cell"><span class="p-l">Postal</span><span class="p-v">{row.postal}</span></div>{/if}
      </div>

      {#if row.speed_measured || row.speed_limit}
        <div class="p-row">
          <div class="p-cell"><span class="p-l">Measured speed</span><span class="p-v">{row.speed_measured ?? "—"} mph</span></div>
          <div class="p-cell"><span class="p-l">Posted limit</span><span class="p-v">{row.speed_limit ?? "—"} mph</span></div>
          <div class="p-cell"><span class="p-l">Over by</span><span class="p-v">
            {row.speed_measured && row.speed_limit ? Math.max(0, row.speed_measured - row.speed_limit) + " mph" : "—"}
          </span></div>
        </div>
      {/if}

      <table class="p-table">
        <thead><tr>
          <th class="n">#</th><th>Code section</th><th>Description</th>
          {#if row.type !== "warning"}<th class="b">Bail</th>{/if}
        </tr></thead>
        <tbody>
          {#each row.charges ?? [] as c, i}
            <tr>
              <td class="n">{i + 1}</td>
              <td class="mono">{c.code}</td>
              <td>{c.label}</td>
              {#if row.type !== "warning"}<td class="b">${Number(c.fine).toLocaleString()}</td>{/if}
            </tr>
          {/each}
        </tbody>
        {#if row.type !== "warning"}
          <tfoot><tr>
            <td colspan="2">TOTAL</td>
            <td colspan="2" class="b">${Number(row.fine_total).toLocaleString()}</td>
          </tr></tfoot>
        {/if}
      </table>

      {#if row.notes}
        <div class="p-notes">
          <span class="p-l">Remark
            <button class="p-copy" title={copied ? "Copied" : "Copy remark"} onclick={copyNote}>
              <span class="material-icons">{copied ? "check" : "content_copy"}</span>
            </button>
          </span>{row.notes}
        </div>
      {/if}

      <div class="p-promise">Without admitting guilt, I promise to appear at the time and place checked below.</div>
      <div class="p-sign">
        <div class="p-sig">
          {#if row.signed_at}
            <span class="p-sig-name">{row.recipient_name ?? ""}</span>
          {:else if !carbon && row.status !== "void"}
            <!-- Signing happens on the line, because that is where a signature
                 goes. A button elsewhere asks you to find the action; this puts
                 it where you were already looking. -->
            <button class="p-sig-line sign" disabled={busy} onclick={sign}>
              <span class="sign-hint">{busy ? "Signing…" : "Click to sign"}</span>
            </button>
          {:else}
            <span class="p-sig-line"></span>
          {/if}
          <span class="p-l">Signature of defendant{#if row.signed_at} · {fmt(row.signed_at)}{:else} · not signed{/if}</span>
        </div>
        <div class="p-sig">
          <span class="p-sig-name">{row.officer_callsign ? row.officer_callsign + " " : ""}{row.officer_name}</span>
          <span class="p-l">Arresting / citing officer</span>
        </div>
      </div>

      {#if msg}<div class="cc-msg">{msg}</div>{/if}

      <!-- The officer's copy is a record; the recipient's is a thing to act on. -->
      {#if !carbon && row.status !== "paid" && row.status !== "void"}
      {/if}
    {/if}
  </div>
</div>
{/if}

<style>
	.cc-overlay {
		position: fixed; inset: 0; z-index: 210;
		display: flex; align-items: center; justify-content: center;
		padding: 24px; background: rgba(0,0,0,0.6);
	}
	.cc-sheet {
		position: relative;
		width: min(760px, 94vw);
		max-height: 88vh; overflow-y: auto;
		padding: 20px 24px;
		background: #f4f1e8; color: #17181c;
		border-radius: 6px;
		font-family: "Courier New", monospace; font-size: 13px; line-height: 1.45;
	}
	.cc-close {
		position: absolute; top: 10px; right: 12px;
		width: 22px; height: 22px; padding: 0;
		background: none; border: 1px solid rgba(0,0,0,0.2); border-radius: 3px;
		color: rgba(0,0,0,0.5); cursor: pointer;
	}
	.cc-empty { padding: 30px; text-align: center; opacity: 0.6; }

	/* Status band. Read first, because it decides whether the rest matters. */
	.cc-status {
		margin-bottom: 12px; padding: 6px 10px;
		border-radius: 3px; font-weight: 700; font-size: 12px;
		text-transform: uppercase; letter-spacing: 0.6px;
	}
	.s-open    { background: rgba(180,120,0,0.15);  color: #8a5a00; }
	.s-overdue { background: rgba(179,38,30,0.15);  color: #b3261e; }
	.s-paid    { background: rgba(20,120,70,0.15);  color: #147846; }
	.s-void    { background: rgba(0,0,0,0.06);      color: rgba(0,0,0,0.45); }
	/* Not a status at all — a statement of what the sheet is. */
	.s-warning { background: rgba(0,0,0,0.05); color: rgba(0,0,0,0.5); }

	.p-head { display: flex; align-items: flex-start; gap: 12px; padding-bottom: 8px; }
	.p-state { font-size: 10px; letter-spacing: 0.5px; }
	.p-agency { font-size: 15px; font-weight: 700; }
	.p-mid { flex: 1; text-align: center; }
	.p-title { font-size: 19px; font-weight: 700; letter-spacing: 1px; }
	.p-sub { font-size: 10px; }
	.p-no { text-align: right; }
	.p-no-l { font-size: 9px; letter-spacing: 0.5px; }
	.p-no-v { font-size: 14px; font-weight: 700; color: #b3261e; }
	.p-no-when { font-size: 10px; opacity: 0.7; }

	.p-row { display: flex; border: 1px solid #17181c; border-bottom: none; }
	.p-row:last-of-type { border-bottom: 1px solid #17181c; }
	.p-cell { flex: 1; min-width: 0; padding: 3px 8px; border-right: 1px solid #17181c; }
	.p-cell:last-child { border-right: none; }
	.p-cell.grow { flex: 2; }
	.p-l { display: block; font-size: 9px; text-transform: uppercase; letter-spacing: 0.4px; opacity: 0.65; }
	.p-v { display: block; font-size: 13px; min-height: 16px; }
	.mono { font-family: "Courier New", monospace; }

	.p-table { width: 100%; border-collapse: collapse; margin-top: 8px; }
	.p-table th, .p-table td { border: 1px solid #17181c; padding: 3px 8px; text-align: left; font-size: 11px; }
	.p-table th { font-size: 9px; text-transform: uppercase; letter-spacing: 0.4px; font-weight: 400; opacity: 0.7; }
	.p-table td { height: 18px; }
	.p-table .n { width: 24px; text-align: center; }
	.p-table .b { width: 86px; text-align: right; }
	.p-table tfoot td { font-weight: 700; }

	.p-notes { margin-top: 8px; padding: 6px 8px; border: 1px solid #17181c; font-size: 12px; }
	.p-copy {
		background: none; border: none; padding: 0 0 0 4px;
		color: inherit; opacity: 0.55; cursor: pointer; vertical-align: -3px;
	}
	.p-copy:hover { opacity: 1; }
	.p-copy .material-icons { font-size: 13px; }

	.p-promise { margin-top: 12px; text-align: center; font-size: 10px; }
	.p-sign { display: flex; gap: 18px; margin-top: 12px; }
	.p-sig { flex: 1; }
	.p-sig-line { display: block; height: 20px; border-bottom: 1px solid #17181c; }
	.p-sig-name {
		display: block; height: 20px;
		font-family: Georgia, "Times New Roman", serif;
		font-style: italic; font-size: 19px;
		border-bottom: 1px solid #17181c;
	}

	.cc-msg { margin-top: 10px; font-size: 11px; color: #b3261e; }
	.cc-actions { display: flex; gap: 8px; margin-top: 14px; }
	.cc-btn {
		flex: 1; padding: 9px;
		background: rgba(0,0,0,0.06); border: 1px solid rgba(0,0,0,0.2);
		border-radius: 4px; color: #17181c;
		font-family: inherit; font-size: 12px; font-weight: 700; cursor: pointer;
	}
	.cc-btn:hover:not(:disabled) { background: rgba(0,0,0,0.1); }
	.cc-btn:disabled { opacity: 0.45; cursor: not-allowed; }
	.cc-btn.pay { background: rgba(20,120,70,0.15); border-color: rgba(20,120,70,0.4); color: #147846; }

	/* The signature line, made clickable. It keeps the look of a ruled line —
	   the hint only appears on hover, so a signed sheet and a blank one read the
	   same at a glance. */
	button.p-sig-line.sign {
		width: 100%; padding: 0;
		background: none; border: none;
		border-bottom: 1px solid #17181c;
		cursor: pointer; text-align: left;
		transition: background 0.12s;
	}
	button.p-sig-line.sign:hover:not(:disabled) { background: rgba(20,120,70,0.1); }
	button.p-sig-line.sign:disabled { cursor: wait; }
	.sign-hint {
		font-family: Georgia, "Times New Roman", serif;
		font-style: italic; font-size: 13px;
		color: rgba(0,0,0,0.3);
		opacity: 0; transition: opacity 0.12s;
	}
	button.p-sig-line.sign:hover .sign-hint,
	button.p-sig-line.sign:disabled .sign-hint { opacity: 1; }

	/* The officer keeps a carbon: greyer stock, a stamped band across the top,
	   and no buttons. A record, not a thing to act on. */
	.cc-sheet.carbon { background: #e6e3da; }
	.cc-kind {
		margin: -4px 0 12px;
		padding: 5px 8px;
		border: 1px dashed rgba(0,0,0,0.35);
		border-radius: 3px;
		font-size: 10px; font-weight: 700;
		text-transform: uppercase; letter-spacing: 1px;
		color: rgba(0,0,0,0.5);
		text-align: center;
	}
</style>
