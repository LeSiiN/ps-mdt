<script lang="ts">
	import { onMount } from "svelte";
	import { formatDate, formatTime, formatDateTime } from "../utils/datetime";
	import { isEnvBrowser } from "../utils/misc";
	import { createCaseService } from "../services/caseService.svelte";
	import { createSearchService } from "../services/searchService.svelte";
	import { fileToBase64, formatBytes } from "../services/uploadService";
	import PersonSearchModal from "../components/report-editor/PersonSearchModal.svelte";
	import SkeletonList from "../components/SkeletonList.svelte";
	import Pagination from "../components/Pagination.svelte";
	import type { createTabService } from "../services/tabService.svelte";
	import type { MDTTab } from "../constants";
	import type {
		CaseAttachment,
		CaseDetailResponse,
		CaseNote,
		CaseOfficerAssignment,
		CaseRecord,
		CaseStatus,
		CasePriority,
	} from "../interfaces/ICase";
	import { globalNotifications } from "../services/notificationService.svelte";

	let { tabService }: { tabService?: ReturnType<typeof createTabService> } = $props();

	function navigateTo(tab: MDTTab) {
		if (!tabService) return;
		tabService.setActiveTab(tab);
		const activeInstance = tabService.getActiveInstance();
		if (activeInstance) {
			tabService.setInstanceTab(activeInstance.id, tab);
		}
	}

	const caseService = createCaseService();
	const searchService = createSearchService();

	let cases = $state<CaseRecord[]>([]);
	let selectedCase = $state<CaseDetailResponse | null>(null);
	let isLoading = $state(false);
	let searchQuery = $state("");
	let reportLinkId = $state("");
	let officerSearchQuery = $state("");
	let showCreatePanel = $state(false);
	let showCaseView = $state(false);
	let showOfficerSearch = $state(false);
	let officerRole = $state<CaseOfficerAssignment["role"]>("assisting");

	// Summary editing — the case summary was read-only, though the server has always
	// accepted updates to it. Editing is inline: click Edit, change the text, Save.
	// Detail tabs — the sections were one long stacked scroll; grouping them behind tabs
	// keeps only the relevant one on screen.
	let detailTab = $state("overview");
	// Reset to the first tab whenever a different case is opened.
	$effect(() => {
		selectedCase?.case.id;
		detailTab = "overview";
	});

	let editingSummary = $state(false);
	let summaryDraft = $state("");
	function startEditSummary() {
		summaryDraft = selectedCase?.case.summary ?? "";
		editingSummary = true;
	}
	async function saveSummary() {
		if (!selectedCase) return;
		const next = summaryDraft.trim();
		editingSummary = false;
		if (next === (selectedCase.case.summary ?? "")) return;
		await handleUpdateCase({ summary: next });
	}
	let isCreateDisabled = $derived.by(() => !newCase.title.trim());
	let newCase = $state({
		title: "",
		summary: "",
		status: "open" as CaseStatus,
		priority: "medium" as CasePriority,
		department: "",
	});
	let filters = $state({
		status: "" as CaseStatus | "",
		priority: "" as CasePriority | "",
		department: "",
	});
	let attachmentDraft = $state({
		type: "document" as CaseAttachment["type"],
		url: "",
		label: "",
	});
	let attachmentFile = $state<File | null>(null);
	let attachmentError = $state("");
	let noteContent = $state("");
	let noteSubmitting = $state(false);
	const maxUploadBytes = 5 * 1024 * 1024;
	const allowedAttachmentTypes = [
		"image/jpeg",
		"image/png",
		"image/webp",
		"application/pdf",
	];
	const allowedEvidenceImageTypes = ["image/jpeg", "image/png", "image/webp"];

	const statusOptions: CaseStatus[] = ["open", "in_progress", "closed"];
	const priorityOptions: CasePriority[] = ["low", "medium", "high"];

	let checklist = $state({
		primaryOfficer: false,
		attachments: false,
		reports: false,
		statusPriority: true,
	});

	onMount(async () => {
		if (isEnvBrowser()) {
			cases = [
				{ id: 1, case_number: 'CASE-001', title: 'Fleeca Bank Armed Robbery', summary: 'Multiple suspects robbed Fleeca Bank on Hawick Ave', status: 'open', priority: 'high', assigned_department: 'Detectives', created_by: 'DET001', created_by_name: 'Det. Williams', created_at: '2026-03-15T10:30:00Z', updated_at: '2026-03-18T14:00:00Z', primary_officer_name: 'Det. Williams', primary_officer_callsign: '201' },
				{ id: 2, case_number: 'CASE-002', title: 'Vinewood Drive-by Shooting', summary: 'Drive-by shooting on Vinewood Blvd with multiple victims', status: 'in_progress', priority: 'high', assigned_department: 'Homicide', created_by: 'DET002', created_by_name: 'Det. Chen', created_at: '2026-03-14T08:15:00Z', updated_at: '2026-03-17T16:45:00Z', primary_officer_name: 'Det. Chen', primary_officer_callsign: '205' },
				{ id: 3, case_number: 'CASE-003', title: 'Vehicle Theft Ring Investigation', summary: 'Series of high-end vehicle thefts across LS', status: 'open', priority: 'medium', assigned_department: 'Auto Theft', created_by: 'SGT001', created_by_name: 'Sgt. Garcia', created_at: '2026-03-10T12:00:00Z', updated_at: '2026-03-16T09:30:00Z', primary_officer_name: 'Sgt. Garcia', primary_officer_callsign: '301' },
				{ id: 4, case_number: 'CASE-004', title: 'Noise Complaint - Recurring', summary: 'Repeated noise complaints from Vespucci Beach area', status: 'closed', priority: 'low', assigned_department: 'Patrol', created_by: 'OFC001', created_by_name: 'Ofc. Brown', created_at: '2026-03-05T18:00:00Z', updated_at: '2026-03-12T11:00:00Z', primary_officer_name: 'Ofc. Brown', primary_officer_callsign: '455' },
				{ id: 5, case_number: 'CASE-005', title: 'Drug Trafficking - Route 68', summary: 'Suspected drug operation along Route 68 corridor', status: 'in_progress', priority: 'medium', assigned_department: 'Narcotics', created_by: 'DET003', created_by_name: 'Det. Ramirez', created_at: '2026-03-08T09:00:00Z', updated_at: '2026-03-18T08:00:00Z', primary_officer_name: 'Det. Ramirez', primary_officer_callsign: '210' },
			];
			isLoading = false;
			return;
		}
		await loadCases();
	});

	async function loadCases() {
		isLoading = true;
		const activeFilters: Record<string, unknown> = {};
		if (filters.status) {
			activeFilters.status = filters.status;
		}
		if (filters.priority) {
			activeFilters.priority = filters.priority;
		}
		if (filters.department.trim()) {
			activeFilters.department = filters.department.trim();
		}
		await caseService.loadCases(1, activeFilters);
		cases = caseService.state.cases;
		isLoading = false;
	}

	$effect(() => {
		const target = tabService?.pendingTarget;
		if (target?.tab === "Cases" && target.id) {
			const id = tabService?.consumeTarget("Cases");
			if (id) selectCase(Number(id));
		}
	});

	async function selectCase(caseId: number) {
		isLoading = true;
		const data = await caseService.getCase(caseId);
		selectedCase = data;
		showCaseView = true;
		const auditResponse = data
			? await caseService.getCaseAuditLogs(caseId, 1, auditPageSize)
			: { items: [], total: 0 };
		auditLogs = auditResponse.items || [];
		auditTotal = auditResponse.total || 0;
		pagedAuditLogs = auditLogs;
		auditPage = 1;
		evidencePage = 1;
		if (data) {
			updateChecklist(data);
			const evidenceResponse = await caseService.getCaseEvidencePage(
				caseId,
				1,
				pageSize,
			);
			if (evidenceResponse.success && evidenceResponse.data) {
				pagedEvidence = evidenceResponse.data.items || [];
				evidenceTotal = evidenceResponse.data.total || 0;
			} else {
				pagedEvidence = [];
				evidenceTotal = 0;
			}
		}
		isLoading = false;
	}

	async function handleLinkReport() {
		if (!selectedCase || !reportLinkId.trim()) return;
		const result = await caseService.linkReportToCase(
			Number(reportLinkId.trim()),
			selectedCase.case.id,
		);
		if (!result.success) {
			globalNotifications.error(result.error || "Failed to link report");
			return;
		}
		reportLinkId = "";
		await selectCase(selectedCase.case.id);
		updateChecklist(selectedCase);
	}

	async function handleAddNote() {
		if (!selectedCase || !noteContent.trim() || noteSubmitting) return;
		noteSubmitting = true;
		const success = await caseService.addCaseNote(selectedCase.case.id, noteContent.trim());
		if (success) {
			noteContent = "";
			await selectCase(selectedCase.case.id);
		} else {
			globalNotifications.error("Failed to add note");
		}
		noteSubmitting = false;
	}

	async function handleDeleteNote(noteId: number) {
		if (!selectedCase) return;
		const success = await caseService.deleteCaseNote(selectedCase.case.id, noteId);
		if (success) {
			await selectCase(selectedCase.case.id);
		} else {
			globalNotifications.error("Failed to delete note");
		}
	}

	async function handleUnlinkReport(reportId: number) {
		if (!selectedCase) return;
		await caseService.unlinkReportFromCase(reportId, selectedCase.case.id);
		await selectCase(selectedCase.case.id);
		updateChecklist(selectedCase);
	}

	function updateChecklist(data: CaseDetailResponse | null) {
		if (!data) return;
		const hasPrimaryOfficer = data.officers.some(
			(officer) => officer.role === "primary",
		);
		const hasAttachments = data.attachments.length > 0;
		const reports = (data as any).reports || [];
		const hasReports = reports.length > 0;
		const hasStatusPriority = Boolean(
			data.case.status && data.case.priority,
		);
		checklist = {
			primaryOfficer: hasPrimaryOfficer,
			attachments: hasAttachments,
			reports: hasReports,
			statusPriority: hasStatusPriority,
		};
	}

	let casePage = $state(1);
	let casePerPage = $state(25);

	let activeStatus = $state("");

	let caseCounts = $derived.by(() => {
		const c = { all: cases.length, open: 0, in_progress: 0, closed: 0 };
		for (const item of cases) {
			if (item.status === "open") c.open++;
			else if (item.status === "in_progress") c.in_progress++;
			else if (item.status === "closed") c.closed++;
		}
		return c;
	});

	let allFilteredCases = $derived.by(() => {
		const query = searchQuery.trim().toLowerCase();
		let list = cases;
		if (activeStatus) list = list.filter((item) => item.status === activeStatus);
		if (query) {
			list = list.filter((item) =>
				[item.case_number, item.title, item.assigned_department]
					.filter(Boolean)
					.some((value) => String(value).toLowerCase().includes(query)),
			);
		}
		return list;
	});

	let filteredCaseList = $derived.by(() => {
		const start = (casePage - 1) * casePerPage;
		return allFilteredCases.slice(start, start + casePerPage);
	});

	// Reset page on search
	$effect(() => {
		searchQuery;
		activeStatus;
		casePage = 1;
	});

	async function handleCreateCase() {
		if (!newCase.title.trim()) return;
		const response = await caseService.createCase({
			title: newCase.title,
			summary: newCase.summary,
			status: newCase.status,
			priority: newCase.priority,
			department: newCase.department || undefined,
		});
		if (response.success) {
			showCreatePanel = false;
			showCaseView = true;
			newCase = {
				title: "",
				summary: "",
				status: "open",
				priority: "medium",
				department: "",
			};
			await loadCases();
			if (response.caseId) {
				await selectCase(response.caseId);
			}
		}
	}

	async function handleUpdateCase(update: Record<string, unknown>) {
		if (!selectedCase) return;
		await caseService.updateCase(selectedCase.case.id, update);
		await selectCase(selectedCase.case.id);
		await loadCases();
	}

	async function handleDeleteCase() {
		if (!selectedCase) return;
		const id = selectedCase.case.id;
		const success = await caseService.deleteCase(id);
		if (success) {
			selectedCase = null;
			showCaseView = false;
			await loadCases();
		}
	}

	function openCreatePanel() {
		selectedCase = null;
		showCreatePanel = true;
		showCaseView = true;
	}

	function closeCaseView() {
		showCreatePanel = false;
		showCaseView = false;
	}

	function formatDateValue(value: string | number | undefined): string {
		return formatDate(value, "-");
	}

	function formatTimeValue(value: string | number | undefined): string {
		return formatTime(value, "-");
	}

	async function handleOfficerSearch(query: string) {
		officerSearchQuery = query;
		if (!query.trim()) {
			searchService.clearResults();
			return;
		}
		await searchService.searchOfficers(query);
	}

	async function handleAssignOfficer(person: {
		citizenid?: string;
		id?: string;
	}) {
		if (!selectedCase) return;
		const citizenid = person.citizenid || person.id;
		if (!citizenid) return;
		await caseService.assignOfficer(
			selectedCase.case.id,
			citizenid,
			officerRole,
		);
		showOfficerSearch = false;
		searchService.clearResults();
		officerSearchQuery = "";
		await selectCase(selectedCase.case.id);
		updateChecklist(selectedCase);
	}

	async function handleRemoveOfficer(citizenid: string) {
		if (!selectedCase) return;
		await caseService.removeOfficer(selectedCase.case.id, citizenid);
		await selectCase(selectedCase.case.id);
		updateChecklist(selectedCase);
	}

	async function handleAddAttachment() {
		if (!selectedCase || !attachmentDraft.url.trim()) return;
		await caseService.addAttachment(selectedCase.case.id, {
			id: 0,
			type: attachmentDraft.type,
			url: attachmentDraft.url,
			label: attachmentDraft.label,
		});
		attachmentDraft = { type: "document", url: "", label: "" };
		await selectCase(selectedCase.case.id);
		updateChecklist(selectedCase);
	}

	async function handleUploadAttachment() {
		if (!selectedCase || !attachmentFile) return;
		attachmentError = "";
		if (attachmentFile.size > maxUploadBytes) {
			attachmentError = `File too large (max ${formatBytes(maxUploadBytes)})`;
			return;
		}
		if (!allowedAttachmentTypes.includes(attachmentFile.type)) {
			attachmentError = "Unsupported file type";
			return;
		}
		try {
			const base64 = await fileToBase64(attachmentFile);
			const response = await caseService.addAttachmentUpload(
				selectedCase.case.id,
				{
					data: base64,
					filename: attachmentFile.name,
					contentType: attachmentFile.type,
					label: attachmentDraft.label,
					type: attachmentDraft.type,
				},
			);
			if (!response.success) {
				attachmentError = "Failed to upload attachment";
				return;
			}
			attachmentFile = null;
			attachmentDraft = { type: "document", url: "", label: "" };
			await selectCase(selectedCase.case.id);
		} catch (error) {
			attachmentError = "Failed to upload attachment";
		}
	}

	async function handleRemoveAttachment(attachmentId: number) {
		if (!selectedCase) return;
		await caseService.removeAttachment(attachmentId);
		await selectCase(selectedCase.case.id);
		updateChecklist(selectedCase);
	}

	let evidenceDraft = $state({
		title: "",
		type: "Physical",
		serial: "",
		notes: "",
		location: "",
		stashId: "",
		stored: false,
	});
	let selectedEvidenceId = $state<number | null>(null);
	let evidenceCustody = $state<any[]>([]);
	let evidenceImageLabel = $state("");
	let evidenceImageFile = $state<File | null>(null);
	let evidenceError = $state("");
	let transferCitizenId = $state("");
	let transferNotes = $state("");
	const ACTION_LABELS: Record<string, string> = {
		case_created: "Created case",
		case_updated: "Updated case",
		case_deleted: "Deleted case",
		case_officer_assigned: "Assigned officer",
		case_officer_removed: "Removed officer",
		case_attachment_added: "Added attachment",
		case_attachment_uploaded: "Uploaded attachment",
		case_attachment_removed: "Removed attachment",
		evidence_added: "Added evidence",
		evidence_updated: "Updated evidence",
		evidence_deleted: "Deleted evidence",
		evidence_transferred: "Transferred evidence",
		evidence_image_added: "Added evidence image",
		evidence_image_removed: "Removed evidence image",
		evidence_linked_case: "Linked evidence to case",
		case_created_from_evidence: "Created case from evidence",
	};

	function formatAuditAction(action: string): string {
		return ACTION_LABELS[action] || action.replace(/_/g, " ");
	}

	function formatAuditDetails(details: string | null | undefined): string {
		if (!details) return "";
		try {
			const parsed = typeof details === "string" ? JSON.parse(details) : details;
			if (typeof parsed !== "object" || parsed === null) return String(details);
			const parts: string[] = [];
			for (const [key, value] of Object.entries(parsed)) {
				if (value === null || value === undefined || value === "") continue;
				const label = key.replace(/_/g, " ").replace(/([a-z])([A-Z])/g, "$1 $2");
				parts.push(`${label}: ${value}`);
			}
			return parts.join(" | ");
		} catch {
			return String(details);
		}
	}

	let auditLogs = $state<any[]>([]);
	let evidencePage = $state(1);
	let evidenceTotal = $state(0);
	let auditPage = $state(1);
	let auditTotal = $state(0);
	let pagedEvidence = $state<any[]>([]);
	let pagedAuditLogs = $state<any[]>([]);
	const pageSize = 5;
	const auditPageSize = 10;

	async function handleAddEvidence() {
		if (!selectedCase || !evidenceDraft.title.trim()) return;
		evidenceError = "";
		const response = await caseService.addEvidenceItem(
			selectedCase.case.id,
			{
				title: evidenceDraft.title,
				type: evidenceDraft.type,
				serial: evidenceDraft.serial,
				notes: evidenceDraft.notes,
				location: evidenceDraft.location,
				stashId: evidenceDraft.stashId,
				stored: evidenceDraft.stored,
			},
		);
		if (!response.success) {
			evidenceError = "Failed to add evidence";
			return;
		}
		evidenceDraft = {
			title: "",
			type: "Physical",
			serial: "",
			notes: "",
			location: "",
			stashId: "",
			stored: false,
		};
		await selectCase(selectedCase.case.id);
		updateChecklist(selectedCase);
	}

	async function handleUpdateEvidence(
		evidenceId: number,
		update: Record<string, unknown>,
	) {
		if (!selectedCase) return;
		await caseService.updateEvidenceItem(evidenceId, update);
		await selectCase(selectedCase.case.id);
	}

	async function handleDeleteEvidence(evidenceId: number) {
		if (!selectedCase) return;
		await caseService.deleteEvidenceItem(evidenceId);
		if (selectedEvidenceId === evidenceId) {
			selectedEvidenceId = null;
			evidenceCustody = [];
		}
		await selectCase(selectedCase.case.id);
	}

	async function handleSelectEvidence(evidenceId: number) {
		selectedEvidenceId = evidenceId;
		evidenceCustody = await caseService.getEvidenceCustody(evidenceId);
	}

	function evidenceTotalPages() {
		return Math.max(1, Math.ceil(evidenceTotal / pageSize));
	}

	function auditTotalPages() {
		return Math.max(1, Math.ceil(auditTotal / auditPageSize));
	}

	async function handleTransferEvidence(toCitizenId: string, notes: string) {
		if (!selectedEvidenceId) return;
		await caseService.transferEvidenceItem(
			selectedEvidenceId,
			toCitizenId,
			notes,
		);
		await handleSelectEvidence(selectedEvidenceId);
		await selectCase(selectedCase?.case.id || 0);
	}

	async function handleUploadEvidenceImage() {
		if (!selectedEvidenceId || !evidenceImageFile) return;
		evidenceError = "";
		if (evidenceImageFile.size > maxUploadBytes) {
			evidenceError = `Image too large (max ${formatBytes(maxUploadBytes)})`;
			return;
		}
		if (!allowedEvidenceImageTypes.includes(evidenceImageFile.type)) {
			evidenceError = "Unsupported image type";
			return;
		}
		try {
			const base64 = await fileToBase64(evidenceImageFile);
			const response = await caseService.addEvidenceImage(
				selectedEvidenceId,
				{
					id: 0,
					url: "",
					label: evidenceImageLabel,
					filename: evidenceImageFile.name,
					contentType: evidenceImageFile.type,
					data: base64,
				} as any,
			);
			if (!response.success) {
				evidenceError = "Failed to upload evidence image";
				return;
			}
			evidenceImageFile = null;
			evidenceImageLabel = "";
			await selectCase(selectedCase?.case.id || 0);
		} catch (error) {
			evidenceError = "Failed to upload evidence image";
		}
	}

	async function handleRemoveEvidenceImage(imageId: number) {
		if (!selectedEvidenceId) return;
		await caseService.removeEvidenceImage(imageId);
		await selectCase(selectedCase?.case.id || 0);
	}

	function formatStatus(status: string) {
		return status.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
	}

	function relativeTime(value: string | number | undefined): string {
		if (value == null) return "-";
		const then = typeof value === "number" ? value : Date.parse(String(value));
		if (Number.isNaN(then)) return formatDateValue(value);
		const diff = Date.now() - then;
		if (diff < 0) return "just now";
		const mins = Math.floor(diff / 60000);
		if (mins < 1) return "just now";
		if (mins < 60) return mins + "m ago";
		const hrs = Math.floor(mins / 60);
		if (hrs < 24) return hrs + "h ago";
		const days = Math.floor(hrs / 24);
		if (days < 30) return days + "d ago";
		return formatDateValue(value);
	}

	// Shared image lightbox: click any thumbnail/attachment to view it full-size. URLs are
	// shown as real images throughout rather than as raw links.
	let lightboxUrl = $state<string | null>(null);
	function openLightbox(url: string) { lightboxUrl = url; }

	// URLs that point at an image we can actually render inline. Everything else stays a
	// link so a PDF or doc URL doesn't render as a broken image.
	function isImageUrl(url?: string): boolean {
		if (!url) return false;
		return /\.(png|jpe?g|gif|webp|bmp|svg)(\?|#|$)/i.test(url) || url.startsWith("data:image");
	}

	function caseInitials(name?: string): string {
		if (!name) return "?";
		const parts = name.replace(/^\w+\.\s*/, "").trim().split(/\s+/);
		const a = (parts[0] && parts[0][0]) || "";
		const b = parts.length > 1 ? parts[parts.length - 1][0] : "";
		return (a + b).toUpperCase() || "?";
	}
</script>

<div class="cases-page">
	{#if showCaseView}
		<!-- ==================== CASE VIEW (Detail or Create) ==================== -->
		<div class="topbar">
			<button class="back-btn" onclick={closeCaseView}>
				<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
				Back
			</button>
			{#if showCreatePanel}
				<span class="topbar-title">New Case</span>
			{:else if selectedCase}
				<span class="topbar-title topbar-title--muted">Case File</span>
			{/if}
		</div>

		{#if showCreatePanel}
			<!-- ==================== CREATE PANEL ==================== -->
			<div class="detail-scroll">
				<div class="create-layout">
					<div class="create-main">
						<div class="section">
							<div class="section-title">Case Details</div>
							<input type="text" placeholder="Case Title" bind:value={newCase.title} class="form-input title-input" />
							<div class="field-row">
								<div class="field-group">
									<span class="field-label">Status</span>
									<select bind:value={newCase.status} class="form-select">
										{#each statusOptions as option}
											<option value={option}>{formatStatus(option)}</option>
										{/each}
									</select>
								</div>
								<div class="field-group">
									<span class="field-label">Priority</span>
									<select bind:value={newCase.priority} class="form-select">
										{#each priorityOptions as option}
											<option value={option}>{formatStatus(option)}</option>
										{/each}
									</select>
								</div>
								<div class="field-group">
									<span class="field-label">Department</span>
									<input class="form-input" bind:value={newCase.department} placeholder="Optional" />
								</div>
							</div>
							<div class="field-group" style="margin-top:12px;">
								<span class="field-label">Summary</span>
								<textarea rows="8" bind:value={newCase.summary} placeholder="Case summary and initial notes..." class="form-textarea"></textarea>
							</div>
						</div>
					</div>
					<div class="create-side">
						<div class="section">
							<div class="section-title">Checklist</div>
							<ul class="checklist">
								<li class:complete={checklist.primaryOfficer}>
									<span class="checkmark"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg></span>
									Assign primary officer
								</li>
								<li class:complete={checklist.attachments}>
									<span class="checkmark"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg></span>
									Attach evidence
								</li>
								<li class:complete={checklist.reports}>
									<span class="checkmark"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg></span>
									Attach reports
								</li>
								<li class:complete={checklist.statusPriority}>
									<span class="checkmark"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg></span>
									Set priority and status
								</li>
							</ul>
						</div>
						<div class="section">
							<div class="section-title">Next Actions</div>
							<p class="muted-text">After creation, open the case to manage officers, evidence, attachments, and audit logs.</p>
							{#if checklist.primaryOfficer && checklist.attachments && checklist.reports && checklist.statusPriority}
								<p class="muted-text">All checklist items complete.</p>
							{/if}
						</div>
						<button class="primary-btn create-btn" onclick={handleCreateCase} disabled={isCreateDisabled} type="button">Create Case</button>
					</div>
				</div>
			</div>

		{:else if selectedCase}
			<!-- ==================== CASE DETAIL VIEW ==================== -->
			<div class="detail-scroll">
				<!-- Hero header: the case's identity and vital stats before any editable
				     fields, so opening a case answers "what is this and who owns it" at once. -->
				<div class="case-hero prio-{selectedCase.case.priority}">
					<span class="hero-rail"></span>
					<div class="hero-body">
						<div class="hero-top">
							<span class="hero-number">{selectedCase.case.case_number}</span>
							<span class="cc-status status-{selectedCase.case.status}">{formatStatus(selectedCase.case.status)}</span>
							<span class="cc-prio prio-badge-{selectedCase.case.priority}">{selectedCase.case.priority} priority</span>
						</div>
						<h1 class="hero-title">{selectedCase.case.title}</h1>
						<div class="hero-meta">
							<span class="hero-avatar">{caseInitials(selectedCase.case.primary_officer_name)}</span>
							<span class="hero-officer">
								{selectedCase.case.primary_officer_callsign ? selectedCase.case.primary_officer_callsign + " · " : ""}{selectedCase.case.primary_officer_name || "Unassigned"}
							</span>
							{#if selectedCase.case.assigned_department}
								<span class="hero-dot">•</span>
								<span class="hero-dept">{selectedCase.case.assigned_department}</span>
							{/if}
							<span class="hero-dot">•</span>
							<span class="hero-updated">Updated {relativeTime(selectedCase.case.updated_at)}</span>
						</div>
					</div>
					</div>

				<!-- Tabs styled to match the roster's boss-tabs: uppercase, icon, accent
				     underline on the active one. -->
				<div class="detail-tabs">
					<button class="detail-tab" class:active={detailTab === "overview"} onclick={() => (detailTab = "overview")}>
						<span class="material-icons detail-tab-icon">description</span>
						Overview
					</button>
					<button class="detail-tab" class:active={detailTab === "evidence"} onclick={() => (detailTab = "evidence")}>
						<span class="material-icons detail-tab-icon">inventory_2</span>
						Evidence
						<span class="detail-tab-count">{selectedCase.evidence.length + selectedCase.attachments.length}</span>
					</button>
					<button class="detail-tab" class:active={detailTab === "reports"} onclick={() => (detailTab = "reports")}>
						<span class="material-icons detail-tab-icon">assignment</span>
						Reports
						<span class="detail-tab-count">{((selectedCase as any).reports || []).length}</span>
					</button>
					<button class="detail-tab" class:active={detailTab === "notes"} onclick={() => (detailTab = "notes")}>
						<span class="material-icons detail-tab-icon">sticky_note_2</span>
						Notes
						<span class="detail-tab-count">{(selectedCase.notes || []).length}</span>
					</button>
					<button class="detail-tab" class:active={detailTab === "activity"} onclick={() => (detailTab = "activity")}>
						<span class="material-icons detail-tab-icon">history</span>
						Activity
					</button>
				</div>

				{#if detailTab === "overview"}
				<!-- Info Section -->
				<div class="section info-section">
					<div class="section-header">
						<div class="section-title" style="margin-bottom:0;">Summary</div>
						{#if !editingSummary}
							<button class="ghost-btn" onclick={startEditSummary}>
								<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>
								Edit
							</button>
						{/if}
					</div>

					{#if editingSummary}
						<textarea class="summary-edit" rows="4" bind:value={summaryDraft} placeholder="Describe the case..."></textarea>
						<div class="summary-actions">
							<button class="ghost-btn" onclick={() => (editingSummary = false)}>Cancel</button>
							<button class="save-btn" onclick={saveSummary}>Save</button>
						</div>
					{:else}
						<p class="summary-text" class:empty={!selectedCase.case.summary}>
							{selectedCase.case.summary || "No summary yet — click Edit to add one."}
						</p>
					{/if}

					<!-- Status and priority as segmented pickers rather than dropdowns: the
					     choice is visible and colour-coded, and changing it is one click. -->
					<div class="control-grid">
						<div class="control-block">
							<span class="control-label">Status</span>
							<div class="seg">
								{#each statusOptions as option}
									<button
										class="seg-btn seg-status-{option}"
										class:active={selectedCase.case.status === option}
										onclick={() => handleUpdateCase({ status: option })}
									>{formatStatus(option)}</button>
								{/each}
							</div>
						</div>
						<div class="control-block">
							<span class="control-label">Priority</span>
							<div class="seg">
								{#each priorityOptions as option}
									<button
										class="seg-btn seg-prio-{option}"
										class:active={selectedCase.case.priority === option}
										onclick={() => handleUpdateCase({ priority: option })}
									>{formatStatus(option)}</button>
								{/each}
							</div>
						</div>
					</div>

					<div class="control-block">
						<span class="control-label">Department</span>
						<input class="form-input dept-input" value={selectedCase.case.assigned_department || ""} placeholder="Unassigned" onchange={(event) => handleUpdateCase({ department: (event.target as HTMLInputElement).value })} />
					</div>

					<!-- Provenance: who opened the case and when — plainly stated, where it
					     was invisible before. -->
					<div class="info-foot">
						<span class="info-foot-item">
							Opened by <strong>{selectedCase.case.created_by_name || selectedCase.case.created_by || "Unknown"}</strong>
						</span>
						<span class="info-foot-sep">•</span>
						<span class="info-foot-item">{formatDateValue(selectedCase.case.created_at)}</span>
						<div style="flex:1;"></div>
						<button class="danger-link" onclick={handleDeleteCase}>
							<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
							Delete case
						</button>
					</div>
				</div>

				<!-- Officers Section -->
				<div class="section">
					<div class="section-header">
						<div class="section-title" style="margin-bottom:0;">Officers</div>
						<div class="inline-controls">
							<select bind:value={officerRole} class="form-select-sm">
								<option value="primary">Primary</option>
								<option value="assisting">Assisting</option>
								<option value="supervisor">Supervisor</option>
							</select>
							<button class="action-btn" onclick={() => (showOfficerSearch = true)}>
								<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
								Add Officer
							</button>
						</div>
					</div>
					{#if selectedCase.officers.length === 0}
						<p class="muted-text">No officers assigned.</p>
					{:else}
						<div class="officer-grid">
							{#each selectedCase.officers as officer}
								<div class="officer-card role-{officer.role}">
									{#if officer.profilepicture}
										<!-- svelte-ignore a11y_click_events_have_key_events -->
										<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
										<img
											class="officer-photo"
											src={officer.profilepicture}
											alt={officer.fullname || officer.citizenid}
											role="button"
											tabindex="-1"
											onclick={() => openLightbox(officer.profilepicture!)}
										/>
									{:else}
										<span class="officer-photo officer-photo--fallback">{caseInitials(officer.fullname)}</span>
									{/if}
									<div class="officer-info">
										<span class="officer-name">
											{officer.callsign ? officer.callsign + " · " : ""}{officer.fullname || officer.citizenid}
										</span>
										<span class="officer-sub">
											{officer.rank || "Officer"}{officer.badge_number ? " · #" + officer.badge_number : ""}
										</span>
									</div>
									<span class="officer-role role-badge-{officer.role}">{officer.role}</span>
									<button class="officer-remove" aria-label="Remove officer" onclick={() => handleRemoveOfficer(officer.citizenid)}>
										<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
									</button>
								</div>
							{/each}
						</div>
					{/if}
				</div>

				{/if}

				{#if detailTab === "reports"}
				<!-- Linked Reports Section -->
				<div class="section">
					<div class="section-header">
						<div class="section-title" style="margin-bottom:0;">Linked Reports</div>
						<div class="inline-controls">
							<input class="form-input-sm" placeholder="Report ID" bind:value={reportLinkId} />
							<button class="action-btn" onclick={handleLinkReport}>
								<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>
								Link
							</button>
						</div>
					</div>
					{#if (selectedCase as any).reports && (selectedCase as any).reports.length > 0}
						<div class="item-list">
							{#each (selectedCase as any).reports as report}
								<div class="list-item">
									<div class="list-item-info">
										<!-- svelte-ignore a11y_click_events_have_key_events -->
										<strong class="nav-link" role="button" tabindex="-1" onclick={() => navigateTo("Reports")}>#{report.id}</strong>
										<span>{report.title}</span>
									</div>
									<button class="remove-btn" onclick={() => handleUnlinkReport(report.id)}>
										<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
									</button>
								</div>
							{/each}
						</div>
					{:else}
						<p class="muted-text">No linked reports.</p>
					{/if}
				</div>

				{/if}

				{#if detailTab === "notes"}
				<!-- Notes Section -->
				<div class="section">
					<div class="section-title">Notes</div>
					<div class="note-input-row">
						<textarea class="form-textarea" placeholder="Add a note..." bind:value={noteContent} rows="2"></textarea>
						<button class="action-btn" disabled={!noteContent.trim() || noteSubmitting} onclick={handleAddNote}>
							{noteSubmitting ? "Saving..." : "Add Note"}
						</button>
					</div>
					{#if selectedCase.notes && selectedCase.notes.length > 0}
						<div class="notes-list">
							{#each selectedCase.notes as note}
								<div class="note-item">
									<div class="note-header">
										<span class="note-author">{note.author_name || "Unknown"}</span>
										<span class="note-date">{note.created_at ? formatDateTime(note.created_at) : ""}</span>
										<button class="remove-btn" onclick={() => handleDeleteNote(note.id)}>
											<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
										</button>
									</div>
									<p class="note-content">{note.content}</p>
								</div>
							{/each}
						</div>
					{:else}
						<p class="muted-text">No notes yet.</p>
					{/if}
				</div>

				{/if}

				{#if detailTab === "evidence"}
				<!-- Attachments Section -->
				<div class="section">
					<div class="section-title">Attachments</div>
					<div class="attachment-form">
						<select bind:value={attachmentDraft.type} class="form-select">
							<option value="photo">Photo</option>
							<option value="document">Document</option>
							<option value="other">Other</option>
						</select>
						<input class="form-input" placeholder="URL" bind:value={attachmentDraft.url} />
						<input class="form-input" placeholder="Label" bind:value={attachmentDraft.label} />
						<button class="action-btn" onclick={handleAddAttachment}>Add</button>
					</div>
					{#if attachmentError}
						<p class="error-text">{attachmentError}</p>
					{/if}
					{#if selectedCase.attachments.length === 0}
						<p class="muted-text">No attachments yet.</p>
					{:else}
						<div class="thumb-grid">
							{#each selectedCase.attachments as attachment}
								<div class="thumb">
									{#if isImageUrl(attachment.url)}
										<!-- svelte-ignore a11y_click_events_have_key_events -->
										<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
										<img src={attachment.url} alt={attachment.label || attachment.type} role="button" tabindex="-1" onclick={() => openLightbox(attachment.url)} />
									{:else}
										<a class="thumb-link" href={attachment.url} target="_blank" rel="noopener noreferrer">
											<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
										</a>
									{/if}
									<span class="thumb-label">{attachment.label || attachment.type}</span>
									<button class="thumb-remove" aria-label="Remove attachment" onclick={() => handleRemoveAttachment(attachment.id)}>
										<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
									</button>
								</div>
							{/each}
						</div>
					{/if}
				</div>

				<!-- Evidence Section -->
				<div class="section">
					<div class="section-title">Evidence</div>
					<div class="evidence-form-grid">
						<div class="field-group">
							<span class="field-label">Title</span>
							<input class="form-input" bind:value={evidenceDraft.title} />
						</div>
						<div class="field-group">
							<span class="field-label">Type</span>
							<input class="form-input" bind:value={evidenceDraft.type} />
						</div>
						<div class="field-group">
							<span class="field-label">Serial</span>
							<input class="form-input" bind:value={evidenceDraft.serial} />
						</div>
						<div class="field-group">
							<span class="field-label">Location</span>
							<input class="form-input" bind:value={evidenceDraft.location} />
						</div>
						<div class="field-group">
							<span class="field-label">Stash ID</span>
							<input class="form-input" bind:value={evidenceDraft.stashId} />
						</div>
						<div class="field-group">
							<span class="field-label">Notes</span>
							<textarea rows="2" class="form-textarea" bind:value={evidenceDraft.notes}></textarea>
						</div>
					</div>
					<div class="evidence-actions-row">
						<label class="checkbox-label">
							<input type="checkbox" bind:checked={evidenceDraft.stored} />
							Stored
						</label>
						<button class="primary-btn" onclick={handleAddEvidence}>Add Evidence</button>
					</div>
					{#if evidenceError}
						<p class="error-text">{evidenceError}</p>
					{/if}
					{#if selectedCase.evidence.length === 0}
						<p class="muted-text">No evidence logged.</p>
					{:else}
						<div class="item-list">
							{#each pagedEvidence as item}
								<div class="list-item">
									<button class="evidence-select" onclick={() => handleSelectEvidence(item.id)}>
										<strong>{item.title}</strong>
										<span>{item.type}</span>
										<span>{item.serial || ""}</span>
								</button>
								<!-- svelte-ignore a11y_click_events_have_key_events -->
								<span class="nav-link nav-link-sm" role="button" tabindex="-1" onclick={() => navigateTo("Evidence")}>View in Evidence</span>
									<div class="evidence-actions">
										<button class="action-btn" onclick={() => handleUpdateEvidence(item.id, { stored: !item.stored })}>
											{item.stored ? "Unstore" : "Store"}
										</button>
										<button class="remove-btn" onclick={() => handleDeleteEvidence(item.id)}>
											<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
											Remove
										</button>
									</div>
								</div>
							{/each}
						</div>
						<div class="pagination">
							<button class="page-btn" disabled={evidencePage === 1} onclick={async () => {
								evidencePage = Math.max(1, evidencePage - 1);
								if (selectedCase) {
									const response = await caseService.getCaseEvidencePage(selectedCase.case.id, evidencePage, pageSize);
									if (response.success && response.data) {
										pagedEvidence = response.data.items || [];
										evidenceTotal = response.data.total || 0;
									}
								}
							}}>Prev</button>
							<span class="page-info">Page {evidencePage} / {evidenceTotalPages()}</span>
							<button class="page-btn" disabled={evidencePage >= evidenceTotalPages()} onclick={async () => {
								evidencePage = Math.min(evidenceTotalPages(), evidencePage + 1);
								if (selectedCase) {
									const response = await caseService.getCaseEvidencePage(selectedCase.case.id, evidencePage, pageSize);
									if (response.success && response.data) {
										pagedEvidence = response.data.items || [];
										evidenceTotal = response.data.total || 0;
									}
								}
							}}>Next</button>
						</div>
					{/if}
				</div>

				<!-- Evidence Custody (when evidence selected) -->
				{#if selectedEvidenceId}
					<div class="section">
						<div class="section-title">Evidence Custody</div>
						<div class="transfer-row">
							<input class="form-input" placeholder="Transfer to Citizen ID" bind:value={transferCitizenId} />
							<input class="form-input" placeholder="Transfer notes" bind:value={transferNotes} />
							<button class="action-btn" onclick={() => {
								handleTransferEvidence(transferCitizenId, transferNotes);
								transferCitizenId = "";
								transferNotes = "";
							}}>Transfer</button>
						</div>
						<div class="upload-row">
							<input type="file" accept=".jpg,.jpeg,.png,.webp" class="file-input" onchange={(event) => {
								const input = event.target as HTMLInputElement;
								evidenceImageFile = input.files && input.files[0] ? input.files[0] : null;
							}} />
							<input class="form-input" placeholder="Image label" bind:value={evidenceImageLabel} />
							<button class="primary-btn" onclick={handleUploadEvidenceImage}>Upload Image</button>
						</div>
						{#if selectedCase?.evidence}
							{#each selectedCase.evidence.filter((e) => e.id === selectedEvidenceId) as item}
								{#if item.images && item.images.length > 0}
									<div class="thumb-grid">
										{#each item.images as image}
											<div class="thumb">
												{#if isImageUrl(image.url)}
													<!-- svelte-ignore a11y_click_events_have_key_events -->
													<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
													<img src={image.url} alt={image.label || "Evidence"} role="button" tabindex="-1" onclick={() => openLightbox(image.url)} />
												{:else}
													<a class="thumb-link" href={image.url} target="_blank" rel="noopener noreferrer">
														<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>
													</a>
												{/if}
												{#if image.label}<span class="thumb-label">{image.label}</span>{/if}
												<button class="thumb-remove" aria-label="Remove image" onclick={() => handleRemoveEvidenceImage(image.id)}>
													<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
												</button>
											</div>
										{/each}
									</div>
								{/if}
							{/each}
						{/if}
						{#if evidenceCustody.length === 0}
							<p class="muted-text">No custody updates yet.</p>
						{:else}
							<div class="custody-list">
								{#each evidenceCustody as entry}
									<div class="custody-item">
										<span>{entry.action}</span>
										<span>{entry.from_citizenid || ""}{entry.to_citizenid ? " -> " + entry.to_citizenid : ""}</span>
										<span>{entry.notes || ""}</span>
									</div>
								{/each}
							</div>
						{/if}
					</div>
				{/if}

				{/if}

				{#if detailTab === "activity"}
				<!-- Audit Log Section -->
				<div class="section">
					<div class="section-title">Audit Log</div>
					{#if auditLogs.length === 0}
						<p class="muted-text">No audit entries found.</p>
					{:else}
						<div class="audit-list">
							{#each pagedAuditLogs as entry}
								<div class="audit-item">
									<div>
										<strong>{formatAuditAction(entry.action)}</strong>
										<span>{entry.actor_name || entry.actor_citizenid || "System"}</span>
									</div>
									<div class="audit-meta">
										<span>{entry.entity_type} #{entry.entity_id}</span>
									</div>
									<div class="audit-details">
										{formatAuditDetails(entry.details)}
									</div>
								</div>
							{/each}
						</div>
						<div class="pagination">
							<button class="page-btn" disabled={auditPage === 1} onclick={async () => {
								auditPage = Math.max(1, auditPage - 1);
								if (selectedCase) {
									const response = await caseService.getCaseAuditLogs(selectedCase.case.id, auditPage, auditPageSize);
									auditLogs = response.items || [];
									auditTotal = response.total || 0;
									pagedAuditLogs = auditLogs;
								}
							}}>Prev</button>
							<span class="page-info">Page {auditPage} / {auditTotalPages()}</span>
							<button class="page-btn" disabled={auditPage >= auditTotalPages()} onclick={async () => {
								auditPage = Math.min(auditTotalPages(), auditPage + 1);
								if (selectedCase) {
									const response = await caseService.getCaseAuditLogs(selectedCase.case.id, auditPage, auditPageSize);
									auditLogs = response.items || [];
									auditTotal = response.total || 0;
									pagedAuditLogs = auditLogs;
								}
							}}>Next</button>
						</div>
					{/if}
				</div>
				{/if}
			</div>

		{:else}
			<div class="section empty-detail">
				<h3>Select a case to view details</h3>
				<p>Use the list to open a case or create a new one.</p>
			</div>
		{/if}

	{:else}
		<!-- ==================== LIST VIEW ==================== -->
		<div class="topbar">
			<div class="search-box">
				<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.3)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
				<input type="text" placeholder="Search cases..." bind:value={searchQuery} />
			</div>
			<select class="form-select-sm" bind:value={filters.status} onchange={loadCases}>
				<option value="">All Status</option>
				{#each statusOptions as option}
					<option value={option}>{formatStatus(option)}</option>
				{/each}
			</select>
			<select class="form-select-sm" bind:value={filters.priority} onchange={loadCases}>
				<option value="">All Priority</option>
				{#each priorityOptions as option}
					<option value={option}>{formatStatus(option)}</option>
				{/each}
			</select>
			<div style="flex:1;"></div>
			<button class="action-btn" onclick={openCreatePanel}>
				<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
				New Case
			</button>
			<button class="back-btn" onclick={loadCases} disabled={isLoading}>
				<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>
				Refresh
			</button>
		</div>

		<div class="stat-bar">
			<button class="stat" class:active={activeStatus === ""} onclick={() => (activeStatus = "")}>
				<span class="stat-num">{caseCounts.all}</span>
				<span class="stat-label">All Cases</span>
			</button>
			<button class="stat stat-open" class:active={activeStatus === "open"} onclick={() => (activeStatus = activeStatus === "open" ? "" : "open")}>
				<span class="stat-num">{caseCounts.open}</span>
				<span class="stat-label">Open</span>
			</button>
			<button class="stat stat-progress" class:active={activeStatus === "in_progress"} onclick={() => (activeStatus = activeStatus === "in_progress" ? "" : "in_progress")}>
				<span class="stat-num">{caseCounts.in_progress}</span>
				<span class="stat-label">In Progress</span>
			</button>
			<button class="stat stat-closed" class:active={activeStatus === "closed"} onclick={() => (activeStatus = activeStatus === "closed" ? "" : "closed")}>
				<span class="stat-num">{caseCounts.closed}</span>
				<span class="stat-label">Closed</span>
			</button>
		</div>

		<div class="list-panel">
			{#if isLoading && cases.length === 0}
				<SkeletonList rows={8} thumb={false} columns={[2.2, 1, 1, 0.8]} />
			{:else if filteredCaseList.length === 0}
				<div class="center-state">
					<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>
					{#if searchQuery || activeStatus}
						<h3>No matching cases</h3>
						<p>
							{#if searchQuery && activeStatus}
								No {formatStatus(activeStatus).toLowerCase()} cases match "{searchQuery}".
							{:else if activeStatus}
								There are no {formatStatus(activeStatus).toLowerCase()} cases right now.
							{:else}
								No cases match "{searchQuery}".
							{/if}
						</p>
						<button class="ghost-btn" onclick={() => { searchQuery = ""; activeStatus = ""; }}>Clear filters</button>
					{:else}
						<h3>No cases yet</h3>
						<p>No cases have been created yet.</p>
						<button class="action-btn" onclick={openCreatePanel}>Create First Case</button>
					{/if}
				</div>
			{:else}
				<div class="case-rows">
				{#each filteredCaseList.slice().reverse() as item}
					<button class="case-row" onclick={() => selectCase(item.id)}>
						<!-- Priority dot: a single quiet signal, colour only. -->
						<span class="cr-dot prio-dot-{item.priority}" title={item.priority}></span>

						<div class="cr-body">
							<div class="cr-head">
								<span class="cr-title">{item.title}</span>
								<span class="cr-number">{item.case_number}</span>
							</div>
							{#if item.summary}
								<div class="cr-summary">{item.summary}</div>
							{/if}
						</div>

						<div class="cr-officer">
							<span class="cr-avatar">{caseInitials(item.primary_officer_name)}</span>
							<span class="cr-officer-name">{item.primary_officer_name || "Unassigned"}</span>
						</div>

						<span class="cr-status status-{item.status}">{formatStatus(item.status)}</span>

						<div class="cr-time">
							<span class="cr-time-val">{relativeTime(item.updated_at)}</span>
							<span class="cr-time-label">updated</span>
						</div>

						<svg class="cr-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>
					</button>
				{/each}
			</div>
			{/if}
			<Pagination
				currentPage={casePage}
				totalItems={allFilteredCases.length}
				perPage={casePerPage}
				onPageChange={(p) => { casePage = p; }}
				onPerPageChange={(pp) => { casePerPage = pp; casePage = 1; }}
			/>
		</div>
	{/if}
</div>

<PersonSearchModal
	show={showOfficerSearch}
	title="Search Officers"
	searchQuery={officerSearchQuery}
	searchResults={searchService.state.results}
	onClose={() => {
		showOfficerSearch = false;
		officerSearchQuery = "";
	}}
	onSearch={handleOfficerSearch}
	onSelect={handleAssignOfficer}
/>

{#if lightboxUrl}
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="lightbox" onclick={() => (lightboxUrl = null)}>
		<img src={lightboxUrl} alt="Preview" onclick={(e) => e.stopPropagation()} />
		<button class="lightbox-close" aria-label="Close" onclick={() => (lightboxUrl = null)}>
			<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
		</button>
	</div>
{/if}

<style>
	/* ===== PAGE ===== */
	.cases-page {
		height: 100%;
		background: var(--card-dark-bg);
		color: rgba(255, 255, 255, 0.9);
		display: flex;
		flex-direction: column;
		overflow: hidden;
	}

	/* ===== TOPBAR ===== */
	.topbar {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 0 16px;
		height: 42px;
		flex-shrink: 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}

	.topbar-title {
		color: rgba(255, 255, 255, 0.85);
		font-size: 13px;
		font-weight: 600;
	}

	.topbar-case-number {
		color: rgba(255, 255, 255, 0.3);
		font-size: 10px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.8px;
	}

	/* ===== SEARCH BOX ===== */
	.search-box {
		display: flex;
		align-items: center;
		gap: 8px;
		background: transparent;
		border: none;
		padding: 0;
		min-width: 240px;
	}

	.search-box input {
		background: transparent;
		border: none;
		color: rgba(255, 255, 255, 0.8);
		font-size: 12px;
		padding: 0;
		outline: none;
		width: 100%;
	}

	.search-box input::placeholder {
		color: rgba(255, 255, 255, 0.2);
	}

	/* ===== BUTTONS ===== */
	.back-btn {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		background: transparent;
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 4px 10px;
		color: rgba(255, 255, 255, 0.4);
		font-size: 10px;
		font-weight: 500;
		cursor: pointer;
		transition: all 0.1s;
	}

	.back-btn:hover:not(:disabled) {
		color: rgba(255, 255, 255, 0.7);
		border-color: rgba(255, 255, 255, 0.1);
	}

	.back-btn:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	.action-btn {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		background: rgba(var(--accent-rgb), 0.06);
		color: rgba(var(--accent-text-rgb), 0.7);
		border: 1px solid rgba(var(--accent-rgb), 0.1);
		padding: 4px 10px;
		border-radius: 3px;
		font-size: 10px;
		font-weight: 500;
		cursor: pointer;
		transition: all 0.1s;
		flex-shrink: 0;
		white-space: nowrap;
	}

	.action-btn:hover {
		background: rgba(var(--accent-rgb), 0.12);
		color: rgba(var(--accent-text-rgb), 0.9);
	}

	.primary-btn {
		background: rgba(var(--accent-rgb), 0.08);
		color: rgba(var(--accent-text-rgb), 0.8);
		border: 1px solid rgba(var(--accent-rgb), 0.12);
		border-radius: 3px;
		padding: 4px 10px;
		font-size: 10px;
		font-weight: 500;
		cursor: pointer;
		transition: all 0.1s;
		white-space: nowrap;
	}

	.primary-btn:hover:not(:disabled) {
		background: rgba(var(--accent-rgb), 0.14);
	}

	.primary-btn:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	.danger-btn {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		background: transparent;
		color: rgba(239, 68, 68, 0.5);
		border: 1px solid rgba(239, 68, 68, 0.1);
		border-radius: 3px;
		padding: 4px 10px;
		font-size: 10px;
		font-weight: 500;
		cursor: pointer;
		transition: all 0.1s;
	}

	.danger-btn:hover {
		background: rgba(239, 68, 68, 0.08);
		color: rgba(252, 165, 165, 0.8);
	}

	.remove-btn {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		background: transparent;
		border: none;
		border-radius: 3px;
		padding: 3px 6px;
		color: rgba(255, 255, 255, 0.35);
		font-size: 10px;
		cursor: pointer;
		transition: all 0.1s;
		flex-shrink: 0;
		opacity: 0;
	}

	.list-item:hover .remove-btn,
	.remove-btn:hover {
		background: rgba(239, 68, 68, 0.1);
		color: rgba(252, 165, 165, 0.8);
	}

	.page-btn {
		display: inline-flex;
		align-items: center;
		background: transparent;
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 3px 8px;
		color: rgba(255, 255, 255, 0.4);
		font-size: 10px;
		cursor: pointer;
		transition: all 0.1s;
	}

	.page-btn:hover:not(:disabled) {
		color: rgba(255, 255, 255, 0.7);
		border-color: rgba(255, 255, 255, 0.1);
	}

	.page-btn:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	/* ===== PILLS ===== */
	.pill {
		padding: 1px 6px;
		border-radius: 3px;
		font-size: 10px;
		font-weight: 600;
		text-transform: capitalize;
		white-space: nowrap;
	}

	.pill-red {
		background: rgba(239, 68, 68, 0.08);
		color: rgba(248, 113, 113, 0.8);
		border: 1px solid rgba(239, 68, 68, 0.1);
	}

	.pill-orange {
		background: rgba(245, 158, 11, 0.08);
		color: rgba(251, 191, 36, 0.8);
		border: 1px solid rgba(245, 158, 11, 0.1);
	}

	.pill-green {
		background: rgba(16, 185, 129, 0.08);
		color: rgba(52, 211, 153, 0.8);
		border: 1px solid rgba(16, 185, 129, 0.1);
	}

	.pill-blue {
		background: rgba(var(--accent-rgb), 0.08);
		color: rgba(96, 165, 250, 0.8);
		border: 1px solid rgba(var(--accent-rgb), 0.1);
	}

	.pill-grey {
		background: rgba(107, 114, 128, 0.08);
		color: rgba(156, 163, 175, 0.8);
		border: 1px solid rgba(107, 114, 128, 0.1);
	}

	/* ===== LIST PANEL (TABLE) ===== */
	.list-panel {
		background: transparent;
		border: none;
		border-radius: 0;
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		overflow: hidden;
	}

	.table-header {
		display: grid;
		grid-template-columns: 2fr 1fr 0.8fr 0.8fr 1fr 1.2fr 0.9fr 0.9fr;
		gap: 8px;
		padding: 8px 16px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}

	.table-header span {
		color: rgba(255, 255, 255, 0.35);
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
	}

	.table-body {
		flex: 1;
		overflow-y: auto;
	}

	.table-row {
		display: grid;
		grid-template-columns: 2fr 1fr 0.8fr 0.8fr 1fr 1.2fr 0.9fr 0.9fr;
		gap: 8px;
		padding: 7px 16px;
		border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
		background: transparent;
		width: 100%;
		text-align: left;
		cursor: pointer;
		transition: background 0.1s;
		align-items: center;
	}

	.table-row:hover {
		background: rgba(255, 255, 255, 0.02);
	}

	.table-row span {
		font-size: 11px;
		color: rgba(255, 255, 255, 0.45);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.row-title {
		color: rgba(255, 255, 255, 0.85) !important;
		font-weight: 500;
	}

	.row-case {
		color: rgba(96, 165, 250, 0.7) !important;
		font-weight: 500;
	}

	.nav-link {
		color: rgba(var(--accent-rgb), 0.6);
		cursor: pointer;
		transition: all 0.1s;
	}

	.nav-link:hover {
		color: rgba(var(--accent-rgb), 0.9);
		text-decoration: underline;
	}

	.nav-link-sm {
		font-size: 10px;
		white-space: nowrap;
		flex-shrink: 0;
	}

	/* ===== SECTIONS (Detail/Create) ===== */
	.section {
		background: transparent;
		border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.04);
		border-radius: 0;
		padding: 12px 16px;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.section:last-child {
		border-bottom: none;
	}

	.section-title {
		color: rgba(255, 255, 255, 0.35);
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		margin-bottom: 2px;
	}

	.section-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 10px;
	}

	.detail-scroll {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 0;
		padding-bottom: 12px;
	}

	/* ===== FORM INPUTS ===== */
	.form-input {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 5px 8px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 11px;
		outline: none;
		transition: border-color 0.1s;
		width: 100%;
		box-sizing: border-box;
	}

	.form-input:focus {
		border-color: rgba(255, 255, 255, 0.1);
	}

	.form-input::placeholder {
		color: rgba(255, 255, 255, 0.2);
	}

	.form-input-sm {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 4px 8px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 11px;
		outline: none;
		width: 90px;
	}

	.form-input-sm::placeholder {
		color: rgba(255, 255, 255, 0.2);
	}

	.form-select {
		padding: 5px 22px 5px 8px;
		font-size: 10px;
		text-transform: capitalize;
	}

	.form-select-sm {
		padding: 4px 20px 4px 8px;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.5);
	}

	.form-textarea {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 5px 8px;
		color: rgba(255, 255, 255, 0.8);
		font-size: 11px;
		outline: none;
		resize: vertical;
		width: 100%;
		box-sizing: border-box;
		min-height: 60px;
	}

	.form-textarea:focus {
		border-color: rgba(255, 255, 255, 0.1);
	}

	.form-textarea::placeholder {
		color: rgba(255, 255, 255, 0.2);
	}

	.title-input {
		font-size: 14px;
		font-weight: 600;
		padding: 6px 8px;
		background: transparent;
		border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.04);
		border-radius: 0;
	}

	.title-input:focus {
		border-bottom-color: rgba(255, 255, 255, 0.1);
	}

	.file-input {
		font-size: 10px;
		color: rgba(255, 255, 255, 0.4);
	}

	.file-input::file-selector-button {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 3px;
		padding: 3px 8px;
		color: rgba(255, 255, 255, 0.5);
		font-size: 10px;
		cursor: pointer;
		margin-right: 6px;
	}

	/* ===== FIELD LAYOUT ===== */
	.field-row {
		display: flex;
		gap: 10px;
		align-items: flex-end;
		flex-wrap: wrap;
	}

	.field-group {
		display: flex;
		flex-direction: column;
		gap: 3px;
		min-width: 120px;
		flex: 1;
	}

	.field-group-actions {
		display: flex;
		flex-direction: row;
		align-items: center;
		gap: 6px;
		min-width: auto;
		flex: none;
	}

	.field-label {
		color: rgba(255, 255, 255, 0.35);
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.5px;
	}

	.summary-text {
		color: rgba(255, 255, 255, 0.5);
		font-size: 11px;
		margin: 0;
		line-height: 1.5;
	}

	/* ===== INLINE CONTROLS ===== */
	.inline-controls {
		display: flex;
		gap: 6px;
		align-items: center;
	}

	/* ===== CHIPS ===== */


	/* ===== ITEM LIST ===== */
	.item-list {
		display: flex;
		flex-direction: column;
		gap: 0;
	}

	.list-item {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 10px;
		background: transparent;
		border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
		border-radius: 0;
		padding: 6px 0;
	}

	.list-item:last-child {
		border-bottom: none;
	}

	.list-item-info {
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-width: 0;
		flex: 1;
	}

	.list-item-info strong {
		color: rgba(255, 255, 255, 0.85);
		font-size: 11px;
		font-weight: 600;
	}

	.list-item-info span {
		color: rgba(255, 255, 255, 0.3);
		font-size: 10px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	/* ===== ATTACHMENT FORM ===== */
	.attachment-form {
		display: grid;
		grid-template-columns: auto 1fr 1fr auto;
		gap: 6px;
		align-items: center;
	}

	.upload-row {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		align-items: center;
	}

	/* ===== EVIDENCE ===== */
	.evidence-form-grid {
		display: grid;
		grid-template-columns: 1fr 1fr 1fr;
		gap: 8px;
	}

	.evidence-actions-row {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.evidence-select {
		background: transparent;
		border: none;
		color: rgba(255, 255, 255, 0.85);
		text-align: left;
		display: flex;
		flex-direction: column;
		gap: 1px;
		cursor: pointer;
		flex: 1;
		min-width: 0;
		padding: 0;
	}

	.evidence-select strong {
		font-size: 11px;
	}

	.evidence-select span {
		font-size: 10px;
		color: rgba(255, 255, 255, 0.3);
	}

	.evidence-actions {
		display: flex;
		gap: 4px;
		flex-shrink: 0;
	}

	.checkbox-label {
		display: flex;
		align-items: center;
		gap: 5px;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.5);
		cursor: pointer;
	}

	/* ===== TRANSFER / CUSTODY ===== */
	.transfer-row {
		display: grid;
		grid-template-columns: 1fr 2fr auto;
		gap: 6px;
		align-items: center;
	}

	.custody-list {
		display: flex;
		flex-direction: column;
		gap: 0;
	}

	.custody-item {
		display: grid;
		grid-template-columns: 100px 1fr 2fr;
		gap: 8px;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.4);
		padding: 4px 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
	}

	/* ===== AUDIT ===== */
	.audit-list {
		display: flex;
		flex-direction: column;
		gap: 0;
	}

	.audit-item {
		display: grid;
		grid-template-columns: 1.5fr 1fr 2fr;
		gap: 8px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
		padding: 6px 0;
		font-size: 11px;
	}

	.audit-item strong {
		color: rgba(255, 255, 255, 0.7);
		font-size: 11px;
	}

	.audit-item span {
		display: block;
		color: rgba(255, 255, 255, 0.35);
		font-size: 10px;
	}

	.audit-meta {
		display: flex;
		flex-direction: column;
		gap: 1px;
	}

	.audit-meta span {
		color: rgba(255, 255, 255, 0.2) !important;
		text-transform: uppercase;
		font-size: 9px !important;
		letter-spacing: 0.3px;
	}

	.audit-details {
		color: rgba(255, 255, 255, 0.35);
		font-size: 10px;
		white-space: pre-wrap;
	}

	/* ===== PAGINATION ===== */
	.pagination {
		display: flex;
		justify-content: flex-end;
		align-items: center;
		gap: 6px;
		margin-top: 4px;
	}

	.page-info {
		color: rgba(255, 255, 255, 0.35);
		font-size: 10px;
	}

	/* ===== STATES ===== */
	.center-state {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		flex: 1;
		text-align: center;
		padding: 60px 20px;
	}

	.center-state h3 {
		color: rgba(255, 255, 255, 0.5);
		font-size: 14px;
		font-weight: 600;
		margin: 12px 0 4px;
	}

	.center-state p {
		color: rgba(255, 255, 255, 0.35);
		font-size: 11px;
		margin: 0 0 12px;
	}

	.empty-detail {
		align-items: center;
		text-align: center;
	}

	.empty-detail h3 {
		color: rgba(255, 255, 255, 0.5);
		font-size: 14px;
		margin: 0 0 4px;
	}

	.empty-detail p {
		color: rgba(255, 255, 255, 0.35);
		font-size: 11px;
		margin: 0;
	}


	.error-text {
		color: rgba(248, 113, 113, 0.8);
		font-size: 10px;
		margin: 0;
	}

	.muted-text {
		color: rgba(255, 255, 255, 0.35);
		font-size: 11px;
		margin: 0;
	}

	/* Notes */
	.note-input-row {
		display: flex;
		gap: 8px;
		align-items: flex-start;
		margin-bottom: 8px;
	}
	.note-input-row .form-textarea {
		flex: 1;
		background: rgba(255, 255, 255, 0.05);
		border: 1px solid rgba(255, 255, 255, 0.1);
		border-radius: 4px;
		color: rgba(255, 255, 255, 0.87);
		font-size: 11px;
		padding: 6px 8px;
		resize: vertical;
		min-height: 36px;
		font-family: inherit;
	}
	.note-input-row .form-textarea:focus {
		outline: none;
		border-color: rgba(var(--accent-rgb), 0.5);
	}
	.note-input-row .action-btn:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}
	.notes-list {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
	.note-item {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 4px;
		padding: 8px 10px;
	}
	.note-header {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-bottom: 4px;
	}
	.note-author {
		color: rgb(var(--accent-text-rgb));
		font-size: 10px;
		font-weight: 600;
	}
	.note-date {
		color: rgba(255, 255, 255, 0.3);
		font-size: 9px;
		flex: 1;
	}
	.note-content {
		color: rgba(255, 255, 255, 0.75);
		font-size: 11px;
		margin: 0;
		white-space: pre-wrap;
		line-height: 1.4;
	}

	/* ===== CREATE LAYOUT ===== */
	.create-layout {
		display: grid;
		grid-template-columns: 2fr 1fr;
		gap: 0;
	}

	.create-main {
		display: flex;
		flex-direction: column;
		gap: 0;
		border-right: 1px solid rgba(255, 255, 255, 0.04);
	}

	.create-side {
		display: flex;
		flex-direction: column;
		gap: 0;
	}

	.create-btn {
		width: calc(100% - 32px);
		margin: 0 16px;
		padding: 6px;
		font-size: 11px;
	}

	/* ===== CHECKLIST ===== */
	.checklist {
		list-style: none;
		padding: 0;
		margin: 0;
	}

	.checklist li {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 5px 0;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.4);
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
	}

	.checklist li:last-child {
		border-bottom: none;
	}

	.checklist li.complete {
		color: rgba(52, 211, 153, 0.8);
	}

	.checkmark {
		width: 16px;
		height: 16px;
		display: flex;
		align-items: center;
		justify-content: center;
		border-radius: 50%;
		border: 1px solid rgba(255, 255, 255, 0.08);
		background: transparent;
		color: rgba(255, 255, 255, 0.15);
		flex-shrink: 0;
		transition: all 0.15s;
	}

	.checklist li.complete .checkmark {
		background: rgba(16, 185, 129, 0.12);
		border-color: rgba(16, 185, 129, 0.3);
		color: rgba(52, 211, 153, 0.8);
	}

	/* ===== SCROLLBAR ===== */
	.table-body::-webkit-scrollbar,
	.detail-scroll::-webkit-scrollbar {
		width: 4px;
	}

	.table-body::-webkit-scrollbar-track,
	.detail-scroll::-webkit-scrollbar-track {
		background: transparent;
	}

	.table-body::-webkit-scrollbar-thumb,
	.detail-scroll::-webkit-scrollbar-thumb {
		background: rgba(255, 255, 255, 0.06);
		border-radius: 2px;
	}

	/* ===== ANIMATION ===== */
	@keyframes spin {
		0% { transform: rotate(0deg); }
		100% { transform: rotate(360deg); }
	}

	/* ===== RESPONSIVE ===== */
	@media (max-width: 1024px) {
		.create-layout {
			grid-template-columns: 1fr;
		}

		.create-main {
			border-right: none;
			border-bottom: 1px solid rgba(255, 255, 255, 0.04);
		}

		.evidence-form-grid {
			grid-template-columns: 1fr 1fr;
		}
	}

	@media (max-width: 768px) {
		.table-header,
		.table-row {
			grid-template-columns: 2fr 1fr 0.8fr 0.8fr;
		}

		.col-dept,
		.col-officer,
		.col-date {
			display: none;
		}

		.attachment-form {
			grid-template-columns: 1fr;
		}

		.field-row {
			flex-direction: column;
		}

		.search-box {
			min-width: 160px;
		}

		.evidence-form-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ═══════════ Stat filter bar ═══════════ */
	.stat-bar {
		display: flex;
		gap: 8px;
		margin-bottom: 12px;
	}
	.stat {
		flex: 1;
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 2px;
		padding: 10px 14px;
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.05);
		border-left: 2px solid rgba(255, 255, 255, 0.1);
		border-radius: 4px;
		cursor: pointer;
		transition: background 0.12s ease, border-color 0.12s ease;
		text-align: left;
	}
	.stat:hover { background: rgba(255, 255, 255, 0.04); }
	.stat.active { background: rgba(255, 255, 255, 0.05); }
	.stat-num { font-size: 20px; font-weight: 700; color: rgba(255, 255, 255, 0.92); line-height: 1; }
	.stat-label {
		font-size: 9px; font-weight: 600; text-transform: uppercase;
		letter-spacing: 0.7px; color: rgba(255, 255, 255, 0.4);
	}
	/* Each stat carries its status colour on the rail, lit when active. */
	.stat-open { border-left-color: rgba(16, 185, 129, 0.5); }
	.stat-open.active { border-left-color: rgb(16, 185, 129); background: rgba(16, 185, 129, 0.08); }
	.stat-open.active .stat-num { color: rgba(52, 211, 153, 0.95); }
	.stat-progress { border-left-color: rgba(56, 189, 248, 0.5); }
	.stat-progress.active { border-left-color: rgb(56, 189, 248); background: rgba(56, 189, 248, 0.08); }
	.stat-progress.active .stat-num { color: rgba(147, 197, 253, 0.95); }
	.stat-closed { border-left-color: rgba(255, 255, 255, 0.2); }
	.stat-closed.active { border-left-color: rgba(255, 255, 255, 0.5); background: rgba(255, 255, 255, 0.06); }
	.stat.active.stat:first-child { border-left-color: rgba(var(--accent-rgb), 0.9); background: rgba(var(--accent-rgb), 0.08); }

	/* ═══════════ Case list rows ═══════════ */
	.case-rows { display: flex; flex-direction: column; }

	.case-row {
		display: flex;
		align-items: center;
		gap: 14px;
		width: 100%;
		padding: 13px 14px;
		background: transparent;
		border: none;
		border-bottom: 1px solid rgba(255, 255, 255, 0.045);
		cursor: pointer;
		text-align: left;
		transition: background 0.1s ease;
	}
	.case-row:hover { background: rgba(255, 255, 255, 0.03); }
	.case-row:first-child { border-top: 1px solid rgba(255, 255, 255, 0.045); }

	/* Priority as a single coloured dot — quiet until you're looking for it. */
	.cr-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
	.prio-dot-high { background: rgb(239, 68, 68); box-shadow: 0 0 6px rgba(239, 68, 68, 0.5); }
	.prio-dot-medium { background: rgb(251, 146, 60); }
	.prio-dot-low { background: rgba(16, 185, 129, 0.7); }

	.cr-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
	.cr-head { display: flex; align-items: baseline; gap: 9px; }
	.cr-title {
		font-size: 13px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.9);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.cr-number {
		font-family: "SFMono-Regular", ui-monospace, monospace;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.35);
		flex-shrink: 0;
	}
	.cr-summary {
		font-size: 11px;
		color: rgba(255, 255, 255, 0.4);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.cr-officer { display: flex; align-items: center; gap: 7px; width: 150px; flex-shrink: 0; }
	.cr-avatar {
		display: grid; place-items: center;
		width: 22px; height: 22px; flex-shrink: 0;
		border-radius: 50%;
		background: rgba(var(--accent-rgb), 0.13);
		border: 1px solid rgba(var(--accent-rgb), 0.2);
		color: rgba(var(--accent-rgb), 0.95);
		font-size: 8px; font-weight: 700;
	}
	.cr-officer-name {
		font-size: 11px; color: rgba(255, 255, 255, 0.6);
		white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
	}

	.cr-status {
		width: 92px;
		flex-shrink: 0;
		text-align: center;
		padding: 3px 0;
		border-radius: 3px;
		font-size: 9px; font-weight: 700;
		text-transform: uppercase; letter-spacing: 0.4px;
	}

	.cr-time { width: 74px; flex-shrink: 0; display: flex; flex-direction: column; align-items: flex-end; gap: 1px; }
	.cr-time-val { font-size: 11px; color: rgba(255, 255, 255, 0.55); }
	.cr-time-label { font-size: 8px; text-transform: uppercase; letter-spacing: 0.5px; color: rgba(255, 255, 255, 0.28); }

	.cr-chevron { color: rgba(255, 255, 255, 0.2); flex-shrink: 0; transition: color 0.1s ease, transform 0.1s ease; }
	.case-row:hover .cr-chevron { color: rgba(255, 255, 255, 0.5); transform: translateX(2px); }

	/* Status colours, shared by the list rows and the detail header. */
	.status-open { background: rgba(16, 185, 129, 0.12); color: rgba(52, 211, 153, 0.9); }
	.status-in_progress { background: rgba(56, 189, 248, 0.12); color: rgba(147, 197, 253, 0.9); }
	.status-closed { background: rgba(255, 255, 255, 0.05); color: rgba(255, 255, 255, 0.45); }

	/* ═══════════ Case detail hero ═══════════ */
	.case-hero {
		position: relative;
		display: flex;
		align-items: stretch;
		gap: 0;
		margin-bottom: 14px;
		background: linear-gradient(rgba(255,255,255,0.03), rgba(255,255,255,0.012));
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 8px;
		overflow: hidden;
	}
	.hero-rail { width: 4px; flex-shrink: 0; background: rgba(255, 255, 255, 0.15); }
	.case-hero.prio-high .hero-rail { background: rgb(239, 68, 68); }
	.case-hero.prio-medium .hero-rail { background: rgb(251, 146, 60); }
	.case-hero.prio-low .hero-rail { background: rgb(16, 185, 129); }

	.hero-body { flex: 1; min-width: 0; padding: 16px 20px; display: flex; flex-direction: column; gap: 8px; }
	/* Status + priority badges in the hero (shared class names with the old cards). */
	.hero-top .cc-status {
		padding: 2px 8px; border-radius: 3px;
		font-size: 9px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.4px;
	}
	.hero-top .cc-prio {
		padding: 2px 8px; border-radius: 3px;
		font-size: 9px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.4px;
	}
	.prio-badge-high { background: rgba(239, 68, 68, 0.13); color: rgba(248, 113, 113, 0.92); border: 1px solid rgba(239, 68, 68, 0.22); }
	.prio-badge-medium { background: rgba(251, 146, 60, 0.12); color: rgba(251, 146, 60, 0.9); border: 1px solid rgba(251, 146, 60, 0.2); }
	.prio-badge-low { background: rgba(255, 255, 255, 0.04); color: rgba(255, 255, 255, 0.4); border: 1px solid rgba(255, 255, 255, 0.07); }
	.hero-top { display: flex; align-items: center; gap: 9px; }
	.hero-number {
		font-family: "SFMono-Regular", ui-monospace, monospace;
		font-size: 11px; font-weight: 600; letter-spacing: 0.4px;
		color: rgba(255, 255, 255, 0.45);
	}
	.hero-title {
		margin: 0;
		font-size: 22px;
		font-weight: 700;
		line-height: 1.2;
		color: rgba(255, 255, 255, 0.96);
		letter-spacing: -0.2px;
	}
	.hero-meta { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
	.hero-avatar {
		display: grid; place-items: center;
		width: 24px; height: 24px; flex-shrink: 0;
		border-radius: 50%;
		background: rgba(var(--accent-rgb), 0.15);
		border: 1px solid rgba(var(--accent-rgb), 0.25);
		color: rgba(var(--accent-rgb), 0.95);
		font-size: 9px; font-weight: 700;
	}
	.hero-officer { font-size: 12px; font-weight: 500; color: rgba(255, 255, 255, 0.82); }
	.hero-dept { font-size: 12px; color: rgba(255, 255, 255, 0.55); }
	.hero-updated { font-size: 11px; color: rgba(255, 255, 255, 0.4); }
	.hero-dot { color: rgba(255, 255, 255, 0.2); font-size: 10px; }

	/* Metrics strip on the right — the case's weight at a glance. */
	/* ═══════════ Detail tabs — same construction as the roster's boss-tabs ═══════════ */
	.detail-tabs {
		display: flex;
		flex-wrap: wrap;
		gap: 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		padding: 0 4px;
		margin-bottom: 16px;
	}
	.detail-tab {
		display: flex;
		align-items: center;
		gap: 4px;
		padding: 8px 12px;
		background: none;
		border: none;
		border-bottom: 2px solid transparent;
		color: rgba(255, 255, 255, 0.35);
		font-size: 10px;
		font-weight: 600;
		cursor: pointer;
		transition: all 0.15s;
		text-transform: uppercase;
		letter-spacing: 0.3px;
		white-space: nowrap;
	}
	.detail-tab:hover {
		color: rgba(255, 255, 255, 0.6);
	}
	.detail-tab.active {
		color: rgba(var(--accent-text-rgb), 0.85);
		border-bottom-color: rgba(var(--accent-rgb), 0.5);
	}
	.detail-tab-icon {
		font-size: 14px;
	}
	.detail-tab-count {
		display: inline-grid;
		place-items: center;
		min-width: 16px;
		height: 15px;
		padding: 0 4px;
		margin-left: 2px;
		border-radius: 8px;
		background: rgba(255, 255, 255, 0.08);
		color: rgba(255, 255, 255, 0.55);
		font-size: 9px;
		font-weight: 700;
	}
	.detail-tab.active .detail-tab-count {
		background: rgba(var(--accent-rgb), 0.2);
		color: rgba(var(--accent-text-rgb), 0.9);
	}

	.topbar-title--muted { color: rgba(255, 255, 255, 0.5); font-weight: 500; }


	/* ═══════════ Case information (detail) ═══════════ */
	.ghost-btn {
		display: inline-flex; align-items: center; gap: 5px;
		padding: 4px 10px;
		background: transparent;
		border: 1px solid rgba(255, 255, 255, 0.1);
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.55);
		font-size: 10px; font-weight: 600;
		cursor: pointer; transition: all 0.1s;
	}
	.ghost-btn:hover { color: rgba(255, 255, 255, 0.9); border-color: rgba(255, 255, 255, 0.2); }

	.summary-text {
		margin: 0 0 14px;
		font-size: 13px; line-height: 1.6;
		color: rgba(255, 255, 255, 0.75);
	}
	.summary-text.empty { color: rgba(255, 255, 255, 0.3); font-style: italic; }

	.summary-edit {
		width: 100%;
		box-sizing: border-box;
		margin-bottom: 8px;
		padding: 10px 12px;
		background: rgba(0, 0, 0, 0.2);
		border: 1px solid rgba(var(--accent-rgb), 0.3);
		border-radius: 4px;
		color: rgba(255, 255, 255, 0.9);
		font-size: 13px; line-height: 1.6; font-family: inherit;
		resize: vertical; outline: none;
	}
	.summary-actions { display: flex; justify-content: flex-end; gap: 6px; margin-bottom: 14px; }
	.save-btn {
		padding: 4px 14px;
		background: rgba(16, 185, 129, 0.1);
		border: 1px solid rgba(16, 185, 129, 0.25);
		border-radius: 3px;
		color: rgba(52, 211, 153, 0.95);
		font-size: 10px; font-weight: 600; cursor: pointer; transition: all 0.1s;
	}
	.save-btn:hover { background: rgba(16, 185, 129, 0.18); }

	/* Segmented status/priority pickers */
	.control-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-bottom: 14px; }
	.control-block { display: flex; flex-direction: column; gap: 6px; }
	.control-label {
		font-size: 9px; font-weight: 700; text-transform: uppercase;
		letter-spacing: 0.7px; color: rgba(255, 255, 255, 0.4);
	}
	.seg {
		display: flex;
		background: rgba(0, 0, 0, 0.2);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 4px;
		padding: 2px;
		gap: 2px;
	}
	.seg-btn {
		flex: 1;
		padding: 5px 4px;
		background: transparent;
		border: none;
		border-radius: 3px;
		color: rgba(255, 255, 255, 0.45);
		font-size: 10px; font-weight: 600;
		cursor: pointer; transition: all 0.1s;
		white-space: nowrap;
	}
	.seg-btn:hover:not(.active) { color: rgba(255, 255, 255, 0.75); background: rgba(255, 255, 255, 0.03); }
	.seg-status-open.active { background: rgba(16, 185, 129, 0.16); color: rgba(52, 211, 153, 0.95); }
	.seg-status-in_progress.active { background: rgba(56, 189, 248, 0.16); color: rgba(147, 197, 253, 0.95); }
	.seg-status-closed.active { background: rgba(255, 255, 255, 0.1); color: rgba(255, 255, 255, 0.85); }
	.seg-prio-high.active { background: rgba(239, 68, 68, 0.16); color: rgba(248, 113, 113, 0.95); }
	.seg-prio-medium.active { background: rgba(251, 146, 60, 0.16); color: rgba(251, 146, 60, 0.95); }
	.seg-prio-low.active { background: rgba(16, 185, 129, 0.14); color: rgba(52, 211, 153, 0.9); }

	.dept-input { max-width: 280px; }

	/* Provenance + delete, set apart from the routine fields. */
	.info-foot {
		display: flex; align-items: center; gap: 8px;
		margin-top: 16px; padding-top: 12px;
		border-top: 1px solid rgba(255, 255, 255, 0.05);
		font-size: 11px; color: rgba(255, 255, 255, 0.4);
	}
	.info-foot strong { color: rgba(255, 255, 255, 0.65); font-weight: 600; }
	.info-foot-sep { color: rgba(255, 255, 255, 0.2); }
	.danger-link {
		display: inline-flex; align-items: center; gap: 5px;
		padding: 4px 10px;
		background: transparent;
		border: 1px solid rgba(239, 68, 68, 0.15);
		border-radius: 3px;
		color: rgba(248, 113, 113, 0.7);
		font-size: 10px; font-weight: 600; cursor: pointer; transition: all 0.1s;
	}
	.danger-link:hover { background: rgba(239, 68, 68, 0.1); color: rgba(248, 113, 113, 0.95); border-color: rgba(239, 68, 68, 0.3); }


	/* ═══════════ Officers (detail) ═══════════ */
	.officer-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 8px; }
	.officer-card {
		position: relative;
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 9px 11px;
		background: rgba(255, 255, 255, 0.025);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-left: 2px solid rgba(255, 255, 255, 0.12);
		border-radius: 5px;
	}
	/* Role tints the left edge: primary is the accent, the rest stay neutral. */
	.officer-card.role-primary { border-left-color: rgba(var(--accent-rgb), 0.7); }
	.officer-card.role-supervisor { border-left-color: rgba(251, 146, 60, 0.6); }

	.officer-photo {
		width: 38px; height: 38px; flex-shrink: 0;
		border-radius: 50%;
		object-fit: cover;
		background: rgba(0, 0, 0, 0.25);
		border: 1px solid rgba(255, 255, 255, 0.1);
		cursor: pointer;
		transition: border-color 0.1s;
	}
	.officer-photo:hover { border-color: rgba(var(--accent-rgb), 0.5); }
	.officer-photo--fallback {
		display: grid; place-items: center;
		cursor: default;
		color: rgba(var(--accent-rgb), 0.9);
		font-size: 12px; font-weight: 700;
		background: rgba(var(--accent-rgb), 0.12);
		border-color: rgba(var(--accent-rgb), 0.2);
	}
	.officer-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
	.officer-name {
		font-size: 12px; font-weight: 600; color: rgba(255, 255, 255, 0.88);
		white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
	}
	.officer-sub {
		font-size: 10px; color: rgba(255, 255, 255, 0.42);
		white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
	}
	.officer-role {
		padding: 2px 7px; border-radius: 3px;
		font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.4px;
		flex-shrink: 0;
	}
	.role-badge-primary { background: rgba(var(--accent-rgb), 0.15); color: rgba(var(--accent-text-rgb, 147,197,253), 0.95); }
	.role-badge-assisting { background: rgba(255, 255, 255, 0.06); color: rgba(255, 255, 255, 0.5); }
	.role-badge-supervisor { background: rgba(251, 146, 60, 0.14); color: rgba(251, 146, 60, 0.9); }
	.officer-remove {
		display: grid; place-items: center;
		width: 20px; height: 20px; flex-shrink: 0;
		padding: 0; border: none; border-radius: 3px;
		background: transparent; color: rgba(255, 255, 255, 0.25);
		cursor: pointer; transition: all 0.1s;
	}
	.officer-remove:hover { background: rgba(239, 68, 68, 0.12); color: rgba(248, 113, 113, 0.9); }

	/* ═══════════ Thumbnails (attachments + evidence images) ═══════════ */
	.thumb-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 8px; }
	.thumb {
		position: relative;
		display: flex;
		flex-direction: column;
		border-radius: 5px;
		overflow: hidden;
		background: rgba(0, 0, 0, 0.2);
		border: 1px solid rgba(255, 255, 255, 0.06);
	}
	.thumb img {
		width: 100%; height: 90px;
		object-fit: cover;
		cursor: pointer;
		display: block;
		transition: opacity 0.1s;
	}
	.thumb img:hover { opacity: 0.85; }
	/* Non-image URLs (docs, PDFs) get an icon tile that opens in a new tab. */
	.thumb-link {
		display: grid; place-items: center;
		height: 90px;
		color: rgba(var(--accent-rgb), 0.8);
		background: rgba(var(--accent-rgb), 0.05);
		transition: background 0.1s;
	}
	.thumb-link:hover { background: rgba(var(--accent-rgb), 0.1); }
	.thumb-label {
		padding: 5px 8px;
		font-size: 10px;
		color: rgba(255, 255, 255, 0.6);
		white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
		border-top: 1px solid rgba(255, 255, 255, 0.04);
	}
	.thumb-remove {
		position: absolute; top: 4px; right: 4px;
		display: grid; place-items: center;
		width: 18px; height: 18px;
		padding: 0; border: none; border-radius: 3px;
		background: rgba(0, 0, 0, 0.55);
		color: rgba(255, 255, 255, 0.7);
		cursor: pointer; transition: all 0.1s;
	}
	.thumb-remove:hover { background: rgba(239, 68, 68, 0.8); color: #fff; }

	/* ═══════════ Lightbox ═══════════ */
	.lightbox {
		position: fixed; inset: 0;
		z-index: 200;
		display: flex; align-items: center; justify-content: center;
		padding: 40px;
		background: rgba(0, 0, 0, 0.85);
	}
	.lightbox img {
		max-width: 90vw; max-height: 90vh;
		object-fit: contain;
		border-radius: 6px;
		box-shadow: 0 20px 70px rgba(0, 0, 0, 0.7);
	}
	.lightbox-close {
		position: absolute; top: 20px; right: 20px;
		display: grid; place-items: center;
		width: 36px; height: 36px;
		border: 1px solid rgba(255, 255, 255, 0.15);
		border-radius: 5px;
		background: rgba(0, 0, 0, 0.5);
		color: rgba(255, 255, 255, 0.8);
		cursor: pointer; transition: all 0.1s;
	}
	.lightbox-close:hover { background: rgba(0, 0, 0, 0.8); color: #fff; }

</style>