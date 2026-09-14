<script lang="ts">
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";
	import type { Charge } from "../interfaces/ICharges";

	// A standalone overlay, not a tab. `type` presets which kind of ticket the
	// command opened, and the officer can still switch.
	let {
		show = false,
		type = "citation",
		onClose = () => {},
	}: { show?: boolean; type?: "citation" | "parking" | "warning"; onClose?: () => void } = $props();

	type TicketType = "citation" | "parking" | "warning";
	type Position = { code: string; label: string; fine: number; points: number };

	// Which kind of ticket this is comes from the command that opened the form
	// and cannot be changed here. Switching mid-write would silently invalidate
	// the charges already picked, since the two types allow different laws.
	let ticketType = $derived<TicketType>(
		type === "parking" ? "parking" : type === "warning" ? "warning" : "citation");
	let charges = $state<Charge[]>([]);
	let search = $state("");
	let positions = $state<Position[]>([]);

	// Form fields. Location, plate and vehicle arrive from the client; measured
	// and posted speed are the officer's own observation and stay manual.
	let location = $state("");
	let postal = $state("");
	let plate = $state("");
	let vehicle = $state("");
	let vehicleColor = $state("");
	let speedMeasured = $state<number | null>(null);
	let speedLimit = $state<number | null>(null);
	let notes = $state("");

	let recipientId = $state("");
	let recipientName = $state("");

	let saving = $state(false);
	let closing = $state(false);
	let copiedNote = $state(false);

	// Pulled from the radar rather than typed from memory. Offered, not
	// inserted silently: the officer still decides what goes on the ticket.
	let radarMsg = $state("");
	async function pullRadar() {
		radarMsg = "";
		try {
			const res: any = await fetchNui(NUI_EVENTS.CITATION.GET_RADAR_SPEED, {});
			if (res?.ok) {
				speedMeasured = res.speed;
				// A reading that belongs to a different plate than the one on
				// the ticket is worth saying out loud, not quietly accepting.
				if (res.plate && plate && res.plate !== plate) {
					radarMsg = `Reading is for ${res.plate}`;
				}
			} else {
				radarMsg = res?.message ?? "No reading available";
			}
		} catch {
			radarMsg = "No reading available";
		}
		setTimeout(() => (radarMsg = ""), 3000);
	}
	// navigator.clipboard needs a secure context, which the NUI is not.
	function copyNote() {
		try {
			const ta = document.createElement("textarea");
			ta.value = notes;
			ta.style.cssText = "position:fixed;opacity:0;";
			document.body.appendChild(ta);
			ta.select();
			document.execCommand("copy");
			ta.remove();
			copiedNote = true;
			setTimeout(() => (copiedNote = false), 1400);
		} catch { /* host blocked it */ }
	}
	let error = $state("");
	let issued = $state<{ number: string; fine: number } | null>(null);

	const MAX_POSITIONS = 5;

	const flagOn = (v: unknown) => v === true || v === 1 || v === "1";

	// Shown on the paper. The officer's own name comes from the profile the MDT
	// already knows; the date is the moment the form is open, which is close
	// enough to the moment it is signed.
	let officerName = $state("");
	let agency = $state("Police Department");

	// Recipient picker. Who is standing there, or which car is parked there —
	// picked from what is actually present rather than typed from memory.
	type Target = {
		kind: "person" | "vehicle";
		serverId?: number;
		citizenid?: string;
		plate?: string;
		label?: string;
		model?: string;
		owner?: string;
		color?: string;
		image?: string;
		distance: number;
	};
	// Stage 1 until somebody is picked, stage 2 once they are. A parking ticket
	// skips ahead: the nearest car is picked automatically.
	let stage = $state<"pick" | "write">("pick");
	let hasPostal = $state(false);
	let targets = $state<Target[]>([]);
	// Kept so the recipient can play the receiving half of the handover.
	let selectedServerId = $state<number | null>(null);
	let loadingTargets = $state(false);

	async function loadTargets() {
		loadingTargets = true;
		try {
			targets = (await fetchNui<Target[]>(NUI_EVENTS.CITATION.GET_TICKET_TARGETS, { type: ticketType })) ?? [];
		} catch { targets = []; }
		loadingTargets = false;
	}

	// The writing pose belongs to the writing, not to standing there deciding
	// who it is for. It starts when the form does.
	$effect(() => {
		// Both conditions, and a cleanup. Without the `show` check the pose
		// restarted on the way out: closing resets the stage, and the effect
		// re-ran against a form that was already gone.
		if (!show || stage !== "write") return;
		fetchNui(NUI_EVENTS.CITATION.ANIM_START, {}).catch(() => {});
		return () => { fetchNui(NUI_EVENTS.CITATION.ANIM_STOP, {}).catch(() => {}); };
	});

	function pick(t: Target) {
		if (t.kind === "person") {
			recipientId = t.citizenid ?? "";
			recipientName = t.label ?? "";
			selectedServerId = t.serverId ?? null;
		} else {
			plate = t.plate ?? "";
			vehicle = t.label ?? "";
			vehicleColor = t.color ?? vehicleColor;
			// The picker already resolved who the plate belongs to, so the
			// paper can name them while it is being written rather than only
			// after the server looks it up again at issue time.
			recipientName = t.owner ?? "";
			recipientId = t.citizenid ?? "";
		}
		stage = "write";
	}

	// A citation may have nothing to do with a car, so it starts without one.
	// This attaches it deliberately — and only then does the paper show the
	// vehicle boxes at all.
	let vehicleChoices = $state<Target[]>([]);
	let pickingVehicle = $state(false);

	async function attachVehicle() {
		pickingVehicle = true;
		try {
			vehicleChoices = (await fetchNui<Target[]>(NUI_EVENTS.CITATION.GET_TICKET_TARGETS, { type: "parking" })) ?? [];
		} catch { vehicleChoices = []; }
	}

	function chooseVehicle(t: Target) {
		plate = t.plate ?? "";
		vehicle = t.label ?? "";
		vehicleColor = t.color ?? "";
		pickingVehicle = false;
	}
	// Note: attaching a vehicle to a CITATION deliberately does not change the
	// recipient. The person is the subject there; the car is a detail.

	function clearVehicle() {
		plate = ""; vehicle = ""; vehicleColor = "";
	}

	let hasVehicle = $derived(!!(plate || vehicle));
	let now = $state("");
	// Fires on open and on close, and on nothing else. The previous version
	// depended on every value it touched, so it re-ran while the officer typed —
	// restarting the animation each time and never reaching its own cleanup.
	let wasShown = false;
	$effect(() => {
		if (show && !wasShown) {
			wasShown = true;
			// Always start from scratch: a new command means a new ticket, not
			// the leftovers of the last one.
			reset();
			// Stamped when the form opens, and left alone after that: the time
			// on the paper should be when the ticket was written, not a clock
			// that keeps ticking while the officer types.
			const d = new Date();
			now = d.toLocaleDateString() + " " +
				d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
			loadContext();
			loadTargets();
			loadCharges();
		} else if (!show && wasShown) {
			wasShown = false;
			fetchNui(NUI_EVENTS.CITATION.ANIM_STOP, {}).catch(() => {});
		}
	});

	// Only laws flagged for this ticket type. A felony has no business on a
	// parking ticket, and the flags are how that is decided.
	let available = $derived(
		charges.filter((c) =>
			// The driver may send a boolean, a number or a string; Number(true)
			// is NaN, so this cannot go through Number() alone.
			flagOn(ticketType === "parking" ? c.in_parking : c.in_citation),
		),
	);

	let filtered = $derived.by(() => {
		const q = search.trim().toLowerCase();
		if (!q) return available;
		return available.filter(
			(c) =>
				(c.code ?? "").toLowerCase().includes(q) ||
				c.label.toLowerCase().includes(q),
		);
	});

	// A warning draws on the same laws but never carries money.
	// Decided at the end, not at the start: a switch part-way through would
	// quietly turn a $500 ticket into nothing, and that is a decision, not a
	// formatting choice. Both buttons draw on the same charges.
	let asWarning = $state(false);
	let isWarning = $derived(asWarning);
	let fineTotal = $derived(positions.reduce((s, p) => s + (p.fine || 0), 0));
	let pointsTotal = $derived(positions.reduce((s, p) => s + (p.points || 0), 0));
	let full = $derived(positions.length >= MAX_POSITIONS);

	function isPicked(code?: string) {
		return positions.some((p) => p.code === code);
	}

	// Clicking a law toggles it. Picking the same one twice is a slip, not an
	// intent to charge it twice.
	function toggle(charge: Charge) {
		const code = charge.code ?? charge.label;
		const at = positions.findIndex((p) => p.code === code);
		if (at !== -1) {
			positions = positions.filter((_, i) => i !== at);
			return;
		}
		if (full) return;
		positions = [
			...positions,
			{
				code,
				label: charge.label,
				fine: Number(charge.fine) || 0,
				// Points aren't a penal-code column; a fine of this size is one
				// point. Servers that want their own scale can change this line.
				points: 1,
			},
		];
	}

	async function loadCharges() {
		try {
			charges = (await fetchNui<Charge[]>(NUI_EVENTS.CITATION.GET_TICKET_CHARGES)) ?? [];
		} catch {
			charges = [];
		}
	}

	// Re-read the surroundings whenever the ticket type changes: a parking
	// ticket looks further for a vehicle than a citation does.
	async function loadContext() {
		try {
			const ctx = await fetchNui<any>(NUI_EVENTS.CITATION.GET_TICKET_CONTEXT, {
				type: ticketType,
			});
			if (!ctx) return;
			location = ctx.location ?? location;
			postal = ctx.postal ?? postal;
			hasPostal = ctx.hasPostal === true;
			if (ctx.vehicleColor) vehicleColor = ctx.vehicleColor;
			if (ctx.agency) agency = ctx.agency;
			if (ctx.officerName) officerName = ctx.officerName;
			if (ctx.plate) plate = ctx.plate;
			if (ctx.vehicle) vehicle = ctx.vehicle;
		} catch { /* the officer can still type it */ }
	}


	// Everything, not just the charges. Reopening the form after a close used
	// to keep the previous recipient and vehicle, which is how the wrong person
	// gets ticketed.
	function closeForm() {
		fetchNui(NUI_EVENTS.CITATION.CLOSE_TICKET_FORM, {}).catch(() => {});
		reset();
		onClose();
	}

	function reset() {
		stage = "pick";
		positions = [];
		notes = "";
		speedMeasured = null;
		speedLimit = null;
		recipientId = "";
		recipientName = "";
		selectedServerId = null;
		plate = "";
		vehicle = "";
		vehicleColor = "";
		location = "";
		postal = "";
		search = "";
		targets = [];
		vehicleChoices = [];
		pickingVehicle = false;
		issued = null;
		error = "";
		closing = false;
	}

	async function submit(warning = false) {
		asWarning = warning;
		error = "";
		if (positions.length === 0) {
			error = "No charge selected — pick at least one from the list above.";
			return;
		}
		if (ticketType === "parking" && !plate.trim()) {
			error = "No plate on this parking ticket. Pick the vehicle again — none was found nearby.";
			return;
		}
		if (ticketType === "citation" && !recipientId) {
			error = "No recipient — close the form and pick the person again.";
			return;
		}
		if (!warning && fineTotal <= 0) {
			error = "Every selected charge carries a $0 fine. Set an amount in the Charges tab first.";
			return;
		}

		saving = true;
		try {
			const res = await fetchNui<any>(NUI_EVENTS.CITATION.CREATE_CITATION, {
				type: warning ? "warning" : ticketType,
				citizenid: recipientId.trim() || null,
				recipientName: recipientName.trim() || null,
				plate: plate.trim() || null,
				vehicle: vehicle.trim() || null,
				vehicleColor: vehicleColor.trim() || null,
				location: location.trim() || null,
				postal: postal.trim() || null,
				speedMeasured,
				speedLimit,
				notes: notes.trim() || null,
				charges: positions,
			});
			if (res?.success) {
				issued = { number: res.number, fine: res.fine };
				positions = [];
				// Handed over, or put on the windscreen. Fire and forget: the
				// officer already has their confirmation.
				fetchNui(NUI_EVENTS.CITATION.ANIM_DELIVER, {
					type: ticketType,
					targetServerId: selectedServerId,
				}).catch(() => {});
				// Fade out rather than vanish: the handover is the point of the
				// whole thing, and closing on the same frame hides it.
				closing = true;
				setTimeout(() => { closing = false; closeForm(); }, 1500);

				// Hold the confirmation up for a beat, then fade out — the
				// handover happens in front of the officer and closing on the
				// same frame meant nobody ever saw it.
				closing = true;
				setTimeout(() => closeForm(), 2400);
			} else {
				// The server knows exactly what was wrong; saying so beats a
				// generic failure the officer has to guess at.
				error = res?.error ?? "The server rejected the ticket without giving a reason.";
			}
		} catch (e) {
			error = "The form could not reach the server — is ps-mdt still running?";
		} finally {
			saving = false;
		}
	}
</script>

{#if show && stage === "pick"}
<!-- Stage 1: who, or which car. Wide and short so it reads as a step, not as
     a second window competing with the form. -->
<div class="cit-overlay">
  <div class="pick-bar">
    <div class="pick-head">
      <span class="pick-title">{ticketType === "parking" ? "Which vehicle?" : "Who is this for?"}</span>
      <span class="pick-sub">{ticketType === "parking" ? "Vehicles nearby" : "People nearby"}</span>
      <button class="icon-btn" title="Refresh" onclick={loadTargets}><span class="material-icons">refresh</span></button>
      <button class="cit-close" onclick={closeForm}>✕</button>
    </div>
    <div class="pick-row">
      {#if loadingTargets}
        <div class="empty">Looking around…</div>
      {:else if targets.length === 0}
        <div class="empty">{ticketType === "parking" ? "No vehicle within range." : "Nobody within range."}</div>
      {:else}
        {#each targets as t}
          <button class="tgt" onclick={() => pick(t)}>
            {#if t.kind === "person"}
              {#if t.image}<img class="tgt-img" src={t.image} alt="" />
              {:else}<span class="tgt-img tgt-fallback">{(t.label ?? "?").slice(0, 1)}</span>{/if}
            {:else}
              {#if t.image}
                    <img class="tgt-img veh" src={t.image} alt="" />
                  {:else}
                    <span class="tgt-img tgt-fallback"><span class="material-icons">directions_car</span></span>
                  {/if}
            {/if}
            <span class="tgt-name">{t.kind === "person" ? (t.label ?? "Unknown") : (t.plate ?? "—")}</span>
            <span class="tgt-sub">{t.kind === "vehicle" ? (t.label ?? "") : ""}</span>
            <span class="tgt-dist">{t.distance} m</span>
          </button>
        {/each}
      {/if}
    </div>
  </div>
</div>
{/if}

{#if show && stage === "write"}
<div class="cit-overlay" class:closing>
  <div class="cit-shell">

    <!-- Left: the form -->
    <div class="cit-form">
      <div class="cit-head">
        <span class="cit-title">{ticketType === "parking" ? "Parking ticket" : "Citation"}</span>
        <span class="cit-sub">{ticketType === "parking" ? "Parking Violation" : "Notice to Appear"}</span>
        <button class="cit-close" onclick={() => { fetchNui(NUI_EVENTS.CITATION.CLOSE_TICKET_FORM, {}).catch(() => {}); onClose(); }}>✕</button>
      </div>

      <div class="cit-scroll">
        <div class="lbl">Add charge</div>
        <input class="inp" placeholder="Search — code or name" bind:value={search} />

        <div class="charge-list">
          {#each filtered as c (c.code ?? c.label)}
            <button class="charge-row" class:picked={isPicked(c.code ?? c.label)}
              disabled={full && !isPicked(c.code ?? c.label)} onclick={() => toggle(c)}>
              <span class="charge-code" style="border-left-color:{c.color ?? '#6b7280'}">{c.code ?? "—"}</span>
              <span class="charge-label">{c.label}</span>
              <span class="charge-fine">${Number(c.fine ?? 0).toLocaleString()}</span>
            </button>
          {/each}
          {#if filtered.length === 0}
            <div class="empty">
              {#if available.length === 0}
                No laws are marked for {ticketType === "parking" ? "parking tickets" : "citations"} yet — set that in the Charges tab.
              {:else}Nothing matches that search.{/if}
            </div>
          {/if}
        </div>

        <div class="lbl">Positions <span class="hint">max {MAX_POSITIONS}</span></div>
        {#if positions.length === 0}
          <div class="empty">No charge selected yet.</div>
        {:else}
          <div class="pos-list">
            {#each positions as p, i}
              <!-- No remove button: the law list above is the toggle, and two
                   ways to undo the same thing is one too many. -->
              <div class="pos-row">
                <span class="pos-n">{i + 1}</span>
                <span class="pos-label">{p.label}</span>
                <span class="pos-fine">${p.fine.toLocaleString()}</span>
              </div>
            {/each}
          </div>
        {/if}

        <div class="who">
          <span class="lbl">Issued to</span>
          <span class="who-name">
            {#if ticketType === "parking"}
              {plate || "—"}{#if recipientName} · {recipientName}{/if}
            {:else}
              {recipientName || "—"}
            {/if}
          </span>
        </div>

        <div class="grid2">
          <label class="fld"><span class="lbl">Location</span><input class="inp" bind:value={location} /></label>
          {#if hasPostal}
            <label class="fld"><span class="lbl">Postal</span><input class="inp" bind:value={postal} /></label>
          {/if}
        </div>

        <!-- A citation need not involve a car. It shows up on the paper only
             once one is attached, so a public-order ticket isn't left with
             empty vehicle boxes. -->
        <div class="lbl">
          Vehicle
          {#if hasVehicle}
            <button class="icon-btn" title="Remove vehicle" onclick={clearVehicle}><span class="material-icons">link_off</span></button>
          {:else}
            <button class="icon-btn" title="Attach a nearby vehicle" onclick={attachVehicle}><span class="material-icons">directions_car</span></button>
          {/if}
        </div>

        {#if pickingVehicle}
          <div class="pick-row inline">
            {#if vehicleChoices.length === 0}
              <div class="empty">No vehicle within range.</div>
            {:else}
              {#each vehicleChoices as v}
                <button class="tgt" onclick={() => chooseVehicle(v)}>
                  {#if v.image}
                    <img class="tgt-img veh" src={v.image} alt="" />
                  {:else}
                    <span class="tgt-img tgt-fallback"><span class="material-icons">directions_car</span></span>
                  {/if}
                  <span class="tgt-name">{v.plate}</span>
                  <span class="tgt-sub">{v.label}</span>
                  <span class="tgt-dist">{v.distance} m</span>
                </button>
              {/each}
            {/if}
          </div>
        {:else if hasVehicle}
          <div class="grid3">
            <label class="fld"><span class="lbl">Plate</span><input class="inp mono" bind:value={plate} /></label>
            <label class="fld"><span class="lbl">Make &amp; model</span><input class="inp" bind:value={vehicle} /></label>
            <label class="fld"><span class="lbl">Color</span><input class="inp" bind:value={vehicleColor} /></label>
          </div>
          {#if ticketType === "citation"}
            <div class="grid3">
              <label class="fld">
                <span class="lbl">Measured (mph)
                  <button class="icon-btn" title="Take the last radar reading" onclick={pullRadar}>
                    <span class="material-icons">speed</span>
                  </button>
                </span>
                <input class="inp" type="number" bind:value={speedMeasured} />
              </label>
              <label class="fld"><span class="lbl">Limit (mph)</span><input class="inp" type="number" bind:value={speedLimit} /></label>
              <span></span>
            </div>
          {/if}
        {:else}
          <div class="empty small">No vehicle attached — the ticket will not mention one.</div>
        {/if}

        <label class="fld"><span class="lbl">Remark <span class="hint">optional</span></span>
          <textarea class="inp ta" rows="2" bind:value={notes}></textarea></label>

        {#if radarMsg}<div class="msg warn">{radarMsg}</div>{/if}
        {#if error}<div class="msg err">{error}</div>{/if}
        {#if issued}<div class="msg ok">Issued {issued.number} · ${issued.fine.toLocaleString()}</div>{/if}
      </div>

      <div class="cit-foot">
        <div class="tot">
          <span class="tot-l">Total</span>
          <span class="tot-v">${fineTotal.toLocaleString()}</span>
        </div>
        {#if issued}
          <button class="btn" onclick={reset}>New ticket</button>
        {:else}
          {#if ticketType !== "parking"}
            <!-- A warning is the same paperwork with the fine dropped, so it
                 belongs beside the issue button rather than behind its own
                 command. -->
            <button class="btn warn" disabled={saving || positions.length === 0}
              onclick={() => submit(true)}>
              Warning only
            </button>
          {/if}
          <button class="btn primary" disabled={saving || positions.length === 0}
            onclick={() => submit(false)}>
            {saving ? "Issuing…" : "Sign & issue"}
          </button>
        {/if}
      </div>
    </div>

    <!-- Right: the paper. Same anatomy the carbon copy will use, so an officer
         sees exactly what the recipient will be handed. -->
    <div class="paper">
      <div class="p-head">
        <div class="p-dept">
          <div class="p-state">STATE OF SAN ANDREAS</div>
          <div class="p-agency">{agency.toUpperCase()}</div>
        </div>
        <div class="p-mid">
          <div class="p-title">{ticketType === "parking" ? "PARKING VIOLATION" : "NOTICE TO APPEAR"}</div>
          <div class="p-sub">Traffic Citation · Penal &amp; Vehicle Code</div>
        </div>
        <div class="p-no">
          <div class="p-no-l">CITATION NO.</div>
          <div class="p-no-v">{issued ? issued.number : "— PROVISIONAL —"}</div>
          <div class="p-no-when">{now}</div>
        </div>
      </div>

      <div class="p-row">
        {#if ticketType === "parking"}
          <!-- Written against the vehicle, so the plate is the subject. The
               registered keeper is named only if the lookup found one. -->
          <div class="p-cell grow"><span class="p-l">Plate</span><span class="p-v mono">{plate || "—"}</span></div>
          {#if recipientName}
            <div class="p-cell grow"><span class="p-l">Registered keeper</span><span class="p-v">{recipientName}</span></div>
          {/if}
        {:else}
          <div class="p-cell grow"><span class="p-l">Name (last, first)</span><span class="p-v">{recipientName || "—"}</span></div>
        {/if}
        <div class="p-cell"><span class="p-l">Date / time of violation</span><span class="p-v">{now}</span></div>
      </div>

      {#if hasVehicle}
        <div class="p-row">
          <!-- The plate already heads a parking ticket; repeating it here just
               fills a box twice. -->
          {#if ticketType !== "parking"}
            <div class="p-cell"><span class="p-l">Plate</span><span class="p-v mono">{plate || "—"}</span></div>
          {/if}
          <div class="p-cell grow"><span class="p-l">Make &amp; model</span><span class="p-v">{vehicle || "—"}</span></div>
          <div class="p-cell"><span class="p-l">Color</span><span class="p-v">{vehicleColor || "—"}</span></div>
        </div>
      {/if}

      <div class="p-row">
        <div class="p-cell grow"><span class="p-l">Location of violation</span><span class="p-v">{location || "—"}</span></div>
        {#if hasPostal}<div class="p-cell"><span class="p-l">Postal</span><span class="p-v">{postal || "—"}</span></div>{/if}
      </div>

      {#if hasVehicle && ticketType === "citation" && (speedMeasured || speedLimit)}
        <div class="p-row">
          <div class="p-cell"><span class="p-l">Measured speed</span><span class="p-v">{speedMeasured ?? "—"} mph</span></div>
          <div class="p-cell"><span class="p-l">Posted limit</span><span class="p-v">{speedLimit ?? "—"} mph</span></div>
          <div class="p-cell"><span class="p-l">Over by</span><span class="p-v">{speedMeasured && speedLimit ? Math.max(0, speedMeasured - speedLimit) + " mph" : "—"}</span></div>
        </div>
      {/if}

      <table class="p-table">
        <thead><tr><th class="n">#</th><th>Code section</th><th>Description</th><th class="c">Corr.</th><th class="b">Bail</th></tr></thead>
        <tbody>
          {#each Array(MAX_POSITIONS) as _, i}
            <tr class:filled={!!positions[i]}>
              <td class="n">{i + 1}</td>
              <td class="mono">{positions[i]?.code ?? ""}</td>
              <td>{positions[i]?.label ?? ""}</td>
              <td class="c">{positions[i] ? "☐" : ""}</td>
              <td class="b">{positions[i] ? "$" + positions[i].fine.toLocaleString() : ""}</td>
            </tr>
          {/each}
        </tbody>
        <tfoot><tr>
          <td colspan="3">TOTAL</td>
          <td colspan="2" class="b">${fineTotal.toLocaleString()}</td>
        </tr></tfoot>
      </table>

      {#if notes}
        <div class="p-notes">
          <span class="p-l">Remark
            <!-- Copyable because a remark often holds a link to evidence, and
                 retyping a URL off a screenshot is not a thing anyone does. -->
            <button class="p-copy" title={copiedNote ? "Copied" : "Copy remark"} onclick={copyNote}>
              <span class="material-icons">{copiedNote ? "check" : "content_copy"}</span>
            </button>
          </span>{notes}
        </div>
      {/if}

      <div class="p-promise">Without admitting guilt, I promise to appear at the time and place checked below.</div>
      <div class="p-sign">
        <div class="p-sig"><span class="p-sig-line"></span><span class="p-l">Signature of defendant</span></div>
        <div class="p-sig"><span class="p-sig-name">{officerName}</span><span class="p-l">Arresting / citing officer</span></div>
      </div>
      <div class="p-foot">Appear on or before — · San Andreas Superior Court, Traffic Division</div>
    </div>

  </div>
</div>
{/if}

<style>
	/* Everything here is component-scoped, so nothing is inherited from other
	   pages — the first version borrowed class names from Charges and Citizens
	   and rendered as unstyled text. */
	.cit-overlay {
		position: fixed; inset: 0; z-index: 200;
		display: flex; align-items: center; justify-content: center;
		padding: 24px;
		background: rgba(0, 0, 0, 0.6);
	}
	.cit-shell {
		display: flex; gap: 14px;
		width: min(1400px, 97vw);
		max-height: 86vh;
	}

	/* ── Form ── */
	.cit-form {
		display: flex; flex-direction: column;
		width: 420px; flex-shrink: 0;
		background: rgba(20, 22, 26, 0.98);
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 8px;
		overflow: hidden;
	}
	.cit-head {
		display: flex; align-items: baseline; gap: 8px;
		padding: 12px 14px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.07);
	}
	.cit-title { font-size: 15px; font-weight: 700; color: rgba(255,255,255,0.92); }
	.cit-sub { font-size: 10px; color: rgba(255,255,255,0.35); }
	.cit-close {
		margin-left: auto;
		width: 22px; height: 22px; padding: 0; margin-left: 4px;
		background: none; border: 1px solid rgba(255,255,255,0.1); border-radius: 3px;
		color: rgba(255,255,255,0.4); font-size: 11px; cursor: pointer;
	}
	.cit-close:hover { color: #fff; }

	.cit-scroll { flex: 1; min-height: 0; overflow-y: auto; padding: 12px 14px; }

	.lbl {
		/* Fixed height, and the icon button inside is taken out of the flow.
		   Without this, a label with a button in it sits taller than its
		   neighbours and the field below it drops out of line. */
		display: flex; align-items: center;
		height: 14px; margin-bottom: 4px;
		font-size: 9px; font-weight: 700; text-transform: uppercase;
		letter-spacing: 0.7px; color: rgba(255,255,255,0.4);
	}
	.hint { font-weight: 400; text-transform: none; letter-spacing: 0; color: rgba(255,255,255,0.28); }
	.fld { display: block; margin-bottom: 10px; }
	.inp {
		width: 100%; box-sizing: border-box;
		padding: 6px 9px;
		background: rgba(0,0,0,0.25);
		border: 1px solid rgba(255,255,255,0.08);
		border-radius: 4px;
		color: rgba(255,255,255,0.9);
		font-size: 12px; font-family: inherit; outline: none;
	}
	.inp:focus { border-color: rgba(var(--accent-rgb), 0.45); }
	.inp::placeholder { color: rgba(255,255,255,0.22); }
	.mono { font-family: "Courier New", monospace; letter-spacing: 0.5px; }
	.grid3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }

	.charge-list {
		max-height: 190px; overflow-y: auto;
		margin: 6px 0 14px;
		border: 1px solid rgba(255,255,255,0.07);
		border-radius: 4px;
	}
	.charge-row {
		display: flex; align-items: center; gap: 9px;
		width: 100%; padding: 6px 9px;
		background: none; border: none;
		border-bottom: 1px solid rgba(255,255,255,0.04);
		text-align: left; cursor: pointer;
	}
	.charge-row:hover:not(:disabled) { background: rgba(255,255,255,0.04); }
	.charge-row:disabled { opacity: 0.3; cursor: not-allowed; }
	.charge-row.picked { background: rgba(var(--accent-rgb), 0.13); }
	.charge-code {
		flex-shrink: 0; min-width: 70px;
		padding: 2px 5px;
		border-left: 2px solid;
		background: rgba(255,255,255,0.05);
		font-family: "Courier New", monospace; font-size: 9px;
		color: rgba(255,255,255,0.6);
	}
	.charge-label { flex: 1; min-width: 0; font-size: 11px; color: rgba(255,255,255,0.82); }
	.charge-fine { font-size: 11px; font-weight: 600; color: rgba(255,255,255,0.55); }

	.empty { padding: 12px; font-size: 11px; color: rgba(255,255,255,0.3); text-align: center; }

	.pos-list { display: flex; flex-direction: column; gap: 3px; margin: 6px 0 14px; }
	.pos-row {
		display: flex; align-items: center; gap: 8px;
		padding: 6px 9px; background: rgba(255,255,255,0.04); border-radius: 3px;
	}
	.pos-n {
		display: grid; place-items: center; width: 16px; height: 16px; flex-shrink: 0;
		border-radius: 3px; background: rgba(var(--accent-rgb), 0.2);
		color: rgba(var(--accent-text-rgb), 0.95); font-size: 9px; font-weight: 700;
	}
	.pos-label { flex: 1; min-width: 0; font-size: 11px; color: rgba(255,255,255,0.85); }
	.pos-fine { font-size: 11px; font-weight: 600; color: rgba(255,255,255,0.7); }
	.pos-x { background: none; border: none; color: rgba(255,255,255,0.3); font-size: 11px; cursor: pointer; }
	.pos-x:hover { color: rgba(248,113,113,0.9); }

	.msg { margin-top: 8px; font-size: 11px; }
	.err { color: rgba(248,113,113,0.9); }
	.warn { color: rgba(251,191,36,0.9); }
	.ok { color: rgba(52,211,153,0.9); }

	.cit-foot {
		display: flex; align-items: center; gap: 12px;
		padding: 11px 14px;
		border-top: 1px solid rgba(255,255,255,0.07);
	}
	.tot { display: flex; flex-direction: column; }
	.tot-l { font-size: 9px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; color: rgba(255,255,255,0.35); }
	.tot-v { font-size: 15px; font-weight: 700; color: rgba(255,255,255,0.92); }
	.btn {
		margin-left: auto; padding: 7px 16px;
		background: rgba(255,255,255,0.06);
		border: 1px solid rgba(255,255,255,0.1);
		border-radius: 4px;
		color: rgba(255,255,255,0.8);
		font-size: 11px; font-weight: 600; cursor: pointer;
	}
	.btn.primary { background: rgba(16,185,129,0.15); border-color: rgba(16,185,129,0.3); color: #34d399; }
	.btn.warn {
		margin-left: auto;
		background: rgba(251,191,36,0.12);
		border-color: rgba(251,191,36,0.3);
		color: #fcd34d;
	}
	.btn.warn + .btn.primary { margin-left: 0; }
	.btn:disabled { opacity: 0.4; cursor: not-allowed; }

	/* ── The paper ──
	   Deliberately light and typewritten: it is a physical form, and making it
	   match the dark UI would have hidden that it is meant to be handed over. */
	.paper {
		flex: 1; min-width: 0;
		/* Sized to what a citation actually contains, not to the window. It was
		   stretched to full height and read like an A4 sheet with a third of it
		   blank; a ticket is a slip. Its own scrollbar for the rare long one. */
		align-self: flex-start;
		max-height: 86vh;
		overflow-y: auto;
		padding: 18px 22px;
		background: #f4f1e8;
		border-radius: 6px;
		color: #17181c;
		font-family: "Courier New", monospace;
		/* Sized to be read, not to look like a scan. The first pass was 10px
		   over a full-width sheet, which is smaller than the form beside it. */
		font-size: 13px;
		line-height: 1.45;
	}
	.p-head { display: flex; align-items: flex-start; gap: 12px; padding-bottom: 8px; }
	.p-state { font-size: 10px; letter-spacing: 0.5px; }
	.p-agency { font-size: 15px; font-weight: 700; }
	.p-mid { flex: 1; text-align: center; }
	.p-title { font-size: 19px; font-weight: 700; letter-spacing: 1px; }
	.p-sub { font-size: 10px; }
	.p-no { text-align: right; }
	.p-no-l { font-size: 9px; letter-spacing: 0.5px; }
	.p-no-v { font-size: 14px; font-weight: 700; color: #b3261e; }

	.p-row { display: flex; border: 1px solid #17181c; border-bottom: none; }
	.p-row:last-of-type { border-bottom: 1px solid #17181c; }
	.p-cell { flex: 1; min-width: 0; padding: 3px 8px; border-right: 1px solid #17181c; }
	.p-cell:last-child { border-right: none; }
	.p-cell.grow { flex: 2; }
	.p-l { display: block; font-size: 9px; text-transform: uppercase; letter-spacing: 0.4px; opacity: 0.65; }
	.p-v { display: block; font-size: 13px; min-height: 16px; }

	.p-table { width: 100%; border-collapse: collapse; margin-top: 8px; }
	.p-table th, .p-table td { border: 1px solid #17181c; padding: 3px 8px; text-align: left; font-size: 11px; }
	.p-table th { font-size: 9px; text-transform: uppercase; letter-spacing: 0.4px; font-weight: 400; opacity: 0.7; }
	.p-table td { height: 18px; }
	.p-table .n { width: 24px; text-align: center; }
	.p-table .c { width: 44px; text-align: center; }
	.p-table .b { width: 86px; text-align: right; }
	.p-table tfoot td { font-weight: 700; }

	.p-notes { margin-top: 8px; padding: 6px 8px; border: 1px solid #17181c; font-size: 12px; }
	.p-promise { margin-top: 10px; text-align: center; font-size: 10px; }
	.p-sign { display: flex; gap: 18px; margin-top: 10px; }
	.p-sig { flex: 1; }
	.p-sig-line { display: block; height: 20px; border-bottom: 1px solid #17181c; }
	.p-sig-name {
		display: block; height: 20px;
		font-family: Georgia, "Times New Roman", serif;
		font-style: italic; font-size: 19px;
		border-bottom: 1px solid #17181c;
	}
	.p-foot { margin-top: 10px; padding-top: 5px; border-top: 1px dashed #17181c; text-align: center; font-size: 10px; }

	/* Recipient picker. Tiles rather than a list: a face and a distance are
	   what an officer matches against, and both read faster as a card. */
	.targets { display: flex; gap: 6px; overflow-x: auto; margin: 6px 0 14px; padding-bottom: 2px; }
	.tgt {
		display: flex; flex-direction: column; align-items: center; gap: 4px;
		flex-shrink: 0; width: 128px; padding: 10px 8px;
		background: rgba(255,255,255,0.03);
		border: 1px solid rgba(255,255,255,0.07);
		border-radius: 5px;
		cursor: pointer; transition: all 0.1s;
	}
	.tgt:hover { background: rgba(255,255,255,0.06); }
	.tgt.sel { background: rgba(var(--accent-rgb), 0.15); border-color: rgba(var(--accent-rgb), 0.4); }
	.tgt-img {
		width: 40px; height: 40px; border-radius: 50%;
		object-fit: cover; background: rgba(0,0,0,0.3);
		border: 1px solid rgba(255,255,255,0.1);
	}
	.tgt-fallback {
		display: grid; place-items: center;
		color: rgba(255,255,255,0.4);
	}
	.tgt-fallback .material-icons { font-size: 20px; }
	.tgt-name {
		max-width: 100%; font-size: 10px; font-weight: 600;
		color: rgba(255,255,255,0.85);
		white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
	}
	.tgt-dist { font-size: 9px; color: rgba(255,255,255,0.35); }
	.relink {
		margin-left: 6px; padding: 0; background: none; border: none;
		color: rgba(var(--accent-text-rgb), 0.7);
		font-size: 9px; font-weight: 600; text-transform: none;
		letter-spacing: 0; cursor: pointer;
	}
	.relink:hover { color: rgba(var(--accent-text-rgb), 1); }

	/* Stage 1: the picker. Wide and short — a step on the way, not a window. */
	.pick-bar {
		width: min(1000px, 94vw);
		background: rgba(20,22,26,0.98);
		border: 1px solid rgba(255,255,255,0.08);
		border-radius: 8px;
		overflow: hidden;
	}
	.pick-head {
		display: flex; align-items: baseline; gap: 8px;
		padding: 11px 14px;
		border-bottom: 1px solid rgba(255,255,255,0.07);
	}
	.pick-title { font-size: 14px; font-weight: 700; color: rgba(255,255,255,0.92); }
	.pick-sub { font-size: 10px; color: rgba(255,255,255,0.35); }
	.pick-head .cit-close { margin-left: 0; }
	.pick-head .icon-btn { margin-left: auto; }
	.pick-row { display: flex; gap: 8px; overflow-x: auto; padding: 14px; }
	.pick-row.inline { padding: 6px 0 12px; }
	.tgt-sub {
		max-width: 100%; font-size: 9px; color: rgba(255,255,255,0.4);
		white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
	}
	.empty.small { padding: 8px; font-size: 10px; text-align: left; }

	/* Who the ticket is for, settled in stage 1 and shown as fact, not a field. */
	.who {
		display: flex; align-items: baseline; gap: 8px;
		margin-bottom: 12px; padding: 8px 10px;
		background: rgba(var(--accent-rgb), 0.1);
		border-left: 2px solid rgba(var(--accent-rgb), 0.5);
		border-radius: 3px;
	}
	.who-name { font-size: 13px; font-weight: 700; color: rgba(255,255,255,0.92); }
	.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }

	/* Resizing the remark must not drag the paper about. */
	.ta { resize: vertical; min-height: 44px; max-height: 180px; min-width: 100%; max-width: 100%; }

	/* Icon buttons where a word used to sit — the action is obvious from the
	   glyph and stops competing with the label beside it. */
	.icon-btn {
		display: inline-grid; place-items: center;
		width: 16px; height: 14px; padding: 0; margin-left: 5px;
		flex-shrink: 0;
		background: none; border: none; border-radius: 3px;
		color: rgba(255,255,255,0.4); cursor: pointer; transition: all 0.1s;
	}
	.icon-btn:hover { color: rgba(var(--accent-text-rgb), 0.95); background: rgba(255,255,255,0.06); }
	.icon-btn .material-icons { font-size: 14px; line-height: 1; }
	.tgt-img.veh { border-radius: 4px; object-fit: contain; background: rgba(255,255,255,0.04); }

	/* A citation's vehicle is context, not the case — quieter than the rows
	   that carry the charge itself. */
	.p-aside .p-v { font-size: 12px; opacity: 0.8; }
	.p-aside { border-style: dashed; }

	/* Fades out after issuing so the handover animation is actually seen. */
	.cit-overlay.closing {
		opacity: 0;
		transition: opacity 1.6s ease-in 0.6s;
		pointer-events: none;
	}

	.p-no-when { font-size: 10px; opacity: 0.7; }
	/* Issued: the sheet steps back so the handover is what you are looking at. */
	.cit-overlay { transition: opacity 0.5s ease; }
	.cit-overlay.closing { opacity: 0; pointer-events: none; }
	.cit-overlay.closing .cit-shell { transform: scale(0.97); transition: transform 0.5s ease; }

	.p-copy {
		background: none; border: none; padding: 0 0 0 4px;
		color: inherit; opacity: 0.55; cursor: pointer; vertical-align: -3px;
	}
	.p-copy:hover { opacity: 1; }
	.p-copy .material-icons { font-size: 13px; }
</style>
