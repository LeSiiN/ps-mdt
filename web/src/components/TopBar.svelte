<script lang="ts">
	import { onMount } from "svelte";
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";
	import {
		DEFAULT_TIME,
		DEFAULT_DATE,
		TIMING,
		APP_INFO,
	} from "../constants";
	import { formatTime, formatDate } from "../utils/datetime";
	import { useNuiEvent } from "@/utils/useNuiEvent";

	let info = $derived(APP_INFO[authService.jobType] || APP_INFO.leo);
	import type { AuthService } from "../services/authService.svelte";

	interface Props {
		authService: AuthService;
		onOpacityStyleChange: (opacityStyle: string) => void;
	}

	let { authService, onOpacityStyleChange }: Props = $props();

	// The callsign lives here now rather than on the dashboard: it's identity, not a
	// statistic, and an officer wants it in view on every tab — not just the one.
	let callsign = $state("");
	const EMPTY_CALLSIGN = new Set(["", "NIL", "NO CALLSIGN", "NONE", "NULL"]);

	// isAuthorized starts false and is set asynchronously, so onMount is too early.
	// Re-running on every authorisation also means reopening the MDT refreshes it
	// rather than showing whatever was cached from last time.
	$effect(() => {
		if (authService.isAuthorized) {
			loadCallsign();
		} else {
			callsign = "";
		}
	});

	// The server already announces a callsign change to the officer it belongs to;
	// nothing was listening for it.
	useNuiEvent<{ callsign?: string }>(NUI_EVENTS.DASHBOARD.CALLSIGN_UPDATED, (data) => {
		const cs = data?.callsign != null ? String(data.callsign).trim() : "";
		callsign = EMPTY_CALLSIGN.has(cs.toUpperCase()) ? "" : cs;
	});

	async function loadCallsign() {
		try {
			const res = await fetchNui<{ callsign?: string }>(
				NUI_EVENTS.DASHBOARD.GET_CALLSIGN,
				{},
				{ callsign: "" },
			);
			const cs = res?.callsign != null ? String(res.callsign).trim() : "";
			callsign = EMPTY_CALLSIGN.has(cs.toUpperCase()) ? "" : cs;
		} catch {
			callsign = "";
		}
	}

	let currentTime = $state(DEFAULT_TIME);
	let currentDate = $state(DEFAULT_DATE);
	let opacityTimeout: ReturnType<typeof setTimeout> | null = $state(null);
	let documentOpacity = $state(1);

	/**
	 * Reactive statement for the opacity style string.
	 */
	const opacityStyle = $derived(`opacity: ${documentOpacity}`);

	/**
	 * Watch for opacity style changes and notify parent.
	 */
	$effect(() => {
		onOpacityStyleChange(opacityStyle);
	});

	function handleTopBarEnter() {
		if (opacityTimeout) {
			clearTimeout(opacityTimeout);
			opacityTimeout = null;
		}
		documentOpacity = 0.25;
	}

	function handleTopBarLeave() {
		if (opacityTimeout) {
			clearTimeout(opacityTimeout);
		}

		opacityTimeout = setTimeout(() => {
			documentOpacity = 1;
			opacityTimeout = null;
		}, TIMING.topBarOpacityDelay);
	}

	/**
	 * Initializes the time update interval and cleans up on component destruction.
	 */
	onMount(() => {
		const timeInterval = setInterval(() => {
			const now = new Date();
			currentTime = formatTime(now);
			currentDate = formatDate(now);
		}, TIMING.timeUpdateInterval);

		return () => {
			clearInterval(timeInterval);
			if (opacityTimeout) {
				clearTimeout(opacityTimeout);
			}
		};
	});
</script>

<div
	class="top-bar"
	role="region"
	onmouseenter={handleTopBarEnter}
	onmouseleave={handleTopBarLeave}
>
	<div class="tb-identity">
		<div class="tb-badge">
			<span class="material-icons">{info.icon}</span>
		</div>

		{#if authService.isAuthorized}
			<div class="tb-who">
				<span class="tb-name">
					{authService.playerInfo().firstName}
					{authService.playerInfo().lastName}
				</span>
				<span class="tb-sub">
					<span class="tb-rank">{authService.playerInfo().rank}</span>
					<span class="tb-dot"></span>
					<span class="tb-dept">{authService.playerInfo().department}</span>
				</span>
			</div>

			<span class="tb-rule"></span>

			<!-- Callsign: the thing you're called on the radio, so it's typeset like a
			     readout rather than buried in a sentence. -->
			<div class="tb-field" class:tb-field-empty={!callsign}>
				<span class="tb-field-label">Callsign</span>
				<span class="tb-field-value">{callsign || "Unassigned"}</span>
			</div>

			<div class="tb-duty" class:on={authService.onDuty}>
				<span class="tb-duty-dot"></span>
				{authService.onDuty ? "On duty" : "Off duty"}
			</div>
		{:else}
			<div class="tb-who">
				<span class="tb-name">{info.title}</span>
				<span class="tb-sub">{info.subtitle}</span>
			</div>
		{/if}
	</div>

	<div class="tb-clock">
		<span class="tb-time">{currentTime}</span>
		<span class="tb-date">{currentDate}</span>
	</div>
</div>

<style>
	/* This is the one element on screen at all times, so it's laid out like a proper
	   terminal header: identity on the left, readouts in the middle, clock on the
	   right — not a run-on line of text glued together with pipe characters. */
	.tb-identity {
		display: flex;
		align-items: center;
		gap: 12px;
		min-width: 0;
	}

	.tb-badge {
		display: grid;
		place-items: center;
		width: 34px;
		height: 34px;
		flex-shrink: 0;
		border-radius: 6px;
		background: var(--accent-10);
		border: 1px solid var(--accent-30);
		color: var(--accent-70);
		box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.05);
	}
	.tb-badge .material-icons { font-size: 19px; }

	.tb-who {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}
	.tb-name {
		font-size: 13px;
		font-weight: 600;
		line-height: 1.15;
		color: rgba(255, 255, 255, 0.92);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.tb-sub {
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: 10px;
		font-weight: 500;
		line-height: 1.15;
		color: rgba(255, 255, 255, 0.38);
		white-space: nowrap;
	}
	.tb-rank {
		color: rgba(255, 255, 255, 0.58);
		text-transform: uppercase;
		letter-spacing: 0.5px;
		font-size: 9px;
		font-weight: 600;
	}
	.tb-dept { letter-spacing: 0.2px; }
	.tb-dot {
		width: 2px;
		height: 2px;
		border-radius: 50%;
		background: rgba(255, 255, 255, 0.22);
		flex-shrink: 0;
	}

	.tb-rule {
		width: 1px;
		height: 24px;
		background: rgba(255, 255, 255, 0.07);
		flex-shrink: 0;
	}

	/* A labelled readout. The label is what stops it reading as decoration. */
	.tb-field {
		display: flex;
		flex-direction: column;
		gap: 2px;
		flex-shrink: 0;
	}
	.tb-field-label {
		font-size: 8px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.9px;
		line-height: 1;
		color: rgba(255, 255, 255, 0.28);
	}
	.tb-field-value {
		font-family: monospace;
		font-size: 14px;
		font-weight: 700;
		line-height: 1.1;
		letter-spacing: 1.2px;
		color: var(--accent-70);
	}
	/* No callsign is worth noticing, but it isn't an error — it stays quiet. */
	.tb-field-empty .tb-field-value {
		font-family: inherit;
		font-size: 12px;
		font-weight: 500;
		letter-spacing: 0;
		color: rgba(255, 255, 255, 0.25);
	}

	.tb-duty {
		display: flex;
		align-items: center;
		gap: 6px;
		flex-shrink: 0;
		padding: 4px 10px;
		border-radius: 4px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		font-size: 10px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.4);
	}
	.tb-duty-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: rgba(255, 255, 255, 0.25);
	}
	.tb-duty.on {
		background: rgba(16, 185, 129, 0.08);
		border-color: rgba(16, 185, 129, 0.22);
		color: rgba(52, 211, 153, 0.9);
	}
	.tb-duty.on .tb-duty-dot {
		background: rgba(52, 211, 153, 0.95);
		box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.5);
		animation: tb-pulse 2s ease-out infinite;
	}
	@keyframes tb-pulse {
		0%   { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.45); }
		70%  { box-shadow: 0 0 0 5px rgba(52, 211, 153, 0); }
		100% { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0); }
	}

	.tb-clock {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 2px;
		flex-shrink: 0;
	}
	.tb-time {
		font-family: monospace;
		font-size: 16px;
		font-weight: 600;
		line-height: 1.1;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.9);
		/* Tabular figures, or the clock jitters as the digits change width. */
		font-variant-numeric: tabular-nums;
	}
	.tb-date {
		font-size: 10px;
		font-weight: 500;
		line-height: 1.1;
		letter-spacing: 0.3px;
		color: rgba(255, 255, 255, 0.33);
		font-variant-numeric: tabular-nums;
	}

	.top-bar {
		background: linear-gradient(180deg, rgba(20, 20, 22, 0.82), rgba(13, 13, 13, 0.72));
		min-height: 55px;
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 0 20px;
		color: var(--primary-text);
		font-size: 14px;
		font-weight: 500;
		border-bottom: 1px solid var(--border-primary);
		z-index: 10;
		position: relative;
		cursor: default;
	}

	:global([data-job-type="ems"]) .top-bar {
		background: rgba(18, 10, 10, 0.8);
		border-bottom-color: rgba(220, 50, 50, 0.12);
	}

	:global([data-job-type="doj"]) .top-bar {
		background: rgba(8, 12, 20, 0.8);
		border-bottom-color: rgba(180, 150, 60, 0.12);
	}

</style>