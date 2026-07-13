<script lang="ts">
	import { onMount } from "svelte";
	import { fetchNui } from "../../utils/fetchNui";
	import { NUI_EVENTS } from "../../constants/nuiEvents";
	import type { JobType } from "../../interfaces/IUser";

	interface FTOPhase {
		id: number;
		name: string;
		description?: string;
		duration_days?: number;
		sort_order: number;
	}

	interface FTOCompetency {
		id: number;
		name: string;
		category?: string;
		sort_order: number;
	}

	let { jobType }: { jobType?: JobType } = $props();

	// State
	let activeTab = $state<"phases" | "competencies">("phases");
	let phases = $state<FTOPhase[]>([]);
	let competencies = $state<FTOCompetency[]>([]);
	let loading = $state(true);
	let statusMsg = $state("");

	// Phase editing
	let newPhaseName = $state("");
	let newPhaseDescription = $state("");
	let newPhaseDuration = $state<number | undefined>(undefined);
	let editingPhaseId = $state<number | null>(null);
	let editPhaseName = $state("");
	let editPhaseDescription = $state("");
	let editPhaseDuration = $state<number | undefined>(undefined);

	// Competency editing
	let newCompName = $state("");
	let newCompCategory = $state("");
	let editingCompId = $state<number | null>(null);
	let editCompName = $state("");
	let editCompCategory = $state("");

	onMount(async () => {
		await Promise.all([loadPhases(), loadCompetencies()]);
	});

	// "Unsaved changes" tracking — add/edit/move/delete are all local until
	// "Save All" is pressed, so we compare against the last loaded state.
	let phasesSnap = $state("");
	let compsSnap = $state("");
	let phasesDirty = $derived(phasesSnap !== "" && JSON.stringify(phases) !== phasesSnap);
	let compsDirty = $derived(compsSnap !== "" && JSON.stringify(competencies) !== compsSnap);

	async function loadPhases() {
		loading = true;
		try {
			const result = await fetchNui<FTOPhase[]>(NUI_EVENTS.FTO.GET_FTO_PHASES, {}, []);
			phases = result || [];
		} catch { phases = []; }
		finally { loading = false; phasesSnap = JSON.stringify(phases); }
	}

	async function loadCompetencies() {
		loading = true;
		try {
			const result = await fetchNui<FTOCompetency[]>(NUI_EVENTS.FTO.GET_FTO_COMPETENCIES, {}, []);
			competencies = result || [];
		} catch { competencies = []; }
		finally { loading = false; compsSnap = JSON.stringify(competencies); }
	}

	// ---- Phase CRUD ----

	function addPhase() {
		if (!newPhaseName.trim()) return;
		phases = [...phases, {
			id: -(Date.now()),
			name: newPhaseName.trim(),
			description: newPhaseDescription.trim() || undefined,
			duration_days: newPhaseDuration || undefined,
			sort_order: phases.length + 1,
		}];
		newPhaseName = "";
		newPhaseDescription = "";
		newPhaseDuration = undefined;
	}

	function startEditPhase(phase: FTOPhase) {
		editingPhaseId = phase.id;
		editPhaseName = phase.name;
		editPhaseDescription = phase.description || "";
		editPhaseDuration = phase.duration_days;
	}

	function saveEditPhase() {
		if (!editingPhaseId || !editPhaseName.trim()) return;
		phases = phases.map(p => p.id === editingPhaseId ? {
			...p,
			name: editPhaseName.trim(),
			description: editPhaseDescription.trim() || undefined,
			duration_days: editPhaseDuration || undefined,
		} : p);
		editingPhaseId = null;
	}

	function deletePhase(id: number) {
		phases = phases.filter(p => p.id !== id);
	}

	function movePhase(index: number, direction: -1 | 1) {
		const newIndex = index + direction;
		if (newIndex < 0 || newIndex >= phases.length) return;
		const updated = [...phases];
		[updated[index], updated[newIndex]] = [updated[newIndex], updated[index]];
		phases = updated.map((p, i) => ({ ...p, sort_order: i + 1 }));
	}

	async function saveAllPhases() {
		try {
			const result = await fetchNui<{ success: boolean }>(
				NUI_EVENTS.FTO.SAVE_FTO_PHASES,
				{ phases: phases.map((p, i) => ({ ...p, sort_order: i + 1 })) },
				{ success: true }
			);
			if (result?.success) {
				showStatus("Phases saved");
				await loadPhases();
			}
		} catch {
			showStatus("Failed to save phases");
		}
	}

	// ---- Competency CRUD ----

	function addCompetency() {
		if (!newCompName.trim()) return;
		competencies = [...competencies, {
			id: -(Date.now()),
			name: newCompName.trim(),
			category: newCompCategory.trim() || undefined,
			sort_order: competencies.length + 1,
		}];
		newCompName = "";
		newCompCategory = "";
	}

	function startEditComp(comp: FTOCompetency) {
		editingCompId = comp.id;
		editCompName = comp.name;
		editCompCategory = comp.category || "";
	}

	function saveEditComp() {
		if (!editingCompId || !editCompName.trim()) return;
		competencies = competencies.map(c => c.id === editingCompId ? {
			...c,
			name: editCompName.trim(),
			category: editCompCategory.trim() || undefined,
		} : c);
		editingCompId = null;
	}

	function deleteComp(id: number) {
		competencies = competencies.filter(c => c.id !== id);
	}

	function moveComp(index: number, direction: -1 | 1) {
		const newIndex = index + direction;
		if (newIndex < 0 || newIndex >= competencies.length) return;
		const updated = [...competencies];
		[updated[index], updated[newIndex]] = [updated[newIndex], updated[index]];
		competencies = updated.map((c, i) => ({ ...c, sort_order: i + 1 }));
	}

	async function saveAllCompetencies() {
		try {
			const result = await fetchNui<{ success: boolean }>(
				NUI_EVENTS.FTO.SAVE_FTO_COMPETENCIES,
				{ competencies: competencies.map((c, i) => ({ ...c, sort_order: i + 1 })) },
				{ success: true }
			);
			if (result?.success) {
				showStatus("Competencies saved");
				await loadCompetencies();
			}
		} catch {
			showStatus("Failed to save competencies");
		}
	}

	function showStatus(msg: string) {
		statusMsg = msg;
		setTimeout(() => { if (statusMsg === msg) statusMsg = ""; }, 3000);
	}
</script>

<div class="mgmt-fto">
	{#if statusMsg}
		<div class="status-toast">{statusMsg}</div>
	{/if}

	<div class="sop-tabs">
		<button class="sop-tab" class:active={activeTab === "phases"} onclick={() => activeTab = "phases"}>
			<span class="material-icons">timeline</span> Phases
		</button>
		<button class="sop-tab" class:active={activeTab === "competencies"} onclick={() => activeTab = "competencies"}>
			<span class="material-icons">checklist</span> Competencies
		</button>
	</div>

	<div class="sop-tab-content">
		{#if activeTab === "phases"}
			<div class="list-section">
				<div class="panel-header">
					<h3>FTO Phases</h3>
					<div class="panel-header-actions">
						{#if phasesDirty}
							<span class="dirty-hint">Unsaved changes</span>
						{/if}
						<button class="btn-save" class:dirty={phasesDirty} onclick={saveAllPhases}>
							<span class="material-icons">save</span> Save All Phases
						</button>
					</div>
				</div>

				{#if phases.length === 0 && !loading}
					<div class="empty-state">
						<span class="material-icons">timeline</span>
						<p>No phases configured. Add your first FTO phase below.</p>
					</div>
				{/if}

				<div class="item-list">
					{#each phases as phase, i}
						{#if editingPhaseId === phase.id}
							<div class="item-edit-row">
								<input type="text" bind:value={editPhaseName} placeholder="Phase name" class="input-sm" />
								<input type="text" bind:value={editPhaseDescription} placeholder="Description" class="input-sm" />
								<input type="number" bind:value={editPhaseDuration} placeholder="Days" class="input-sm input-narrow" min="1" />
								<button class="btn-icon-sm" onclick={saveEditPhase} title="Save">
									<span class="material-icons">check</span>
								</button>
								<button class="btn-icon-sm cancel" onclick={() => editingPhaseId = null} title="Cancel">
									<span class="material-icons">close</span>
								</button>
							</div>
						{:else}
							<div class="item-row">
								<span class="item-order">{i + 1}</span>
								<div class="item-text">
									<span class="item-name">{phase.name}</span>
									{#if phase.description}
										<span class="item-desc">{phase.description}</span>
									{/if}
								</div>
								{#if phase.duration_days}
									<span class="item-badge">{phase.duration_days}d</span>
								{/if}
								<div class="item-actions">
									<button class="btn-icon-xs" onclick={() => movePhase(i, -1)} title="Move up" disabled={i === 0}>
										<span class="material-icons">arrow_upward</span>
									</button>
									<button class="btn-icon-xs" onclick={() => movePhase(i, 1)} title="Move down" disabled={i === phases.length - 1}>
										<span class="material-icons">arrow_downward</span>
									</button>
									<button class="btn-icon-xs" onclick={() => startEditPhase(phase)} title="Edit">
										<span class="material-icons">edit</span>
									</button>
									<button class="btn-icon-xs danger" onclick={() => deletePhase(phase.id)} title="Delete">
										<span class="material-icons">delete</span>
									</button>
								</div>
							</div>
						{/if}
					{/each}
				</div>

				<div class="add-row">
					<input type="text" bind:value={newPhaseName} placeholder="Phase name..." class="input-sm" onkeydown={(e) => e.key === 'Enter' && addPhase()} />
					<input type="text" bind:value={newPhaseDescription} placeholder="Description..." class="input-sm" />
					<input type="number" bind:value={newPhaseDuration} placeholder="Days" class="input-sm input-narrow" min="1" />
					<button class="btn-add" onclick={addPhase} disabled={!newPhaseName.trim()}>
						<span class="material-icons">add</span>
					</button>
				</div>
			</div>

		{:else if activeTab === "competencies"}
			<div class="list-section">
				<div class="panel-header">
					<h3>FTO Competencies</h3>
					<div class="panel-header-actions">
						{#if compsDirty}
							<span class="dirty-hint">Unsaved changes</span>
						{/if}
						<button class="btn-save" class:dirty={compsDirty} onclick={saveAllCompetencies}>
							<span class="material-icons">save</span> Save All Competencies
						</button>
					</div>
				</div>

				{#if competencies.length === 0 && !loading}
					<div class="empty-state">
						<span class="material-icons">checklist</span>
						<p>No competencies configured. Add your first competency below.</p>
					</div>
				{/if}

				<div class="item-list">
					{#each competencies as comp, i}
						{#if editingCompId === comp.id}
							<div class="item-edit-row">
								<input type="text" bind:value={editCompName} placeholder="Competency name" class="input-sm" />
								<input type="text" bind:value={editCompCategory} placeholder="Category" class="input-sm" />
								<button class="btn-icon-sm" onclick={saveEditComp} title="Save">
									<span class="material-icons">check</span>
								</button>
								<button class="btn-icon-sm cancel" onclick={() => editingCompId = null} title="Cancel">
									<span class="material-icons">close</span>
								</button>
							</div>
						{:else}
							<div class="item-row">
								<span class="item-order">{i + 1}</span>
								<span class="item-name">{comp.name}</span>
								{#if comp.category}
									<span class="item-badge">{comp.category}</span>
								{/if}
								<div class="item-actions">
									<button class="btn-icon-xs" onclick={() => moveComp(i, -1)} title="Move up" disabled={i === 0}>
										<span class="material-icons">arrow_upward</span>
									</button>
									<button class="btn-icon-xs" onclick={() => moveComp(i, 1)} title="Move down" disabled={i === competencies.length - 1}>
										<span class="material-icons">arrow_downward</span>
									</button>
									<button class="btn-icon-xs" onclick={() => startEditComp(comp)} title="Edit">
										<span class="material-icons">edit</span>
									</button>
									<button class="btn-icon-xs danger" onclick={() => deleteComp(comp.id)} title="Delete">
										<span class="material-icons">delete</span>
									</button>
								</div>
							</div>
						{/if}
					{/each}
				</div>

				<div class="add-row">
					<input type="text" bind:value={newCompName} placeholder="Competency name..." class="input-sm" onkeydown={(e) => e.key === 'Enter' && addCompetency()} />
					<input type="text" bind:value={newCompCategory} placeholder="Category..." class="input-sm" />
					<button class="btn-add" onclick={addCompetency} disabled={!newCompName.trim()}>
						<span class="material-icons">add</span>
					</button>
				</div>
			</div>
		{/if}
	</div>
</div>

<style>
	.mgmt-fto {
		height: 100%;
		display: flex;
		flex-direction: column;
		position: relative;
	}

	.status-toast {
		position: absolute;
		top: 8px;
		right: 16px;
		background: rgba(34, 197, 94, 0.12);
		color: rgba(110, 231, 183, 0.9);
		border: 1px solid rgba(34, 197, 94, 0.25);
		padding: 4px 12px;
		border-radius: 3px;
		font-size: 10px;
		font-weight: 500;
		z-index: 10;
		animation: fadeInOut 3s ease forwards;
	}

	@keyframes fadeInOut {
		0% { opacity: 0; transform: translateY(-8px); }
		10% { opacity: 1; transform: translateY(0); }
		80% { opacity: 1; }
		100% { opacity: 0; }
	}

	/* Tabs */
	.sop-tabs {
		display: flex;
		gap: 4px;
		padding: 12px 16px 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		flex-shrink: 0;
	}

	.sop-tab {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 8px 16px;
		background: transparent;
		border: none;
		border-bottom: 2px solid transparent;
		color: rgba(255, 255, 255, 0.5);
		font-size: 12px;
		cursor: pointer;
		transition: all 0.15s;
	}

	.sop-tab .material-icons { font-size: 16px; }

	.sop-tab:hover { color: rgba(255, 255, 255, 0.7); }

	.sop-tab.active {
		color: var(--accent-text);
		border-bottom-color: var(--accent-60);
	}

	.sop-tab-content {
		flex: 1;
		overflow-y: auto;
		padding: 16px;
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
	}

	/* List Section */
	.list-section {
		display: flex;
		flex-direction: column;
		gap: 0;
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 8px;
		overflow: hidden;
	}

	.panel-header {
		padding: 12px 16px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		display: flex;
		align-items: center;
		justify-content: space-between;
		flex-shrink: 0;
	}

	.panel-header h3 {
		font-size: 12px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.8);
		margin: 0;
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.empty-state {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 32px;
		color: rgba(255, 255, 255, 0.3);
		font-size: 12px;
	}

	.empty-state .material-icons {
		font-size: 28px;
	}

	.empty-state p {
		margin: 0;
	}

	/* Item List */
	.item-list {
		flex: 1;
		overflow-y: auto;
		padding: 8px;
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
	}

	.item-row {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 8px 12px;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 5px;
		margin-bottom: 4px;
		transition: border-color 0.1s, background 0.1s;
	}
	.item-row:hover {
		background: rgba(255, 255, 255, 0.035);
		border-color: rgba(255, 255, 255, 0.1);
	}

	.item-row:hover {
		background: rgba(255, 255, 255, 0.02);
	}

	.item-order {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 20px;
		height: 20px;
		flex-shrink: 0;
		border-radius: 50%;
		font-size: 10px;
		font-weight: 700;
		color: rgba(var(--accent-text-rgb), 0.85);
		background: rgba(var(--accent-rgb), 0.1);
	}

	.item-text {
		flex: 1;
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.item-name {
		font-size: 12px;
		color: rgba(255, 255, 255, 0.8);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.item-desc {
		font-size: 10px;
		color: rgba(255, 255, 255, 0.4);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.item-badge {
		font-size: 10px;
		font-weight: 600;
		color: rgba(var(--accent-text-rgb), 0.75);
		background: rgba(var(--accent-rgb), 0.08);
		padding: 1px 7px;
		border-radius: 3px;
	}

	.item-actions {
		display: flex;
		gap: 2px;
		opacity: 0;
		transition: opacity 0.12s;
	}

	.item-row:hover .item-actions {
		opacity: 1;
	}

	.item-edit-row {
		display: flex;
		align-items: center;
		gap: 4px;
		padding: 6px 12px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.04);
	}

	/* Inputs */
	.input-sm {
		flex: 1;
		padding: 6px 9px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.85);
		font-size: 11px;
		outline: none;
		transition: border-color 0.1s;
	}
	.input-sm:focus { border-color: rgba(255, 255, 255, 0.14); }


	.input-narrow {
		max-width: 70px;
		flex: 0 0 70px;
	}

	/* Buttons */
	.btn-icon-sm, .btn-icon-xs {
		display: flex;
		align-items: center;
		justify-content: center;
		background: transparent;
		border: none;
		cursor: pointer;
		border-radius: 4px;
		transition: all 0.12s;
	}

	.btn-icon-sm {
		padding: 4px;
		color: rgba(34, 197, 94, 0.7);
	}

	.btn-icon-sm .material-icons { font-size: 16px; }

	.btn-icon-sm.cancel { color: rgba(239, 68, 68, 0.7); }

	.btn-icon-sm:hover { background: rgba(255, 255, 255, 0.06); }

	.btn-icon-xs {
		padding: 2px;
		color: rgba(255, 255, 255, 0.3);
	}

	.btn-icon-xs .material-icons { font-size: 14px; }

	.btn-icon-xs.danger:hover { color: rgba(239, 68, 68, 0.8); }

	.btn-icon-xs:hover { color: rgba(255, 255, 255, 0.7); }

	.btn-icon-xs:disabled {
		opacity: 0.2;
		cursor: not-allowed;
	}

	.add-row {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 10px 12px;
		border-top: 1px solid rgba(255, 255, 255, 0.06);
		background: rgba(255, 255, 255, 0.015);
		flex-shrink: 0;
	}

	.btn-add {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 28px;
		height: 28px;
		flex-shrink: 0;
		background: rgba(var(--accent-rgb), 0.08);
		border: 1px solid rgba(var(--accent-rgb), 0.18);
		border-radius: 3px;
		color: rgba(var(--accent-text-rgb), 0.85);
		cursor: pointer;
		transition: all 0.1s;
	}
	.btn-add:hover:not(:disabled) {
		background: rgba(var(--accent-rgb), 0.16);
		border-color: rgba(var(--accent-rgb), 0.3);
		color: rgba(var(--accent-text-rgb), 1);
	}
	.btn-add:disabled { opacity: 0.35; cursor: not-allowed; }

	.btn-add .material-icons { font-size: 16px; }


	.btn-save {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 4px 10px;
		border-radius: 3px;
		font-size: 10px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid rgba(var(--accent-rgb), 0.1);
		background: rgba(var(--accent-rgb), 0.06);
		color: rgba(var(--accent-text-rgb), 0.7);
		transition: all 0.1s;
	}
	.btn-save:hover { background: rgba(var(--accent-rgb), 0.12); color: rgba(var(--accent-text-rgb), 0.9); }
	.btn-save.dirty {
		background: rgba(var(--accent-rgb), 0.14);
		border-color: rgba(var(--accent-rgb), 0.25);
		color: rgba(var(--accent-text-rgb), 0.95);
	}
	.panel-header-actions {
		display: flex;
		align-items: center;
		gap: 10px;
	}
	.dirty-hint {
		font-size: 10px;
		color: rgba(234, 179, 8, 0.75);
	}


	.btn-save .material-icons { font-size: 13px; }
</style>