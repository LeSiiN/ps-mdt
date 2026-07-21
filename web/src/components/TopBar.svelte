<script lang="ts">
	import { onMount } from "svelte";
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";
	import {
		DEFAULT_TIME,
		DEFAULT_DATE,
		TIMING,
		getAppInfo,
	} from "../constants";
	import { formatTime, formatDate } from "../utils/datetime";
	import { useNuiEvent } from "@/utils/useNuiEvent";

	import type { AuthService } from "../services/authService.svelte";

	import type { TabService } from "../services/tabService.svelte";
	import type { MDTTab } from "../constants";

	interface Props {
		authService: AuthService;
		tabService: TabService;
		onOpacityStyleChange: (opacityStyle: string) => void;
	}

	let { authService, tabService, onOpacityStyleChange }: Props = $props();

	// Below the props on purpose: a $derived reading authService before it is
	// declared only worked because deriveds evaluate lazily, on first render.
	let info = $derived(getAppInfo(authService.jobType));

	// ── Global search ──
	// A plate could be a vehicle, a BOLO or a report; a name could be a citizen or a
	// warrant. Officers had to guess which tab to look in. This asks all of them.
	interface SearchHit {
		type: "citizen" | "vehicle" | "report" | "warrant" | "bolo" | "case" | "weapon" | "evidence";
		id: string | number;
		label: string;
		sub?: string;
		icon?: string;
		/** Only citizens and vehicles carry one — they're the two you identify by sight. */
		image?: string;
	}

	// Hover, not click: clicking a result is how you open it, and a click that sometimes
	// zooms and sometimes navigates would be a coin toss. Hovering costs nothing and
	// undoes itself.
	let preview = $state<{ url: string; label: string } | null>(null);

	const TYPE_LABEL: Record<SearchHit["type"], string> = {
		warrant: "Warrants",
		bolo: "BOLOs",
		citizen: "Citizens",
		vehicle: "Vehicles",
		report: "Reports",
		case: "Cases",
		weapon: "Weapons",
		evidence: "Evidence",
	};

	// Where each hit sends you. A warrant opens its report — that's where the detail is,
	// and it's what clicking a warrant in the Warrants tab already does.
	const TYPE_TAB: Record<SearchHit["type"], MDTTab> = {
		warrant: "Reports",
		bolo: "BOLOs",
		citizen: "Citizens",
		vehicle: "Vehicles",
		report: "Reports",
		case: "Cases",
		weapon: "Weapons",
		evidence: "Evidence",
	};

	// Warrants and BOLOs are things somebody is meant to ACT on. They lead, and they
	// look like it — everything else is reference material.
	const URGENT = new Set<SearchHit["type"]>(["warrant", "bolo"]);

	let searchQuery = $state("");
	let searchHits = $state<SearchHit[]>([]);
	let searchOpen = $state(false);
	let searchBusy = $state(false);
	let activeHit = $state(-1);
	let searchSeq = 0;

	// Grouped so the dropdown reads as "3 citizens, 1 vehicle" rather than a flat list.
	let grouped = $derived.by(() => {
		const order: SearchHit["type"][] = [
			"warrant", "bolo",
			"citizen", "vehicle", "report", "case", "weapon", "evidence",
		];
		return order
			.map((t) => ({ type: t, items: searchHits.filter((h) => h.type === t) }))
			.filter((g) => g.items.length > 0);
	});

	// Flat order must match what's rendered, or the arrow keys select the wrong row.
	let flatHits = $derived(grouped.flatMap((g) => g.items));

	let debounce: ReturnType<typeof setTimeout> | null = null;

	function onSearchInput() {
		if (debounce) clearTimeout(debounce);
		activeHit = -1;
		// The row this belonged to is about to be replaced.
		preview = null;

		const q = searchQuery.trim();
		// Matches the server's minimum; two characters matches half the database.
		if (q.length < 3) {
			searchHits = [];
			searchOpen = false;
			searchBusy = false;
			return;
		}

		searchOpen = true;
		searchBusy = true;
		// Firing on every keystroke would put one query per letter on the database.
		debounce = setTimeout(() => runSearch(q), 220);
	}

	async function runSearch(q: string) {
		// Responses can land out of order; only the newest one may write.
		const seq = ++searchSeq;
		try {
			const res = await fetchNui<{ results: SearchHit[] }>(
				NUI_EVENTS.SEARCH.GLOBAL_SEARCH,
				{ query: q },
				{ results: [] },
			);
			if (seq !== searchSeq) return;
			searchHits = res?.results ?? [];
		} catch {
			if (seq !== searchSeq) return;
			searchHits = [];
		} finally {
			if (seq === searchSeq) searchBusy = false;
		}
	}

	function openHit(hit: SearchHit) {
		tabService.openWithTarget(TYPE_TAB[hit.type], hit.id);
		closeSearch();
	}

	function closeSearch() {
		searchOpen = false;
		searchQuery = "";
		searchHits = [];
		activeHit = -1;
		// The preview only LOOKS gone when the dropdown closes — it lives inside it. Left
		// set, it reappeared over the next search, showing the previous search's photo.
		preview = null;
	}

	function onSearchKey(e: KeyboardEvent) {
		if (e.key === "Escape") { closeSearch(); return; }
		if (!searchOpen || flatHits.length === 0) return;

		if (e.key === "ArrowDown") {
			e.preventDefault();
			activeHit = (activeHit + 1) % flatHits.length;
		} else if (e.key === "ArrowUp") {
			e.preventDefault();
			activeHit = activeHit <= 0 ? flatHits.length - 1 : activeHit - 1;
		} else if (e.key === "Enter") {
			e.preventDefault();
			openHit(flatHits[activeHit >= 0 ? activeHit : 0]);
		}
	}

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

	/**
	 * Hovering the top bar fades the MDT to 25% so the officer can see the road
	 * underneath. That was fine when the bar was only something you read. Now it's
	 * where you type — and the fade fires on ENTERING the bar, which is exactly the
	 * motion you make to reach the search box. Gating on "is the search open" was no
	 * use: at the moment the pointer crosses into the bar, it isn't open yet.
	 *
	 * So the trigger is the pointer and the caret, not the state of the results:
	 * anywhere inside the search area — the dropdown is a child of it, so it counts —
	 * or a focused input means the officer is working, and nothing fades.
	 */
	let searchHovered = $state(false);
	let searchFocused = $state(false);

	let searchActive = $derived(
		searchHovered || searchFocused || searchOpen || searchQuery.length > 0,
	);

	function handleTopBarEnter() {
		if (opacityTimeout) {
			clearTimeout(opacityTimeout);
			opacityTimeout = null;
		}
		if (searchActive) return;
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

	// Reaching the search from an already-faded bar has to bring it back at once, not
	// wait for the pointer to leave and the timer to run out.
	$effect(() => {
		if (searchActive) {
			if (opacityTimeout) {
				clearTimeout(opacityTimeout);
				opacityTimeout = null;
			}
			documentOpacity = 1;
		}
	});

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

			<!-- A citizen has no callsign and is never on duty. Showing them "Unassigned"
			     and "Off duty" isn't neutral — it implies they're an officer who simply
			     hasn't been given one. -->
			{#if !authService.isCivilian}
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
			{/if}

			<!-- Civilians never see this. CheckAuth already refuses them server-side, but a
			     search box that always returns nothing is worse than no search box. -->
			{#if !authService.isCivilian}
			<!-- svelte-ignore a11y_no_static_element_interactions -->
			<div
				class="tb-search"
				onmouseenter={() => (searchHovered = true)}
				onmouseleave={() => (searchHovered = false)}
			>
				<span class="material-icons tb-search-icon">search</span>
				<input
					type="text"
					placeholder="Search name, plate, report…"
					bind:value={searchQuery}
					oninput={onSearchInput}
					onkeydown={onSearchKey}
					onfocus={() => {
						searchFocused = true;
						if (searchHits.length) searchOpen = true;
					}}
					onblur={() => (searchFocused = false)}
				/>
				{#if searchQuery}
					<button class="tb-search-clear" aria-label="Clear search" onclick={closeSearch}>
						<span class="material-icons">close</span>
					</button>
				{/if}

				{#if searchOpen}
					<div class="tb-results">
						{#if searchBusy && flatHits.length === 0}
							<div class="tb-results-msg">Searching…</div>
						{:else if flatHits.length === 0}
							<div class="tb-results-msg">Nothing found for “{searchQuery}”.</div>
						{:else}
							{#each grouped as group (group.type)}
								{@const urgent = URGENT.has(group.type)}
								<div class="tb-group" class:urgent>
									{TYPE_LABEL[group.type]}
									{#if urgent}<span class="tb-group-count">{group.items.length}</span>{/if}
								</div>
								{#each group.items as hit (`${hit.type}-${hit.id}`)}
									{@const idx = flatHits.indexOf(hit)}
									<button
										class="tb-hit"
										class:urgent
										class:active={idx === activeHit}
										onmouseenter={() => (activeHit = idx)}
										onclick={() => openHit(hit)}
									>
										{#if hit.image}
											<!-- svelte-ignore a11y_no_static_element_interactions -->
											<span
												class="tb-hit-thumb"
												onmouseenter={() => (preview = { url: hit.image!, label: hit.label })}
												onmouseleave={() => (preview = null)}
											>
												<img src={hit.image} alt="" />
											</span>
										{:else}
											<span class="material-icons tb-hit-icon">{hit.icon ?? "search"}</span>
										{/if}
										<span class="tb-hit-text">
											<span class="tb-hit-label">{hit.label}</span>
											{#if hit.sub}<span class="tb-hit-sub">{hit.sub}</span>{/if}
										</span>
										<span class="material-icons tb-hit-go">chevron_right</span>
									</button>
								{/each}
							{/each}
						{/if}
					</div>

					<!-- OUTSIDE .tb-results on purpose. Nested inside it, the preview was a
					     child of a scrolling, clipping container: it scrolled away with the
					     list and got cut off at the edge. Anchored to .tb-search instead, it
					     sits beside the dropdown and stays put. -->
					{#if preview}
						<div class="tb-preview">
							<img src={preview.url} alt={preview.label} />
							<span>{preview.label}</span>
						</div>
					{/if}
				{/if}
			</div>
			{/if}
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

	/* Search sits with the identity block, not the clock — it's a thing you do, not a
	   thing you read. */
	.tb-search {
		position: relative;
		display: flex;
		align-items: center;
		flex-shrink: 0;
		width: 230px;
		margin-left: 4px;
	}
	.tb-search-icon {
		position: absolute;
		left: 8px;
		font-size: 15px;
		color: rgba(255, 255, 255, 0.25);
		pointer-events: none;
	}
	.tb-search input {
		width: 100%;
		height: 30px;
		box-sizing: border-box;
		padding: 0 28px;
		border-radius: 5px;
		border: 1px solid rgba(255, 255, 255, 0.07);
		background: rgba(255, 255, 255, 0.03);
		color: rgba(255, 255, 255, 0.85);
		font-size: 11px;
		font-family: inherit;
	}
	.tb-search input::placeholder { color: rgba(255, 255, 255, 0.25); }
	.tb-search input:focus {
		outline: none;
		border-color: var(--accent-30);
		background: rgba(255, 255, 255, 0.05);
	}
	.tb-search-clear {
		position: absolute;
		right: 6px;
		display: flex;
		padding: 2px;
		border: none;
		background: none;
		color: rgba(255, 255, 255, 0.3);
		cursor: pointer;
	}
	.tb-search-clear:hover { color: rgba(255, 255, 255, 0.9); }
	.tb-search-clear .material-icons { font-size: 14px; }

	.tb-results {
		position: absolute;
		top: calc(100% + 6px);
		left: 0;
		width: 340px;
		max-height: 380px;
		overflow-y: auto;
		z-index: 10;
		padding: 4px;
		border-radius: 6px;
		border: 1px solid rgba(255, 255, 255, 0.08);
		/* Solid, not translucent: backdrop-filter renders as a black block in CEF. */
		background: rgb(20, 21, 23);
		box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55);
	}
	.tb-results::-webkit-scrollbar { width: 5px; }
	.tb-results::-webkit-scrollbar-thumb {
		background: rgba(255, 255, 255, 0.08);
		border-radius: 3px;
	}

	.tb-group {
		padding: 6px 8px 3px;
		font-size: 8px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.8px;
		color: rgba(255, 255, 255, 0.28);
	}

	/* Warrants and BOLOs are the two things that mean "do something now". They sit at
	   the top and carry a red edge; everything else is reference material and stays
	   quiet, or nothing stands out at all. */
	.tb-group.urgent {
		display: flex;
		align-items: center;
		gap: 5px;
		color: rgba(248, 113, 113, 0.85);
	}
	.tb-group-count {
		display: inline-grid;
		place-items: center;
		min-width: 13px;
		height: 13px;
		padding: 0 3px;
		border-radius: 7px;
		background: rgba(239, 68, 68, 0.2);
		color: rgba(252, 165, 165, 1);
		font-size: 8px;
		font-weight: 700;
	}

	.tb-hit.urgent {
		border-left: 2px solid rgba(239, 68, 68, 0.5);
		border-radius: 0 4px 4px 0;
		background: rgba(239, 68, 68, 0.05);
	}
	.tb-hit.urgent .tb-hit-icon { color: rgba(248, 113, 113, 0.8); }
	.tb-hit.urgent .tb-hit-label { color: rgba(254, 226, 226, 0.95); font-weight: 600; }
	.tb-hit.urgent.active {
		background: rgba(239, 68, 68, 0.15);
		border-left-color: rgba(239, 68, 68, 0.9);
	}
	.tb-hit.urgent.active .tb-hit-icon { color: rgba(252, 165, 165, 1); }

	.tb-hit {
		display: flex;
		align-items: center;
		gap: 9px;
		width: 100%;
		padding: 7px 8px;
		border: none;
		border-radius: 4px;
		background: none;
		text-align: left;
		cursor: pointer;
		font-family: inherit;
	}
	.tb-hit.active { background: rgba(255, 255, 255, 0.06); }
	/* A thumbnail sits where the icon would, so rows with and without one still line up. */
	.tb-hit-thumb {
		flex-shrink: 0;
		width: 28px;
		height: 28px;
		border-radius: 4px;
		overflow: hidden;
		border: 1px solid rgba(255, 255, 255, 0.1);
		background: rgba(255, 255, 255, 0.04);
	}
	.tb-hit-thumb img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}

	/* Sits beside the dropdown, not over it — covering the list you're reading to show
	   one row of it would be self-defeating. */
	.tb-preview {
		position: absolute;
		top: 0;
		left: calc(100% + 8px);
		width: 260px;
		padding: 6px;
		border-radius: 6px;
		border: 1px solid rgba(255, 255, 255, 0.1);
		background: rgb(20, 21, 23);
		box-shadow: 0 16px 40px rgba(0, 0, 0, 0.6);
		pointer-events: none;
		z-index: 11;
	}
	.tb-preview img {
		width: 100%;
		border-radius: 4px;
		display: block;
		object-fit: cover;
		max-height: 240px;
	}
	.tb-preview span {
		display: block;
		margin-top: 5px;
		text-align: center;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.6);
	}

	.tb-hit-icon {
		flex-shrink: 0;
		font-size: 16px;
		color: rgba(255, 255, 255, 0.35);
	}
	.tb-hit.active .tb-hit-icon { color: var(--accent-70); }
	.tb-hit-text {
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-width: 0;
		flex: 1;
	}
	.tb-hit-label {
		font-size: 12px;
		font-weight: 500;
		color: rgba(255, 255, 255, 0.9);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.tb-hit-sub {
		font-size: 10px;
		color: rgba(255, 255, 255, 0.35);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.tb-hit-go {
		flex-shrink: 0;
		font-size: 15px;
		color: rgba(255, 255, 255, 0.15);
	}
	.tb-hit.active .tb-hit-go { color: rgba(255, 255, 255, 0.5); }

	.tb-results-msg {
		padding: 14px 10px;
		text-align: center;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.3);
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
		/* The top bar is chrome — it belongs above the page, always. At z-index 10 it lost
		   to the Map tab, whose Leaflet layers and overlays run up to 1500, so the search
		   dropdown was drawn UNDER the map and you only saw the top half of it. This is a
		   stacking context, so everything inside (dropdown, preview) rides along. */
		z-index: 2000;
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