import { fetchNui } from "./fetchNui";
import type { NuiEventName } from "@/constants/nuiEvents";

// Server searches can touch large tables, so give them more headroom than the
// default 10s fetchNui timeout (which otherwise blanks results mid-type).
const SEARCH_TIMEOUT = 20000;

/**
 * Build a search runner for a single NUI event.
 *
 * Each runner keeps an internal sequence counter and returns `{ results, stale }`.
 * `stale` is true when a newer query was started before this one resolved — the
 * caller should simply ignore stale results, which prevents a slow earlier
 * response from overwriting the results of a more recent query (the classic
 * type-fast race).
 *
 * Usage:
 *   const runSearch = createSearch<ReportVehicle[]>(NUI_EVENTS.REPORT.SEARCH_VEHICLES_FOR_REPORT, []);
 *   const { results, stale } = await runSearch({ query });
 *   if (stale) return;
 */
export function createSearch<T>(event: NuiEventName, fallback: T) {
	let seq = 0;
	return async (data?: any): Promise<{ results: T; stale: boolean }> => {
		const mySeq = ++seq;
		const results = await fetchNui<T>(event, data, fallback, SEARCH_TIMEOUT);
		return { results, stale: mySeq !== seq };
	};
}
