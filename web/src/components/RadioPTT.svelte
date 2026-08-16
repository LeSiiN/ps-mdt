<script lang="ts">
	/**
	 * Hold-to-talk radio button for use while the MDT is open.
	 *
	 * The MDT holds full NUI focus, so the game never sees a PTT keypress —
	 * which is why this is a button rather than a key listener. Press and hold
	 * to transmit, release to stop.
	 *
	 * Everything here is about not getting stuck transmitting. Pointer capture
	 * means a release outside the button still lands on it; pointercancel,
	 * blur and visibilitychange cover the cases where no release ever arrives
	 * at all (alt-tab, the MDT closing mid-press, the pointer being yanked away
	 * by the game). The client also drops the mic on its own if the MDT is no
	 * longer open, so a lost release costs at most a second.
	 */
	import { onMount, onDestroy } from "svelte";
	import { useNuiEvent } from "@/utils/useNuiEvent";
	import { NUI_EVENTS } from "@/constants/nuiEvents";
	import { fetchNui } from "@/utils/fetchNui";

	interface Props {
		/** Fires whenever the button is hovered, focused or held. */
		onActiveChange?: (active: boolean) => void;
	}

	let { onActiveChange }: Props = $props();

	let enabled = $state(false);
	let talking = $state(false);
	let hovered = $state(false);
	let focused = $state(false);

	// Like the search field, this has to hold the top bar at full opacity —
	// squinting at a fading bar while transmitting is exactly the wrong moment
	// for the UI to get out of the way.
	$effect(() => {
		onActiveChange?.(enabled && (hovered || focused || talking));
	});

	// The client pushes { enabled } when the MDT opens. It is false when the
	// radio is switched off in config or no voice resource is running — in
	// which case the button would do nothing, so it isn't rendered.
	useNuiEvent<{ enabled?: boolean }>(NUI_EVENTS.RADIO.CONFIG, (data) => {
		enabled = data?.enabled === true;
		if (!enabled) setTalking(false);
	});

	function setTalking(state: boolean) {
		if (state === talking) return;
		talking = state;
		fetchNui(NUI_EVENTS.RADIO.PTT, { talking: state }).catch(() => {});
	}

	function onPointerDown(event: PointerEvent) {
		if (!enabled || event.button !== 0) return;
		event.preventDefault();
		// Capture so the matching release is delivered here even if the cursor
		// has moved off the button by then — without this, dragging away while
		// holding leaves the mic open.
		(event.currentTarget as HTMLElement).setPointerCapture?.(event.pointerId);
		setTalking(true);
	}

	function onPointerUp(event: PointerEvent) {
		if (event.button !== 0 && event.type === "pointerup") return;
		(event.currentTarget as HTMLElement).releasePointerCapture?.(event.pointerId);
		setTalking(false);
	}

	/** Space and Enter hold the same way, but only while the button has focus. */
	function onKeyDown(event: KeyboardEvent) {
		if (!enabled || event.repeat) return;
		if (event.key === " " || event.key === "Enter") {
			event.preventDefault(); // stop the browser turning this into a click
			setTalking(true);
		}
	}

	function onKeyUp(event: KeyboardEvent) {
		if (event.key === " " || event.key === "Enter") setTalking(false);
	}

	function release() {
		setTalking(false);
	}

	function onLeave() {
		hovered = false;
		// Dragging off the button keeps transmitting thanks to pointer capture,
		// so the release below is what actually ends it on pointerup.
	}

	function onVisibility() {
		if (document.hidden) release();
	}

	onMount(() => {
		window.addEventListener("blur", release);
		document.addEventListener("visibilitychange", onVisibility);
	});

	onDestroy(() => {
		window.removeEventListener("blur", release);
		document.removeEventListener("visibilitychange", onVisibility);
		setTalking(false); // the MDT closing mid-press must not leave it open
		onActiveChange?.(false);
	});
</script>

{#if enabled}
	<button
		class="ptt"
		class:live={talking}
		type="button"
		data-hold-open
		aria-pressed={talking}
		aria-label={talking ? "Transmitting — release to stop" : "Hold to transmit on the radio"}
		onpointerdown={onPointerDown}
		onpointerup={onPointerUp}
		onpointercancel={onPointerUp}
		onkeydown={onKeyDown}
		onkeyup={onKeyUp}
		onmouseenter={() => (hovered = true)}
		onmouseleave={onLeave}
		onfocus={() => (focused = true)}
		onblur={() => { focused = false; release(); }}
		oncontextmenu={(e) => e.preventDefault()}
	>
		<!-- Inline rather than an icon font: ps-mdt loads material-icons, which has
		     no walkie-talkie, and Font Awesome's is a Pro icon. Drawn to match the
		     1.8px stroke weight used by the rest of the top bar. -->
		<svg class="ptt-icon" width="19" height="19" viewBox="0 0 24 24" fill="none"
			stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
			aria-hidden="true">
			<!-- antenna -->
			<path d="M16 7V3.5" />
			<!-- body -->
			<rect x="6" y="7" width="12" height="14" rx="2" />
			<!-- speaker grille -->
			<path d="M9 11h6" />
			<path d="M9 14h6" />
			<!-- push-to-talk key on the side -->
			<path d="M6 12v3" />
			<!-- transmit arcs, only while live -->
			{#if talking}
				<path class="ptt-wave ptt-wave-1" d="M18.2 4.9a4 4 0 0 1 2.9 2.9" />
				<path class="ptt-wave ptt-wave-2" d="M18.6 2.1a7 7 0 0 1 5.1 5.1" />
			{/if}
		</svg>
		<span class="ptt-text">
			<span class="ptt-label">{talking ? "On air" : "Radio"}</span>
			<span class="ptt-hint">{talking ? "Release to stop" : "Hold to talk"}</span>
		</span>
	</button>
{/if}

<style>
	.ptt {
		display: inline-flex;
		align-items: center;
		gap: 9px;
		padding: 6px 13px 6px 10px;
		border-radius: 8px;
		font-family: inherit;
		cursor: pointer;
		flex-shrink: 0;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.08);
		transition:
			background 0.12s ease,
			border-color 0.12s ease;
		/* A held button must not start a text selection or a drag. */
		user-select: none;
		-webkit-user-select: none;
		touch-action: none;
	}

	.ptt:hover {
		background: rgba(255, 255, 255, 0.07);
		border-color: rgba(255, 255, 255, 0.15);
	}

	/* Live is deliberately loud: the one thing worse than not transmitting is
	   transmitting without realising it. */
	.ptt.live,
	.ptt.live:hover {
		background: rgba(239, 68, 68, 0.14);
		border-color: rgba(239, 68, 68, 0.5);
	}

	.ptt-icon {
		flex: none;
		color: rgba(255, 255, 255, 0.45);
		transition: color 0.12s ease;
	}

	/* The arcs stagger outward so the icon reads as actively transmitting
	   rather than simply changing colour. */
	.ptt-wave {
		animation: ptt-wave 1.2s ease-out infinite;
	}

	.ptt-wave-2 {
		animation-delay: 0.2s;
	}

	.ptt.live .ptt-icon {
		color: rgb(248, 113, 113);
	}

	.ptt-text {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 1px;
		line-height: 1.1;
	}

	.ptt-label {
		font-size: 12px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.75);
	}

	.ptt.live .ptt-label {
		color: rgb(252, 165, 165);
	}

	.ptt-hint {
		font-size: 9px;
		font-weight: 600;
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: rgba(255, 255, 255, 0.3);
	}

	.ptt.live .ptt-hint {
		color: rgba(252, 165, 165, 0.6);
	}

	@keyframes ptt-wave {
		0% { opacity: 0.15; }
		45% { opacity: 1; }
		100% { opacity: 0.15; }
	}

	:global(.mdt-reduced-motion) .ptt-wave {
		animation: none;
		opacity: 1;
	}
</style>