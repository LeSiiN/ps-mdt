import { writable } from "svelte/store";

const pendingReportId = writable<string | null>(null);

export function openReportInEditor(reportId: string | number | null): void {
	// Report ids are numeric in the database and strings in the store, and
	// both forms reach this function from different screens.
	pendingReportId.set(reportId != null ? String(reportId) : "new");
}

export function clearPendingReport(): void {
	pendingReportId.set(null);
}

export { pendingReportId };
