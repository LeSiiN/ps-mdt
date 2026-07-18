<script lang="ts">
	/**
	 * Management → Applications: the in-game editor for what each department asks on its
	 * application form. Questions live in the database, not config, so a department can
	 * change its form without a restart. Mirrors the other management editors.
	 */
	import { fetchNui } from "../../utils/fetchNui";

	interface Question {
		id: number;
		label: string;
		type: "short" | "long" | "choice" | "boolean" | "number" | "link";
		options?: string[] | null;
		required: boolean;
	}

	// Departments are defined in config; the server hands us the list (same pattern as
	// every other config-backed list in the MDT).
	let departments = $state<{ id: string; label: string }[]>([]);
	let activeDept = $state("");
	let questions = $state<Question[]>([]);
	let loading = $state(false);
	let status = $state("");

	// The question currently being edited (or a fresh one being created).
	let editing = $state<Question | null>(null);
	let draftOptions = $state<string[]>([]);
	let newOption = $state("");

	const TYPE_LABELS: Record<Question["type"], string> = {
		short: "Short text",
		long: "Long text",
		choice: "Multiple choice",
		boolean: "Yes / No",
		number: "Number",
		link: "Link (URL)",
	};

	$effect(() => {
		if (activeDept) load();
	});

	// Load the department list once on mount, then default to the first.
	$effect(() => {
		loadDepartments();
	});

	async function loadDepartments() {
		try {
			const res = await fetchNui<{
				success: boolean;
				departments?: { id: string; label: string }[];
			}>("getApplicationDepartments", {});
			departments = res?.departments ?? [];
			if (!activeDept && departments.length > 0) {
				activeDept = departments[0].id;
			}
		} catch {
			departments = [];
		}
	}

	async function load() {
		loading = true;
		try {
			const res = await fetchNui<{ success: boolean; questions?: Question[] }>(
				"getApplicationQuestions",
				{ department: activeDept },
			);
			questions = res?.questions ?? [];
		} catch {
			questions = [];
		} finally {
			loading = false;
		}
	}

	function showStatus(msg: string) {
		status = msg;
		setTimeout(() => (status = ""), 2500);
	}

	function startNew() {
		editing = { id: 0, label: "", type: "short", required: false, options: [] };
		draftOptions = [];
		newOption = "";
	}

	function startEdit(q: Question) {
		editing = { ...q };
		draftOptions = q.options ? [...q.options] : [];
		newOption = "";
	}

	function cancelEdit() {
		editing = null;
		draftOptions = [];
		newOption = "";
	}

	function addOption() {
		const v = newOption.trim();
		if (v === "" || draftOptions.includes(v)) {
			newOption = "";
			return;
		}
		draftOptions = [...draftOptions, v];
		newOption = "";
	}

	function removeOption(opt: string) {
		draftOptions = draftOptions.filter((o) => o !== opt);
	}

	let canSave = $derived.by(() => {
		if (!editing) return false;
		if (editing.label.trim() === "") return false;
		if (editing.type === "choice" && draftOptions.length < 2) return false;
		return true;
	});

	async function save() {
		if (!editing || !canSave) return;
		const payload: any = {
			department: activeDept,
			label: editing.label.trim(),
			type: editing.type,
			required: editing.required,
			options: editing.type === "choice" ? draftOptions : undefined,
		};
		if (editing.id) payload.id = editing.id;

		try {
			const res = await fetchNui<{ success: boolean; message?: string }>(
				"saveApplicationQuestion",
				payload,
			);
			if (res?.success) {
				showStatus(editing.id ? "Question updated" : "Question added");
				cancelEdit();
				await load();
			} else {
				showStatus(res?.message || "Could not save");
			}
		} catch {
			showStatus("Could not save");
		}
	}

	async function remove(q: Question) {
		try {
			const res = await fetchNui<{ success: boolean }>("deleteApplicationQuestion", {
				id: q.id,
			});
			if (res?.success) {
				showStatus("Question removed");
				await load();
			}
		} catch {
			showStatus("Could not remove");
		}
	}

	// Move a question up or down and persist the whole order.
	async function move(index: number, dir: -1 | 1) {
		const target = index + dir;
		if (target < 0 || target >= questions.length) return;
		const next = [...questions];
		[next[index], next[target]] = [next[target], next[index]];
		questions = next;
		try {
			await fetchNui("reorderApplicationQuestions", {
				department: activeDept,
				order: next.map((q) => q.id),
			});
		} catch {
			// If persistence fails, reload the authoritative order.
			await load();
		}
	}
</script>

<div class="app-editor">
	<div class="head">
		<div class="dept-tabs">
			{#each departments as d}
				<button class="dept-tab" class:active={activeDept === d.id} onclick={() => (activeDept = d.id)}>
					{d.label}
				</button>
			{/each}
		</div>
		{#if status}<span class="status">{status}</span>{/if}
	</div>

	<p class="intro">
		Questions applicants answer for <strong>{departments.find((d) => d.id === activeDept)?.label ?? activeDept}</strong>.
		Changes take effect immediately — the next applicant sees the updated form.
	</p>

	<div class="editor-scroll">
	{#if loading}
		<div class="empty">Loading…</div>
	{:else if questions.length === 0}
		<div class="empty">No questions yet. Add the first one below.</div>
	{:else}
		<div class="q-list">
			{#each questions as q, i (q.id)}
				<div class="q-row">
					<div class="q-reorder">
						<button class="mini" disabled={i === 0} onclick={() => move(i, -1)} aria-label="Move up">
							<span class="material-icons">keyboard_arrow_up</span>
						</button>
						<button class="mini" disabled={i === questions.length - 1} onclick={() => move(i, 1)} aria-label="Move down">
							<span class="material-icons">keyboard_arrow_down</span>
						</button>
					</div>
					<div class="q-main">
						<div class="q-label">
							{q.label}
							{#if q.required}<span class="q-req">Required</span>{/if}
						</div>
						<div class="q-meta">
							{TYPE_LABELS[q.type]}
							{#if q.type === "choice" && q.options}· {q.options.length} options{/if}
						</div>
					</div>
					<div class="q-actions">
						<button class="mini" onclick={() => startEdit(q)} aria-label="Edit">
							<span class="material-icons">edit</span>
						</button>
						<button class="mini danger" onclick={() => remove(q)} aria-label="Delete">
							<span class="material-icons">delete</span>
						</button>
					</div>
				</div>
			{/each}
		</div>
	{/if}
	</div>

	<div class="editor-foot">
	{#if editing}
		<div class="editor-card">
			<div class="editor-title">{editing.id ? "Edit question" : "New question"}</div>

			<div class="fld">
				<span class="lbl">Question</span>
				<input class="inp" type="text" bind:value={editing.label} placeholder="e.g. Why do you want to join?" />
			</div>

			<div class="fld-row">
				<div class="fld">
					<span class="lbl">Type</span>
					<select class="inp" bind:value={editing.type}>
						{#each Object.entries(TYPE_LABELS) as [val, lbl]}
							<option value={val}>{lbl}</option>
						{/each}
					</select>
				</div>
				<label class="req-toggle">
					<input type="checkbox" bind:checked={editing.required} />
					<span>Required</span>
				</label>
			</div>

			{#if editing.type === "choice"}
				<div class="fld">
					<span class="lbl">Options <span class="hint">(at least two)</span></span>
					<div class="opt-add">
						<input
							class="inp"
							type="text"
							bind:value={newOption}
							placeholder="Add an option…"
							onkeydown={(e) => e.key === "Enter" && addOption()}
						/>
						<button class="btn ghost" onclick={addOption}>Add</button>
					</div>
					{#if draftOptions.length > 0}
						<div class="opt-list">
							{#each draftOptions as opt}
								<span class="opt-chip">
									{opt}
									<button onclick={() => removeOption(opt)} aria-label="Remove option">
										<span class="material-icons">close</span>
									</button>
								</span>
							{/each}
						</div>
					{/if}
				</div>
			{/if}

			<div class="editor-actions">
				<button class="btn ghost" onclick={cancelEdit}>Cancel</button>
				<button class="btn primary" disabled={!canSave} onclick={save}>
					{editing.id ? "Save changes" : "Add question"}
				</button>
			</div>
		</div>
	{:else}
		<button class="btn add" onclick={startNew}>
			<span class="material-icons">add</span> Add question
		</button>
	{/if}
	</div>
</div>

<style>
	/* Matches the other Management editors (Awards, Tags): 3px radius, 9-11px type,
	   fine 1px borders, accent-tinted primary buttons. */
	.app-editor {
		display: flex;
		flex-direction: column;
		gap: 12px;
		height: 100%;
		min-height: 0;
	}
	/* The question list scrolls on its own so a long list (past ~10 questions) stays
	   usable and the add/editor controls below never scroll out of reach. */
	.editor-scroll {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
	}
	.editor-scroll::-webkit-scrollbar { width: 5px; }
	.editor-scroll::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.08); border-radius: 3px; }
	.editor-foot {
		flex-shrink: 0;
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding-top: 4px;
		border-top: 1px solid rgba(255, 255, 255, 0.05);
	}
	.head {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	/* Department selector as a segmented pill, the MDT's standard for a small exclusive
	   choice. */
	.dept-tabs {
		display: inline-flex;
		gap: 3px;
		padding: 3px;
		background: rgba(0, 0, 0, 0.25);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-radius: 5px;
	}
	.dept-tab {
		padding: 5px 14px;
		border: none;
		border-radius: 3px;
		background: transparent;
		color: rgba(255, 255, 255, 0.5);
		font-size: 10px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.4px;
		cursor: pointer;
		transition: all 0.1s;
	}
	.dept-tab.active {
		background: rgba(var(--accent-rgb), 0.15);
		color: rgba(255, 255, 255, 0.9);
	}
	.status { font-size: 10px; color: rgba(52, 211, 153, 0.9); }

	.intro {
		margin: 0;
		font-size: 11px;
		line-height: 1.5;
		color: rgba(255, 255, 255, 0.4);
	}

	.empty {
		padding: 24px 0;
		text-align: center;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.3);
	}

	.q-list { display: flex; flex-direction: column; gap: 5px; }
	.q-row {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 9px 11px;
		border-radius: 3px;
		border: 1px solid rgba(255, 255, 255, 0.05);
		background: rgba(255, 255, 255, 0.02);
		transition: border-color 0.1s;
	}
	.q-row:hover { border-color: rgba(255, 255, 255, 0.1); }
	.q-reorder { display: flex; flex-direction: column; }
	.q-main { flex: 1; min-width: 0; }
	.q-label {
		display: flex;
		align-items: center;
		gap: 8px;
		font-size: 12px;
		color: rgba(255, 255, 255, 0.85);
	}
	.q-req {
		font-size: 8px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.4px;
		color: rgba(251, 146, 60, 0.9);
		background: rgba(251, 146, 60, 0.1);
		border: 1px solid rgba(251, 146, 60, 0.2);
		padding: 1px 5px;
		border-radius: 3px;
	}
	.q-meta { margin-top: 2px; font-size: 9px; color: rgba(255, 255, 255, 0.35); text-transform: uppercase; letter-spacing: 0.4px; }
	.q-actions { display: flex; gap: 2px; }

	.mini {
		display: grid;
		place-items: center;
		width: 24px;
		height: 24px;
		border: 1px solid transparent;
		border-radius: 3px;
		background: transparent;
		color: rgba(255, 255, 255, 0.35);
		cursor: pointer;
		transition: all 0.1s;
	}
	.mini:hover:not(:disabled) { color: rgba(255, 255, 255, 0.7); background: rgba(255, 255, 255, 0.04); }
	.mini:disabled { opacity: 0.25; cursor: default; }
	.mini.danger:hover:not(:disabled) { color: rgba(248, 113, 113, 0.9); background: rgba(239, 68, 68, 0.08); }
	.mini .material-icons { font-size: 14px; }

	.editor-card {
		display: flex;
		flex-direction: column;
		gap: 11px;
		padding: 13px;
		border-radius: 3px;
		border: 1px solid rgba(var(--accent-rgb), 0.15);
		background: rgba(var(--accent-rgb), 0.03);
	}
	.editor-title {
		font-size: 10px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.6);
	}
	.fld { display: flex; flex-direction: column; gap: 5px; }
	.fld-row { display: flex; gap: 12px; align-items: flex-end; }
	.fld-row .fld { flex: 1; }
	.lbl {
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.35);
	}
	.hint { color: rgba(255, 255, 255, 0.25); text-transform: none; letter-spacing: 0; }
	.inp {
		width: 100%;
		padding: 6px 9px;
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.85);
		font-size: 11px;
		font-family: inherit;
		box-sizing: border-box;
		transition: border-color 0.1s;
	}
	.inp:focus { outline: none; border-color: rgba(var(--accent-rgb), 0.4); }
	.inp option { background: #1a1d23; }

	.req-toggle {
		display: flex;
		align-items: center;
		gap: 6px;
		padding-bottom: 7px;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.65);
		cursor: pointer;
		white-space: nowrap;
	}
	.req-toggle input { width: 13px; height: 13px; accent-color: rgb(var(--accent-rgb)); }

	.opt-add { display: flex; gap: 5px; }
	.opt-list { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 7px; }
	.opt-chip {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 3px 5px 3px 9px;
		border-radius: 3px;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.07);
		font-size: 10px;
		color: rgba(255, 255, 255, 0.75);
	}
	.opt-chip button {
		display: grid;
		place-items: center;
		width: 15px;
		height: 15px;
		border: none;
		border-radius: 2px;
		background: transparent;
		color: rgba(255, 255, 255, 0.35);
		cursor: pointer;
	}
	.opt-chip button:hover { background: rgba(239, 68, 68, 0.15); color: rgba(248, 113, 113, 0.9); }
	.opt-chip .material-icons { font-size: 11px; }

	.editor-actions { display: flex; justify-content: flex-end; gap: 6px; }

	/* Buttons match the Awards/Tags editors exactly. */
	.btn {
		padding: 5px 16px;
		border-radius: 3px;
		font-size: 10px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.4px;
		cursor: pointer;
		border: 1px solid transparent;
		transition: all 0.1s;
	}
	.btn.ghost {
		background: transparent;
		border-color: rgba(255, 255, 255, 0.08);
		color: rgba(255, 255, 255, 0.5);
	}
	.btn.ghost:hover { color: rgba(255, 255, 255, 0.75); border-color: rgba(255, 255, 255, 0.12); }
	.btn.primary {
		background: rgba(var(--accent-rgb), 0.1);
		border-color: rgba(var(--accent-rgb), 0.25);
		color: rgba(255, 255, 255, 0.9);
	}
	.btn.primary:hover:not(:disabled) { background: rgba(var(--accent-rgb), 0.18); }
	.btn.primary:disabled { opacity: 0.3; cursor: not-allowed; }
	.btn.add {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		align-self: flex-start;
		background: rgba(var(--accent-rgb), 0.06);
		border-color: rgba(var(--accent-rgb), 0.15);
		color: rgba(255, 255, 255, 0.7);
	}
	.btn.add:hover { background: rgba(var(--accent-rgb), 0.12); color: rgba(255, 255, 255, 0.9); }
	.btn.add .material-icons { font-size: 14px; }
</style>