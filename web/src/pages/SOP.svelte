<script lang="ts">
	import { onMount } from "svelte";
	import { fetchNui } from "../utils/fetchNui";
	import { NUI_EVENTS } from "../constants/nuiEvents";
	import type { AuthService } from "../services/authService.svelte";

	interface SOPSection {
		id: number;
		title: string;
		content: string;
		sort_order: number;
	}

	interface SOPCategory {
		id: number;
		title: string;
		icon: string;
		sort_order: number;
		sections: SOPSection[];
	}

	interface SOPSettings {
		mission_statement?: string;
		introduction?: string;
		version?: number;
	}

	interface AgreementState {
		agreed?: boolean;
		currentVersion?: number;
	}

	let { authService }: { authService?: AuthService } = $props();

	let categories = $state<SOPCategory[]>([]);
	let sopSettings = $state<SOPSettings>({});
	let agreement = $state<AgreementState>({});
	// null = the overview (mission + introduction), otherwise a category id.
	let selectedCategoryId = $state<number | null>(null);
	let searchQuery = $state("");
	let loading = $state(true);
	let activeSectionId = $state<number | null>(null);
	let contentEl = $state<HTMLElement | null>(null);

	let hasOverview = $derived(
		!!(sopSettings.mission_statement?.trim() || sopSettings.introduction?.trim()),
	);
	let selectedCategory = $derived(categories.find((c) => c.id === selectedCategoryId) || null);
	let query = $derived(searchQuery.trim().toLowerCase());

	// Search matches section bodies as well as titles, so the sidebar lists the
	// sections that actually hit — otherwise you're told a category matches but not
	// where, and you have to read the whole thing to find out.
	let filteredCategories = $derived.by(() => {
		if (!query) return categories;
		return categories
			.map((cat) => ({
				...cat,
				sections: cat.sections.filter(
					(s) =>
						s.title.toLowerCase().includes(query) ||
						stripHtml(s.content).toLowerCase().includes(query),
				),
			}))
			.filter((cat) => cat.title.toLowerCase().includes(query) || cat.sections.length > 0);
	});

	let matchCount = $derived(
		query ? filteredCategories.reduce((n, c) => n + c.sections.length, 0) : 0,
	);

	// The sections shown in the content pane: narrowed to the matches while searching.
	let visibleSections = $derived.by(() => {
		if (!selectedCategory) return [];
		if (!query) return selectedCategory.sections;
		const match = filteredCategories.find((c) => c.id === selectedCategory.id);
		return match ? match.sections : [];
	});

	function stripHtml(html: string): string {
		return html.replace(/<[^>]*>/g, " ");
	}

	function escapeRegExp(s: string): string {
		return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	}

	/**
	 * Highlight the search term inside rich text without breaking it.
	 * Only the text between tags is touched — never a tag or an attribute — so an
	 * SOP written with links, tables or images survives being searched.
	 */
	function highlight(html: string): string {
		if (!query) return html;
		const re = new RegExp(`(${escapeRegExp(query)})`, "gi");
		return html.replace(/>([^<]+)</g, (_m, text: string) =>
			">" + text.replace(re, "<mark>$1</mark>") + "<",
		);
	}

	function highlightText(text: string): string {
		if (!query) return escapeHtml(text);
		const re = new RegExp(`(${escapeRegExp(query)})`, "gi");
		return escapeHtml(text).replace(re, "<mark>$1</mark>");
	}

	function escapeHtml(s: string): string {
		return s
			.replace(/&/g, "&amp;")
			.replace(/</g, "&lt;")
			.replace(/>/g, "&gt;");
	}

	function openSection(categoryId: number, sectionId: number) {
		selectedCategoryId = categoryId;
		// Wait for the category to render before scrolling to the section.
		requestAnimationFrame(() => scrollToSection(sectionId));
	}

	function scrollToSection(sectionId: number) {
		const el = document.getElementById(`sop-section-${sectionId}`);
		if (!el || !contentEl) return;
		contentEl.scrollTo({ top: el.offsetTop - 12, behavior: "smooth" });
		activeSectionId = sectionId;
	}

	// Keep the table of contents in step with what's actually on screen.
	function onContentScroll() {
		if (!contentEl || visibleSections.length === 0) return;
		const top = contentEl.scrollTop + 40;
		let current: number | null = visibleSections[0].id;
		for (const s of visibleSections) {
			const el = document.getElementById(`sop-section-${s.id}`);
			if (el && el.offsetTop <= top) current = s.id;
		}
		activeSectionId = current;
	}

	function backToTop() {
		contentEl?.scrollTo({ top: 0, behavior: "smooth" });
	}

	onMount(async () => {
		await Promise.all([loadCategories(), loadSettings(), loadAgreement()]);
	});

	async function loadSettings() {
		try {
			const result = await fetchNui<SOPSettings>(NUI_EVENTS.SOP.GET_SOP_SETTINGS, {}, {});
			sopSettings = result || {};
		} catch {
			sopSettings = {};
		}
	}

	// Which version this officer signed off on. The MDT already forces an agreement
	// on open; showing it here means you can tell at a glance whether what you're
	// reading is the version you agreed to.
	async function loadAgreement() {
		try {
			const result = await fetchNui<AgreementState>(
				NUI_EVENTS.SOP.CHECK_SOP_AGREEMENT,
				{},
				{},
			);
			agreement = result || {};
		} catch {
			agreement = {};
		}
	}

	async function loadCategories() {
		loading = true;
		try {
			const result = await fetchNui<SOPCategory[]>(NUI_EVENTS.SOP.GET_SOP_CATEGORIES, {}, []);
			categories = result || [];
		} catch {
			categories = [];
		} finally {
			loading = false;
		}
	}

	// Land on the overview when there is one, otherwise the first category.
	$effect(() => {
		if (loading || selectedCategoryId !== null) return;
		if (hasOverview) return; // null already means overview
		if (categories.length > 0) selectedCategoryId = categories[0].id;
	});
</script>

<div class="sop-page">
	<aside class="sop-sidebar">
		<div class="sidebar-header">
			<span class="material-icons header-icon">menu_book</span>
			<div class="header-text">
				<h2>Standard Operating Procedures</h2>
				{#if sopSettings.version}
					<span class="version-line">
						Version {sopSettings.version}
						{#if agreement.agreed}
							<span class="ack-pill ack-ok" title="You have acknowledged this version">Acknowledged</span>
						{:else}
							<span class="ack-pill ack-pending" title="You have not acknowledged this version">Not acknowledged</span>
						{/if}
					</span>
				{/if}
			</div>
		</div>

		<div class="search-box">
			<span class="material-icons search-icon">search</span>
			<input
				type="text"
				placeholder="Search procedures…"
				bind:value={searchQuery}
				onkeydown={(e) => { if (e.key === "Escape") searchQuery = ""; }}
			/>
			{#if searchQuery}
				<button class="search-clear" aria-label="Clear search" onclick={() => (searchQuery = "")}>
					<span class="material-icons">close</span>
				</button>
			{/if}
		</div>

		{#if query}
			<div class="search-summary">
				{matchCount} section{matchCount === 1 ? "" : "s"} matched
			</div>
		{/if}

		<div class="category-list">
			{#if loading}
				<div class="loading-state">
					<div class="spinner"></div>
					<span>Loading…</span>
				</div>
			{:else}
				{#if hasOverview && !query}
					<button
						class="category-item"
						class:active={selectedCategoryId === null}
						onclick={() => (selectedCategoryId = null)}
					>
						<span class="material-icons cat-icon">flag</span>
						<div class="cat-info">
							<span class="cat-title">Overview</span>
							<span class="cat-count">Mission &amp; introduction</span>
						</div>
					</button>
				{/if}

				{#if filteredCategories.length === 0}
					<div class="empty-state">
						<span class="material-icons">search_off</span>
						<span>{query ? "Nothing matched that search" : "No SOPs published yet"}</span>
					</div>
				{:else}
					{#each filteredCategories as category (category.id)}
						<button
							class="category-item"
							class:active={selectedCategoryId === category.id}
							onclick={() => (selectedCategoryId = category.id)}
						>
							<span class="material-icons cat-icon">{category.icon || "description"}</span>
							<div class="cat-info">
								<span class="cat-title">{category.title}</span>
								<span class="cat-count">
									{category.sections.length} section{category.sections.length === 1 ? "" : "s"}
									{#if query}matching{/if}
								</span>
							</div>
						</button>

						<!-- While searching, show which sections actually hit so you can jump
						     straight there instead of hunting through the category. -->
						{#if query && category.sections.length > 0}
							<div class="match-list">
								{#each category.sections as section (section.id)}
									<button class="match-item" onclick={() => openSection(category.id, section.id)}>
										<span class="material-icons match-icon">subdirectory_arrow_right</span>
										<span class="match-title">{@html highlightText(section.title)}</span>
									</button>
								{/each}
							</div>
						{/if}
					{/each}
				{/if}
			{/if}
		</div>
	</aside>

	<div class="sop-content" bind:this={contentEl} onscroll={onContentScroll}>
		{#if loading}
			<div class="content-empty">
				<div class="spinner"></div>
				<span>Loading SOPs…</span>
			</div>
		{:else if selectedCategoryId === null && hasOverview}
			<!-- Overview: the mission statement and introduction used to be a banner
			     stapled on top of every category. They're their own page now. -->
			<div class="content-header">
				<span class="material-icons">flag</span>
				<h2>Overview</h2>
			</div>

			{#if sopSettings.mission_statement?.trim()}
				<div class="doc-card">
					<div class="doc-header">
						<span class="material-icons doc-icon">flag</span>
						<h3>Mission Statement</h3>
					</div>
					<div class="doc-body prose">{@html sopSettings.mission_statement}</div>
				</div>
			{/if}

			{#if sopSettings.introduction?.trim()}
				<div class="doc-card">
					<div class="doc-header">
						<span class="material-icons doc-icon">info</span>
						<h3>Introduction</h3>
					</div>
					<div class="doc-body prose">{@html sopSettings.introduction}</div>
				</div>
			{/if}
		{:else if !selectedCategory}
			<div class="content-empty">
				<span class="material-icons empty-icon">menu_book</span>
				<h3>Select a category</h3>
				<p>Choose an SOP category from the sidebar to read it.</p>
			</div>
		{:else if visibleSections.length === 0}
			<div class="content-empty">
				<span class="material-icons empty-icon">article</span>
				<h3>{selectedCategory.title}</h3>
				<p>{query ? "No sections in this category match your search." : "No sections have been added to this category yet."}</p>
			</div>
		{:else}
			<div class="content-header">
				<span class="material-icons">{selectedCategory.icon || "description"}</span>
				<h2>{selectedCategory.title}</h2>
				<span class="header-count">{visibleSections.length} section{visibleSections.length === 1 ? "" : "s"}</span>
			</div>

			<!-- Jump list. An SOP category can run long; scrolling blind through it to
			     find one rule is the main thing that made this tab tiring to use. -->
			{#if visibleSections.length > 1}
				<div class="toc">
					{#each visibleSections as section, i (section.id)}
						<button
							class="toc-chip"
							class:active={activeSectionId === section.id}
							onclick={() => scrollToSection(section.id)}
						>
							<span class="toc-num">{i + 1}</span>
							<span class="toc-text">{section.title}</span>
						</button>
					{/each}
				</div>
			{/if}

			<div class="sections-list">
				{#each visibleSections as section, i (section.id)}
					<div class="section-card" id="sop-section-{section.id}">
						<div class="section-header">
							<span class="section-number">{i + 1}</span>
							<h3 class="section-title">{@html highlightText(section.title)}</h3>
						</div>
						<div class="section-content prose">{@html highlight(section.content)}</div>
					</div>
				{/each}
			</div>

			<button class="back-to-top" onclick={backToTop}>
				<span class="material-icons">arrow_upward</span>
				Back to top
			</button>
		{/if}
	</div>
</div>

<style>
	/* Surfaces use --card-dark-bg and 6px radii, like every other tab. This page was
	   the odd one out: it painted its own translucent white overlays and 10px radii,
	   which is why it never quite matched and ignored the theme. */
	.sop-page {
		display: flex;
		height: 100%;
		overflow: hidden;
		gap: 10px;
		padding: 10px;
		box-sizing: border-box;
	}

	/* ── Sidebar ── */
	.sop-sidebar {
		display: flex;
		flex-direction: column;
		flex-shrink: 0;
		width: 270px;
		background: var(--card-dark-bg);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 6px;
		overflow: hidden;
	}

	.sidebar-header {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 12px 14px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}
	.header-icon { font-size: 18px; color: var(--accent-70); }
	.header-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
	.sidebar-header h2 {
		margin: 0;
		font-size: 12px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.85);
		line-height: 1.25;
	}
	.version-line {
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.3);
	}
	.ack-pill {
		border-radius: 3px;
		padding: 1px 5px;
		font-size: 8px;
		letter-spacing: 0.3px;
	}
	.ack-ok { background: rgba(16, 185, 129, 0.1); color: rgba(52, 211, 153, 0.85); }
	.ack-pending { background: rgba(251, 191, 36, 0.1); color: rgba(252, 211, 77, 0.85); }

	.search-box {
		position: relative;
		display: flex;
		align-items: center;
		margin: 10px 10px 6px;
	}
	.search-icon {
		position: absolute;
		left: 7px;
		font-size: 14px;
		color: rgba(255, 255, 255, 0.25);
		pointer-events: none;
	}
	.search-box input {
		width: 100%;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 5px 26px 5px 26px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 11px;
		font-family: inherit;
		box-sizing: border-box;
		transition: border-color 0.1s;
	}
	.search-box input:focus { outline: none; border-color: rgba(255, 255, 255, 0.12); }
	.search-box input::placeholder { color: rgba(255, 255, 255, 0.2); }
	.search-clear {
		position: absolute;
		right: 5px;
		display: flex;
		background: none;
		border: none;
		padding: 2px;
		color: rgba(255, 255, 255, 0.3);
		cursor: pointer;
	}
	.search-clear:hover { color: rgba(255, 255, 255, 0.8); }
	.search-clear .material-icons { font-size: 13px; }

	.search-summary {
		padding: 0 12px 6px;
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.5px;
		color: var(--accent-70);
	}

	.category-list {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding: 4px 8px 10px;
		overflow-y: auto;
	}
	.category-list::-webkit-scrollbar { width: 5px; }
	.category-list::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.08); border-radius: 3px; }

	.category-item {
		display: flex;
		align-items: center;
		gap: 9px;
		width: 100%;
		padding: 8px 9px;
		background: transparent;
		border: 1px solid transparent;
		border-radius: 4px;
		cursor: pointer;
		text-align: left;
		transition: all 0.1s;
	}
	.category-item:hover { background: rgba(255, 255, 255, 0.03); }
	.category-item.active {
		background: var(--accent-10);
		border-color: var(--accent-30);
	}
	.cat-icon { font-size: 16px; color: rgba(255, 255, 255, 0.35); }
	.category-item.active .cat-icon { color: var(--accent-70); }
	.cat-info { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
	.cat-title {
		font-size: 11px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.8);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.cat-count {
		font-size: 9px;
		color: rgba(255, 255, 255, 0.3);
	}

	/* Search hits, listed under their category so you can jump straight to one. */
	.match-list {
		display: flex;
		flex-direction: column;
		gap: 1px;
		margin: 1px 0 4px 18px;
		padding-left: 8px;
		border-left: 1px solid rgba(255, 255, 255, 0.06);
	}
	.match-item {
		display: flex;
		align-items: center;
		gap: 5px;
		background: none;
		border: none;
		border-radius: 3px;
		padding: 4px 6px;
		cursor: pointer;
		text-align: left;
		color: rgba(255, 255, 255, 0.5);
		transition: all 0.1s;
	}
	.match-item:hover { background: rgba(255, 255, 255, 0.04); color: rgba(255, 255, 255, 0.9); }
	.match-icon { font-size: 12px; color: rgba(255, 255, 255, 0.2); flex-shrink: 0; }
	.match-title {
		font-size: 10px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	/* ── Content ── */
	.sop-content {
		position: relative;
		flex: 1;
		min-width: 0;
		background: var(--card-dark-bg);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 6px;
		padding: 14px 18px 18px;
		overflow-y: auto;
	}
	.sop-content::-webkit-scrollbar { width: 6px; }
	.sop-content::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.08); border-radius: 3px; }

	.content-header {
		display: flex;
		align-items: center;
		gap: 9px;
		padding-bottom: 10px;
		margin-bottom: 12px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}
	.content-header .material-icons { font-size: 19px; color: var(--accent-70); }
	.content-header h2 {
		margin: 0;
		font-size: 14px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.9);
	}
	.header-count {
		margin-left: auto;
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.25);
	}

	/* Jump list */
	.toc {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
		margin-bottom: 14px;
	}
	.toc-chip {
		display: flex;
		align-items: center;
		gap: 5px;
		max-width: 240px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 3px 8px 3px 4px;
		cursor: pointer;
		transition: all 0.1s;
	}
	.toc-chip:hover { border-color: rgba(255, 255, 255, 0.15); }
	.toc-chip.active {
		background: var(--accent-10);
		border-color: var(--accent-30);
	}
	.toc-num {
		display: grid;
		place-items: center;
		width: 15px;
		height: 15px;
		border-radius: 2px;
		background: rgba(255, 255, 255, 0.06);
		font-size: 9px;
		font-weight: 700;
		color: rgba(255, 255, 255, 0.5);
		font-variant-numeric: tabular-nums;
	}
	.toc-chip.active .toc-num { background: var(--accent-30); color: #fff; }
	.toc-text {
		font-size: 10px;
		font-weight: 500;
		color: rgba(255, 255, 255, 0.6);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.toc-chip.active .toc-text { color: rgba(255, 255, 255, 0.95); }

	.sections-list { display: flex; flex-direction: column; gap: 10px; }

	.section-card {
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 6px;
		overflow: hidden;
		scroll-margin-top: 12px;
	}
	.section-header {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 9px 14px;
		background: rgba(255, 255, 255, 0.02);
		border-bottom: 1px solid rgba(255, 255, 255, 0.05);
	}
	.section-number {
		display: grid;
		place-items: center;
		width: 18px;
		height: 18px;
		flex-shrink: 0;
		border-radius: 3px;
		background: var(--accent-10);
		color: var(--accent-70);
		font-size: 10px;
		font-weight: 700;
		font-variant-numeric: tabular-nums;
	}
	.section-title {
		margin: 0;
		font-size: 12px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.85);
	}
	.section-content { padding: 12px 14px; }

	/* Documents on the overview page */
	.doc-card {
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 6px;
		overflow: hidden;
		margin-bottom: 10px;
	}
	.doc-header {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 9px 14px;
		background: rgba(255, 255, 255, 0.02);
		border-bottom: 1px solid rgba(255, 255, 255, 0.05);
	}
	.doc-icon { font-size: 15px; color: var(--accent-70); }
	.doc-header h3 {
		margin: 0;
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.75);
	}
	.doc-body { padding: 12px 14px; }

	.back-to-top {
		display: flex;
		align-items: center;
		gap: 5px;
		margin: 14px auto 0;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 4px 10px;
		color: rgba(255, 255, 255, 0.4);
		font-size: 10px;
		font-weight: 600;
		cursor: pointer;
		transition: all 0.1s;
	}
	.back-to-top:hover { color: rgba(255, 255, 255, 0.85); border-color: rgba(255, 255, 255, 0.15); }
	.back-to-top .material-icons { font-size: 13px; }

	/* ── States ── */
	.loading-state, .empty-state {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 7px;
		padding: 26px 10px;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.3);
		text-align: center;
	}
	.empty-state .material-icons { font-size: 20px; opacity: 0.5; }

	.content-empty {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 8px;
		height: 100%;
		color: rgba(255, 255, 255, 0.3);
		text-align: center;
	}
	.empty-icon { font-size: 34px; opacity: 0.35; }
	.content-empty h3 { margin: 0; font-size: 13px; color: rgba(255, 255, 255, 0.6); }
	.content-empty p { margin: 0; font-size: 11px; max-width: 300px; line-height: 1.5; }

	.spinner {
		width: 16px;
		height: 16px;
		border: 2px solid rgba(255, 255, 255, 0.08);
		border-top-color: var(--accent-70);
		border-radius: 50%;
		animation: spin 0.7s linear infinite;
	}
	@keyframes spin { to { transform: rotate(360deg); } }

	/*
	 * Rich text. `.prose` was used on every SOP body but never actually defined
	 * anywhere in the app, so procedures rendered with raw browser defaults —
	 * oversized black-on-dark headings, unstyled lists, the lot.
	 */
	.prose :global(> *:first-child) { margin-top: 0; }
	.prose :global(> *:last-child) { margin-bottom: 0; }
	.prose :global(p) {
		margin: 0 0 8px;
		font-size: 11.5px;
		line-height: 1.65;
		color: rgba(255, 255, 255, 0.7);
	}
	.prose :global(h1),
	.prose :global(h2),
	.prose :global(h3),
	.prose :global(h4) {
		margin: 14px 0 6px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.9);
		line-height: 1.3;
	}
	.prose :global(h1) { font-size: 14px; }
	.prose :global(h2) { font-size: 13px; }
	.prose :global(h3) { font-size: 12px; }
	.prose :global(h4) { font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; color: rgba(255, 255, 255, 0.5); }
	.prose :global(ul),
	.prose :global(ol) {
		margin: 0 0 8px;
		padding-left: 18px;
		font-size: 11.5px;
		line-height: 1.65;
		color: rgba(255, 255, 255, 0.7);
	}
	.prose :global(li) { margin-bottom: 3px; }
	.prose :global(li::marker) { color: var(--accent-60); }
	.prose :global(strong) { color: rgba(255, 255, 255, 0.95); font-weight: 600; }
	.prose :global(em) { color: rgba(255, 255, 255, 0.8); }
	.prose :global(a) { color: var(--accent-70); text-decoration: underline; }
	.prose :global(code) {
		background: rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 1px 4px;
		font-family: monospace;
		font-size: 10.5px;
		color: rgba(252, 211, 77, 0.9);
	}
	.prose :global(blockquote) {
		margin: 0 0 8px;
		padding: 4px 0 4px 10px;
		border-left: 2px solid var(--accent-30);
		color: rgba(255, 255, 255, 0.55);
		font-style: italic;
	}
	.prose :global(hr) {
		border: none;
		border-top: 1px solid rgba(255, 255, 255, 0.07);
		margin: 12px 0;
	}
	.prose :global(table) {
		width: 100%;
		border-collapse: collapse;
		margin: 0 0 8px;
		font-size: 11px;
	}
	.prose :global(th),
	.prose :global(td) {
		border: 1px solid rgba(255, 255, 255, 0.07);
		padding: 5px 8px;
		text-align: left;
		color: rgba(255, 255, 255, 0.7);
	}
	.prose :global(th) {
		background: rgba(255, 255, 255, 0.03);
		font-weight: 600;
		font-size: 10px;
		text-transform: uppercase;
		letter-spacing: 0.4px;
		color: rgba(255, 255, 255, 0.5);
	}
	.prose :global(img) { max-width: 100%; border-radius: 4px; }

	/* Search hits */
	.prose :global(mark),
	.section-title :global(mark),
	.match-title :global(mark) {
		background: rgba(251, 191, 36, 0.25);
		color: rgba(253, 224, 71, 0.95);
		border-radius: 2px;
		padding: 0 1px;
	}
</style>