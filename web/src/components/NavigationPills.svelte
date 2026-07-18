<script lang="ts">
	import { MDT_TABS, NAV_GROUPS, DOJ_NAV_GROUPS, getTabsForJob, getTabLabel, type MDTTab, type ComponentId } from "../constants";
	import type { createTabService } from "../services/tabService.svelte";
	import type { JobType } from "../interfaces/IUser";
	import type { AuthService } from "../services/authService.svelte";

	interface Props {
		tabService: ReturnType<typeof createTabService>;
		jobType?: JobType;
		authService?: AuthService;
	}

	let { tabService, jobType = 'leo', authService }: Props = $props();

	// Tooltip for the collapsed sidebar. Appended to <body> and positioned fixed because
	// the nav column clips horizontally (overflow-x: hidden) — an in-flow tooltip would be
	// cut off — and CEF doesn't render native `title` attributes at all.
	function tip(node: HTMLElement, text: string | undefined) {
		let el: HTMLDivElement | null = null;
		let cur = text;
		function place(e: MouseEvent) {
			if (!el) return;
			const t = el.getBoundingClientRect();
			let x = e.clientX + 14;
			let y = e.clientY + 16;
			if (x + t.width > window.innerWidth - 4) x = e.clientX - t.width - 14;
			if (y + t.height > window.innerHeight - 4) y = e.clientY - t.height - 16;
			el.style.left = `${Math.max(4, x)}px`;
			el.style.top = `${Math.max(4, y)}px`;
		}
		function show(e: MouseEvent) {
			if (!cur || el) return;
			el = document.createElement("div");
			el.textContent = cur;
			el.style.cssText = "position:fixed;z-index:99999;background:#111113;color:rgba(255,255,255,0.92);padding:6px 9px;border-radius:5px;font-size:11px;font-weight:500;line-height:1.4;white-space:nowrap;border:1px solid rgba(255,255,255,0.12);box-shadow:0 8px 24px rgba(0,0,0,0.6);pointer-events:none;";
			document.body.appendChild(el);
			place(e);
		}
		function move(e: MouseEvent) { if (el) place(e); }
		function hide() { if (el) { el.remove(); el = null; } }
		node.addEventListener("mouseenter", show);
		node.addEventListener("mousemove", move);
		node.addEventListener("mouseleave", hide);
		return {
			update(v: string | undefined) { cur = v; if (el && !v) hide(); },
			destroy() { hide(); node.removeEventListener("mouseenter", show); node.removeEventListener("mousemove", move); node.removeEventListener("mouseleave", hide); },
		};
	}

	function isTabHidden(tabName: string): boolean {
		if (!authService) return false;
		const key = `tab_hidden_${tabName.toLowerCase()}`;
		return authService.hasRawPermission(key);
	}

	let visibleTabs = $derived(getTabsForJob(jobType).filter(t => !isTabHidden(t.name)));
	let visibleTabNames = $derived(new Set(visibleTabs.map(t => t.name)));

	let collapsed = $state(false);
	let collapsedGroups = $state<Record<string, boolean>>({});

	function collapseSidebar() {
		collapsed = !collapsed;
	}

	function toggleGroup(groupId: string) {
		collapsedGroups[groupId] = !collapsedGroups[groupId];
	}

	function handleTabClick(tab: { name: string; icon: string }) {
		const activeInstance = tabService.getActiveInstance();
		if (activeInstance) {
			tabService.setInstanceTab(activeInstance.id, tab.name as MDTTab);
		} else {
			tabService.setActiveTab(tab.name as MDTTab);
		}
	}

	function getTabData(tabName: string) {
		return MDT_TABS.find(t => t.name === tabName);
	}

	// Compute visible groups: filter out groups with no visible tabs
	let navGroups = $derived(jobType === 'doj' ? DOJ_NAV_GROUPS : NAV_GROUPS);

	let visibleGroups = $derived.by(() => {
		return navGroups
			.map(group => ({
				...group,
				visibleTabs: group.tabs.filter(t => visibleTabNames.has(t)),
			}))
			.filter(g => g.visibleTabs.length > 0);
	});

	let activeTab = $derived(tabService.getActiveInstanceTab());
	$effect(() => {
		if (!activeTab) return;
		if (!visibleTabNames.has(activeTab)) {
			const inst = tabService.getActiveInstance();
			if (inst) tabService.setInstanceTab(inst.id, "Dashboard");
			return;
		}
		for (const group of navGroups) {
			if (group.label && group.tabs.includes(activeTab)) {
				if (collapsedGroups[group.id]) {
					collapsedGroups[group.id] = false;
				}
				break;
			}
		}
	});

	function isGroupCollapsed(groupId: string): boolean {
		return collapsedGroups[groupId] ?? false;
	}
</script>

<div class="nav-pills" class:collapsed>
	{#each visibleGroups as group}
		{#if group.label && !collapsed}
			<!-- Collapsible group with header -->
			<div class="nav-group">
				<button class="nav-group-header" onclick={() => toggleGroup(group.id)}>
					<span class="material-icons nav-group-icon">{group.icon}</span>
					<span class="nav-group-label">{group.label}</span>
					{#if isGroupCollapsed(group.id) && group.visibleTabs.some((t) => t === activeTab)}
						<!-- The active tab lives inside this collapsed group; without this the
						     current location would vanish entirely from the sidebar. -->
						<span class="nav-group-dot"></span>
					{/if}
					<span class="material-icons nav-group-chevron" class:rotated={!isGroupCollapsed(group.id)}>expand_more</span>
				</button>
				{#if !isGroupCollapsed(group.id)}
					<div class="nav-group-items">
						{#each group.visibleTabs as tabName}
							{@const tab = getTabData(tabName)}
							{#if tab}
								<button
									class="nav-pill grouped"
									class:active={activeTab === tab.name}
									onclick={() => handleTabClick(tab)}
								>
									<span class="material-icons nav-icon">{tab.icon}</span>
									<span>{getTabLabel(tab.name)}</span>
								</button>
							{/if}
						{/each}
					</div>
				{/if}
			</div>
		{:else}
			<!-- Ungrouped items (Dashboard, Preferences, Settings) or collapsed sidebar -->
			{#each group.visibleTabs as tabName}
				{@const tab = getTabData(tabName)}
				{#if tab}
					<button
						class="nav-pill"
						class:active={activeTab === tab.name}
						onclick={() => handleTabClick(tab)}
						use:tip={collapsed ? getTabLabel(tab.name) : undefined}
					>
						<span class="material-icons nav-icon">{tab.icon}</span>
						<span class:hide={collapsed}>{getTabLabel(tab.name)}</span>
					</button>
				{/if}
			{/each}
		{/if}
	{/each}

	<button
		class="nav-pill collapse-button"
		onclick={collapseSidebar}
		use:tip={collapsed ? "Expand sidebar" : undefined}
	>
		<span class="material-icons nav-icon"
			>{collapsed
				? "keyboard_double_arrow_right"
				: "keyboard_double_arrow_left"}</span
		>
		{collapsed ? "" : "Collapse"}
	</button>
</div>

<style>
	.hide {
		display: none;
	}

	.nav-pills {
		display: flex;
		flex-direction: column;
		height: 100%;
		overflow-y: auto;
		overflow-x: hidden;
		scrollbar-width: none;
		padding: 4px 0 0;
	}

	.nav-pills::-webkit-scrollbar {
		display: none;
	}

	/* Full-bleed rows with a 3px rail down the left edge. The rail is present on every row
	   (just transparent) so nothing shifts sideways when the selection moves. */
	.nav-pill {
		position: relative;
		display: flex;
		align-items: center;
		gap: 11px;
		width: 100%;
		padding: 9px 18px 9px 17px;
		border: none;
		border-left: 3px solid transparent;
		border-radius: 0;
		background: none;
		color: rgba(255, 255, 255, 0.5);
		font-size: 12.5px;
		text-align: left;
		cursor: pointer;
		flex-shrink: 0;
		transition:
			background 0.12s ease,
			border-color 0.12s ease,
			color 0.12s ease;
	}

	.nav-icon {
		font-size: 18px;
		flex-shrink: 0;
		opacity: 0.65;
		transition:
			opacity 0.12s ease,
			color 0.12s ease;
	}

	/* Hover previews the selection: the rail lights up faintly, so the row tells you what
	   clicking it will look like. */
	.nav-pill:hover {
		background: rgba(255, 255, 255, 0.035);
		border-left-color: rgba(255, 255, 255, 0.14);
		color: rgba(255, 255, 255, 0.88);
	}
	.nav-pill:hover .nav-icon {
		opacity: 1;
	}

	/* Active: accent rail, accent-tinted row, accent icon, and a short inward glow off the
	   rail so the row reads as lit rather than merely filled. */
	.nav-pill.active {
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.11);
		border-left-color: rgb(var(--accent-rgb, 56, 189, 248));
		color: rgba(255, 255, 255, 0.97);
		font-weight: 500;
		box-shadow: inset 10px 0 16px -13px rgb(var(--accent-rgb, 56, 189, 248));
	}
	.nav-pill.active .nav-icon {
		opacity: 1;
		color: rgb(var(--accent-rgb, 56, 189, 248));
	}
	.nav-pill.active:hover {
		background: rgba(var(--accent-rgb, 56, 189, 248), 0.16);
	}

	/* ===== DOMAIN IDENTITIES ===== */
	:global([data-job-type="ems"]) .nav-pill:hover {
		background: rgba(220, 50, 50, 0.06);
	}
	:global([data-job-type="ems"]) .nav-pill.active {
		background: rgba(220, 50, 50, 0.12);
		border-left-color: rgb(239, 68, 68);
		box-shadow: inset 10px 0 16px -13px rgb(239, 68, 68);
	}
	:global([data-job-type="ems"]) .nav-pill.active .nav-icon {
		color: rgba(252, 165, 165, 0.95);
	}
	:global([data-job-type="ems"]) .nav-pill.active:hover {
		background: rgba(220, 50, 50, 0.17);
	}
	:global([data-job-type="ems"]) .nav-group-dot {
		background: rgb(239, 68, 68);
	}

	:global([data-job-type="doj"]) .nav-pill:hover {
		background: rgba(180, 150, 60, 0.06);
	}
	:global([data-job-type="doj"]) .nav-pill.active {
		background: rgba(180, 150, 60, 0.12);
		border-left-color: rgb(196, 165, 80);
		box-shadow: inset 10px 0 16px -13px rgb(196, 165, 80);
	}
	:global([data-job-type="doj"]) .nav-pill.active .nav-icon {
		color: rgba(212, 190, 130, 0.95);
	}
	:global([data-job-type="doj"]) .nav-pill.active:hover {
		background: rgba(180, 150, 60, 0.17);
	}
	:global([data-job-type="doj"]) .nav-group-dot {
		background: rgb(196, 165, 80);
	}

	/* ===== GROUPS ===== */
	.nav-group {
		display: flex;
		flex-direction: column;
	}

	.nav-group-header {
		display: flex;
		align-items: center;
		gap: 8px;
		width: 100%;
		padding: 7px 18px 7px 20px;
		margin: 6px 0 0;
		background: none;
		border: none;
		border-radius: 0;
		color: rgba(255, 255, 255, 0.26);
		font-size: 9px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.9px;
		cursor: pointer;
		transition: color 0.12s ease;
	}

	.nav-group-header:hover {
		color: rgba(255, 255, 255, 0.55);
	}

	.nav-group-icon {
		font-size: 13px;
		opacity: 0.55;
	}

	.nav-group-label {
		flex: 1;
		text-align: left;
	}

	/* Marks a collapsed group that holds the current tab. */
	.nav-group-dot {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		flex-shrink: 0;
		background: rgb(var(--accent-rgb, 56, 189, 248));
	}

	/* The chevron is structural, not informative — keep it quiet until the header is
	   hovered, so the section labels stay clean. */
	.nav-group-chevron {
		font-size: 15px;
		opacity: 0.35;
		transition:
			transform 0.18s ease,
			opacity 0.12s ease;
		transform: rotate(-90deg);
	}
	.nav-group-header:hover .nav-group-chevron {
		opacity: 0.8;
	}

	.nav-group-chevron.rotated {
		transform: rotate(0deg);
	}

	.nav-group-items {
		display: flex;
		flex-direction: column;
	}

	/* Children sit one indent in and a notch smaller. */
	.nav-pill.grouped {
		padding-left: 33px;
		font-size: 12px;
	}
	.nav-pill.grouped .nav-icon {
		font-size: 16px;
	}

	/* ===== COLLAPSED ===== */
	.nav-pills.collapsed .nav-pill {
		justify-content: center;
		padding-left: 13px;
		padding-right: 16px;
		gap: 0;
	}

	/* ===== COLLAPSE BUTTON ===== */
	/* A control, not a destination: kept at the bottom behind its own rule, and it never
	   lights its rail on hover the way a tab does. */
	.collapse-button {
		margin-top: auto;
		margin-bottom: 6px;
		padding-top: 12px;
		padding-bottom: 12px;
		color: rgba(255, 255, 255, 0.28);
		font-size: 12px;
	}
	.collapse-button::before {
		content: "";
		position: absolute;
		top: 0;
		left: 14px;
		right: 14px;
		height: 1px;
		background: rgba(255, 255, 255, 0.05);
	}
	.collapse-button:hover {
		background: rgba(255, 255, 255, 0.03);
		border-left-color: transparent;
		color: rgba(255, 255, 255, 0.62);
	}
	.collapse-button .nav-icon {
		font-size: 17px;
	}
</style>