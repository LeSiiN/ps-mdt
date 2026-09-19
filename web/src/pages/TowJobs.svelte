<script lang="ts">
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";

	// Standalone, not an MDT tab: a tow driver has no MDT access, and the work
	// happens out in the world.
	let { show = false, onClose = () => {} }: { show?: boolean; onClose?: () => void } = $props();

	type TowJob = {
		id: number;
		plate: string;
		model?: string;
		lot?: string;
		coords?: string;
		location?: string;
		pay: number;
		officer_name?: string;
		distance?: number;
		lotLabel?: string;
		created_at?: string;
		taken_at?: string;
	};

	let jobs = $state<TowJob[]>([]);
	let mine = $state<TowJob | null>(null);
	let loading = $state(true);
	let busy = $state(false);
	let msg = $state("");

	// Stepping out of the queue without going off duty. A driver who is busy
	// with something else shouldn't have to clock off to stop getting calls.
	let available = $state(true);

	async function toggleAvailable() {
		busy = true;
		try {
			const res: any = await fetchNui(NUI_EVENTS.TOWING.SET_TOW_AVAILABLE, {
				available: !available,
			});
			available = res?.available ?? !available;
			msg = available ? "Back in the queue" : "You're out of the queue — jobs go to others";
			await load();
		} catch { msg = "That didn't work."; }
		busy = false;
		setTimeout(() => (msg = ""), 3500);
	}

	async function load() {
		loading = true;
		try {
			const res = await fetchNui<{ jobs: TowJob[]; mine: TowJob | null }>(
				NUI_EVENTS.TOWING.GET_TOW_JOBS, {});
			jobs = res?.jobs ?? [];
			mine = res?.mine ?? null;
			const av: any = await fetchNui(NUI_EVENTS.TOWING.GET_TOW_AVAILABLE, {});
			available = av?.available !== false;
		} catch {
			jobs = []; mine = null;
		}
		loading = false;
	}

	let wasShown = false;
	$effect(() => {
		if (show && !wasShown) { wasShown = true; load(); }
		else if (!show && wasShown) { wasShown = false; msg = ""; }
	});

	// Typed against the event map rather than plain string, so a renamed event
	// breaks the build instead of the feature.
	type TowEvent = typeof NUI_EVENTS.TOWING[keyof typeof NUI_EVENTS.TOWING];

	async function act(event: TowEvent, jobId: number, after?: () => void) {
		busy = true; msg = "";
		try {
			const res: any = await fetchNui(event, { jobId });
			if (res?.success !== false) {
				await load();
				after?.();
			} else {
				msg = res?.error ?? "That didn't work.";
			}
		} catch { msg = "That didn't work."; }
		busy = false;
		if (msg) setTimeout(() => (msg = ""), 3500);
	}

	const take = (j: TowJob) => act(NUI_EVENTS.TOWING.TAKE_TOW_JOB, j.id);
	const drop = (j: TowJob) => act(NUI_EVENTS.TOWING.DROP_TOW_JOB, j.id);

	async function deliver(j: TowJob) {
		busy = true; msg = "";
		try {
			const res: any = await fetchNui(NUI_EVENTS.TOWING.DELIVER_TOW_JOB, { jobId: j.id });
			if (res?.success) {
				msg = `Delivered — $${Number(res.paid ?? 0).toLocaleString()}`;
				await load();
			} else {
				msg = res?.error ?? "Could not deliver.";
			}
		} catch { msg = "Could not deliver."; }
		busy = false;
		setTimeout(() => (msg = ""), 4000);
	}

	// Metres up close, kilometres beyond — a driver reads "1.2 km" faster than
	// "1240 m".
	function fmtDist(m?: number): string {
		if (m === undefined) return "";
		return m < 1000 ? m + " m" : (m / 1000).toFixed(1) + " km";
	}

	function waypoint(coords?: string) {
		if (!coords) return;
		fetchNui(NUI_EVENTS.TOWING.TOW_WAYPOINT, { coords }).catch(() => {});
	}

	function close() {
		fetchNui(NUI_EVENTS.TOWING.CLOSE_TOW_JOBS, {}).catch(() => {});
		onClose();
	}

	function onKey(e: KeyboardEvent) {
		if (e.key === "Escape" && show) { e.preventDefault(); close(); }
	}
	$effect(() => {
		window.addEventListener("keydown", onKey);
		return () => window.removeEventListener("keydown", onKey);
	});
</script>

{#if show}
<div class="tj-wrap">
  <div class="tj-panel">
    <div class="tj-head">
      <span class="material-icons tj-hicon">local_shipping</span>
      <span class="tj-title">Tow Jobs</span>
      <button class="tj-avail" class:off={!available} disabled={busy} onclick={toggleAvailable}
        title={available ? "Stop receiving jobs" : "Start receiving jobs again"}>
        <span class="tj-dot"></span>{available ? "Available" : "Paused"}
      </button>
      <button class="tj-ico" title="Refresh" onclick={load}>
        <span class="material-icons">refresh</span>
      </button>
      <button class="tj-ico" onclick={close}><span class="material-icons">close</span></button>
    </div>

    {#if msg}<div class="tj-msg">{msg}</div>{/if}

    <div class="tj-body">
      {#if mine}
        <!-- The job in hand gets the whole top of the panel. One at a time, so
             it is the screen rather than an entry on it. -->
        <div class="tj-active">
          <div class="tj-active-bar">
            <span class="tj-pulse"></span>ON THE JOB
            <span class="tj-active-pay">${Number(mine.pay).toLocaleString()}</span>
          </div>

          <div class="tj-active-veh">
            <span class="tj-plate">{mine.plate}</span>
            <span class="tj-model">{mine.model ?? "Unknown vehicle"}</span>
          </div>

          <!-- Pick up here, drop off there. The route is the job. -->
          <div class="tj-route">
            <div class="tj-stop">
              <span class="tj-pin from"></span>
              <div class="tj-stop-text">
                <span class="tj-stop-k">Collect</span>
                <span class="tj-stop-v">{mine.location || "Unknown street"}</span>
              </div>
              {#if mine.distance !== undefined}
                <span class="tj-dist">{fmtDist(mine.distance)}</span>
              {/if}
            </div>
            <div class="tj-line"></div>
            <div class="tj-stop">
              <span class="tj-pin to"></span>
              <div class="tj-stop-text">
                <span class="tj-stop-k">Deliver</span>
                <span class="tj-stop-v">{mine.lotLabel ?? mine.lot ?? "impound"}</span>
              </div>
            </div>
          </div>

          <div class="tj-acts">
            <button class="tj-btn" onclick={() => waypoint(mine?.coords)}>
              <span class="material-icons">near_me</span> Route
            </button>
            <button class="tj-btn go wide" disabled={busy} onclick={() => mine && deliver(mine)}>
              <span class="material-icons">check_circle</span>{busy ? "…" : "Deliver"}
            </button>
          </div>
          <button class="tj-giveup" disabled={busy} onclick={() => mine && drop(mine)}>
            Give this job back
          </button>
        </div>
      {/if}

      <div class="tj-listhead">
        <span>{mine ? "Also waiting" : "Waiting"}</span>
        <span class="tj-count">{jobs.length}</span>
      </div>

      {#if loading}
        <div class="tj-empty">Loading…</div>
      {:else if !available}
        <div class="tj-empty">
          <span class="material-icons">pause_circle</span>
          You're paused
          <span class="tj-esub">Switch back to Available to take work.</span>
        </div>
      {:else if jobs.length === 0}
        <div class="tj-empty">
          <span class="material-icons">done_all</span>
          Nothing waiting
          <span class="tj-esub">Police requests land here.</span>
        </div>
      {:else}
        {#each jobs as j (j.id)}
          <!-- Pay and distance lead: that is the whole decision. The plate
               matters on arrival, not while choosing. -->
          <button class="tj-job" disabled={busy || !!mine} onclick={() => take(j)}>
            <div class="tj-job-top">
              <span class="tj-job-model">{j.model ?? "Unknown vehicle"}</span>
              <span class="tj-job-pay">${Number(j.pay).toLocaleString()}</span>
            </div>
            <div class="tj-job-mid">
              <span class="material-icons">place</span>{j.location || "Unknown street"}
              {#if j.distance !== undefined}
                <span class="tj-job-dist">{fmtDist(j.distance)}</span>
              {/if}
            </div>
            <div class="tj-job-foot">
              <span class="tj-plate small">{j.plate}</span>
              {#if j.officer_name}<span class="tj-job-by">{j.officer_name}</span>{/if}
              <span class="tj-job-take">{mine ? "" : "Accept"}</span>
            </div>
          </button>
        {/each}
      {/if}
    </div>
  </div>
</div>
{/if}

<style>
	/* ps-dispatch's panel, but the content is shaped around one question: is
	   this worth driving to? Pay and distance lead; the plate matters when you
	   arrive, not while you choose. */
	.tj-wrap {
		position: fixed; inset: 0; z-index: 200;
		display: flex; align-items: center; justify-content: flex-end;
		padding: 0 14px;
		pointer-events: none;
	}
	.tj-panel {
		pointer-events: auto;
		width: 372px; max-width: 30vw; height: 86%;
		display: flex; flex-direction: column;
		background: rgba(26, 28, 33, 0.97);
		border: 1px solid rgba(255, 255, 255, 0.1);
		border-radius: 6px; overflow: hidden;
		box-shadow: 0 24px 70px rgba(0, 0, 0, 0.65);
		color: rgba(255, 255, 255, 0.85);
	}

	.tj-head {
		display: flex; align-items: center; gap: 8px;
		padding: 10px 12px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.09);
	}
	.tj-hicon { font-size: 17px; color: #fbbf24; }
	.tj-title { font-size: 12px; font-weight: 600; color: rgba(255, 255, 255, 0.85); }
	.tj-avail {
		display: inline-flex; align-items: center; gap: 5px;
		margin-left: auto; padding: 3px 9px;
		background: rgba(34, 197, 94, 0.12);
		border: none; border-radius: 3px;
		color: #4ade80;
		font-size: 9px; font-weight: 600; letter-spacing: 0.04em;
		font-family: inherit; cursor: pointer;
	}
	.tj-avail.off { background: rgba(255, 255, 255, 0.05); color: rgba(255, 255, 255, 0.4); }
	.tj-avail:disabled { opacity: 0.5; cursor: wait; }
	.tj-dot { width: 5px; height: 5px; border-radius: 50%; background: currentColor; }
	.tj-ico {
		display: grid; place-items: center;
		width: 20px; height: 20px; padding: 0;
		background: none; border: none; border-radius: 3px;
		color: rgba(255, 255, 255, 0.35); cursor: pointer;
	}
	.tj-ico:hover { color: rgba(255, 255, 255, 0.85); background: rgba(255, 255, 255, 0.06); }
	.tj-ico .material-icons { font-size: 15px; }

	.tj-msg {
		padding: 8px 12px;
		background: rgba(255, 255, 255, 0.04);
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		font-size: 11px; color: rgba(255, 255, 255, 0.7);
	}
	.tj-body { flex: 1; min-height: 0; overflow-y: auto; padding: 10px; }

	/* ── The job in hand ────────────────────────────────────────────────── */
	.tj-active {
		margin-bottom: 14px; padding: 12px;
		background: rgba(251, 191, 36, 0.06);
		border: 1px solid rgba(251, 191, 36, 0.3);
		border-radius: 6px;
	}
	.tj-active-bar {
		display: flex; align-items: center; gap: 7px;
		margin-bottom: 10px;
		font-size: 9px; font-weight: 700; letter-spacing: 0.12em;
		color: #fcd34d;
	}
	.tj-pulse {
		width: 6px; height: 6px; border-radius: 50%;
		background: #fcd34d;
		box-shadow: 0 0 0 0 rgba(252, 211, 77, 0.6);
		animation: tj-ping 2s ease-out infinite;
	}
	@keyframes tj-ping {
		0%   { box-shadow: 0 0 0 0 rgba(252, 211, 77, 0.6); }
		70%  { box-shadow: 0 0 0 7px rgba(252, 211, 77, 0); }
		100% { box-shadow: 0 0 0 0 rgba(252, 211, 77, 0); }
	}
	@media (prefers-reduced-motion: reduce) { .tj-pulse { animation: none; } }
	.tj-active-pay { margin-left: auto; font-size: 17px; font-weight: 700; color: #4ade80; letter-spacing: -0.3px; }

	.tj-active-veh { display: flex; align-items: center; gap: 9px; margin-bottom: 12px; }
	.tj-plate {
		padding: 3px 9px; border-radius: 3px;
		background: rgba(0, 0, 0, 0.4);
		border: 1px solid rgba(255, 255, 255, 0.12);
		font-family: "Courier New", monospace;
		font-size: 13px; font-weight: 700; letter-spacing: 1.5px;
		color: #fff;
	}
	.tj-plate.small { font-size: 10px; letter-spacing: 1px; padding: 2px 6px; }
	.tj-model { font-size: 13px; font-weight: 600; color: rgba(255, 255, 255, 0.9); }

	/* Collect here, deliver there — the route drawn as a route. */
	.tj-route { position: relative; }
	.tj-stop { display: flex; align-items: center; gap: 10px; }
	.tj-pin {
		width: 9px; height: 9px; border-radius: 50%; flex-shrink: 0;
		border: 2px solid;
	}
	.tj-pin.from { border-color: #fcd34d; background: rgba(252, 211, 77, 0.25); }
	.tj-pin.to { border-color: #4ade80; background: rgba(74, 222, 128, 0.25); }
	.tj-line {
		width: 2px; height: 16px; margin: 2px 0 2px 3.5px;
		background: linear-gradient(rgba(252, 211, 77, 0.5), rgba(74, 222, 128, 0.5));
	}
	.tj-stop-text { display: flex; flex-direction: column; min-width: 0; }
	.tj-stop-k {
		font-size: 8px; font-weight: 700; letter-spacing: 0.1em;
		text-transform: uppercase; color: rgba(255, 255, 255, 0.35);
	}
	.tj-stop-v {
		font-size: 12px; color: rgba(255, 255, 255, 0.85);
		overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
	}
	.tj-dist {
		margin-left: auto; flex-shrink: 0;
		font-size: 11px; font-weight: 700; color: rgba(255, 255, 255, 0.55);
	}

	.tj-acts { display: flex; gap: 7px; margin-top: 14px; }
	.tj-btn {
		display: flex; align-items: center; justify-content: center; gap: 6px;
		flex: 1; padding: 9px 12px;
		background: rgba(255, 255, 255, 0.06);
		border: 1px solid rgba(255, 255, 255, 0.09);
		border-radius: 4px;
		color: rgba(255, 255, 255, 0.82);
		font-size: 11px; font-weight: 700; font-family: inherit;
		cursor: pointer; transition: background 0.12s;
	}
	.tj-btn:hover:not(:disabled) { background: rgba(255, 255, 255, 0.11); }
	.tj-btn:disabled { opacity: 0.35; cursor: not-allowed; }
	.tj-btn.wide { flex: 1.6; }
	.tj-btn.go { background: rgba(34, 197, 94, 0.14); border-color: rgba(34, 197, 94, 0.3); color: #4ade80; }
	.tj-btn.go:hover:not(:disabled) { background: rgba(34, 197, 94, 0.22); }
	.tj-btn .material-icons { font-size: 15px; }

	/* Quiet on purpose: giving a job back is allowed, not encouraged. */
	.tj-giveup {
		display: block; width: 100%;
		margin-top: 8px; padding: 4px;
		background: none; border: none;
		color: rgba(255, 255, 255, 0.28);
		font-size: 10px; font-family: inherit;
		cursor: pointer;
	}
	.tj-giveup:hover:not(:disabled) { color: rgba(248, 113, 113, 0.85); }

	/* ── The queue ──────────────────────────────────────────────────────── */
	.tj-listhead {
		display: flex; align-items: center; gap: 7px;
		padding: 0 2px 7px;
		font-size: 9px; font-weight: 700; letter-spacing: 0.1em;
		text-transform: uppercase; color: rgba(255, 255, 255, 0.3);
	}
	.tj-count {
		padding: 1px 6px; border-radius: 3px;
		background: rgba(255, 255, 255, 0.06);
		color: rgba(255, 255, 255, 0.5);
	}

	/* The whole card is the accept button. Hunting for a small target while
	   sitting in a truck is the wrong kind of precision. */
	.tj-job {
		display: block; width: 100%;
		margin-bottom: 7px; padding: 11px 12px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 6px;
		text-align: left; font-family: inherit;
		cursor: pointer; transition: all 0.13s;
	}
	.tj-job:hover:not(:disabled) {
		background: rgba(34, 197, 94, 0.07);
		border-color: rgba(34, 197, 94, 0.3);
		transform: translateX(-2px);
	}
	.tj-job:disabled { opacity: 0.4; cursor: not-allowed; }

	.tj-job-top { display: flex; align-items: baseline; gap: 10px; }
	.tj-job-model {
		flex: 1; min-width: 0;
		font-size: 13px; font-weight: 600; color: rgba(255, 255, 255, 0.9);
		overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
	}
	.tj-job-pay { font-size: 15px; font-weight: 700; color: #4ade80; letter-spacing: -0.3px; }

	.tj-job-mid {
		display: flex; align-items: center; gap: 5px;
		margin-top: 4px;
		font-size: 11px; color: rgba(255, 255, 255, 0.45);
	}
	.tj-job-mid .material-icons { font-size: 13px; opacity: 0.6; }
	.tj-job-dist { margin-left: auto; font-weight: 700; color: rgba(255, 255, 255, 0.6); }

	.tj-job-foot {
		display: flex; align-items: center; gap: 8px;
		margin-top: 9px; padding-top: 8px;
		border-top: 1px solid rgba(255, 255, 255, 0.05);
	}
	.tj-job-by { font-size: 10px; color: rgba(255, 255, 255, 0.28); }
	.tj-job-take {
		margin-left: auto;
		font-size: 10px; font-weight: 700; letter-spacing: 0.06em;
		color: rgba(74, 222, 128, 0.5);
		transition: color 0.13s;
	}
	.tj-job:hover:not(:disabled) .tj-job-take { color: #4ade80; }

	.tj-empty {
		display: flex; flex-direction: column; align-items: center; gap: 6px;
		padding: 38px 16px; text-align: center;
		font-size: 12px; color: rgba(255, 255, 255, 0.35);
	}
	.tj-empty .material-icons { font-size: 30px; opacity: 0.22; }
	.tj-esub { font-size: 10px; color: rgba(255, 255, 255, 0.22); }
</style>
