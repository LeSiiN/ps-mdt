import { NUI_EVENTS } from "../constants/nuiEvents";
import { createSearch } from "../utils/searchNui";
import type { SearchResult } from "../interfaces/IReportEditor";

export interface SearchServiceState {
	results: SearchResult[];
	isSearching: boolean;
	lastQuery: string;
	lastError: string | null;
}

export function createSearchService() {
	let state = $state<SearchServiceState>({
		results: [],
		isSearching: false,
		lastQuery: "",
		lastError: null,
	});

	// Race-safe runners: only the most recent query per kind delivers results,
	// and they carry the longer search timeout + [] fallback (so a slow/timed-out
	// response never blanks the list or overwrites a newer query).
	const runOfficerSearch = createSearch<SearchResult[]>(
		NUI_EVENTS.REPORT.SEARCH_OFFICERS,
		[],
	);
	const runPlayerSearch = createSearch<SearchResult[]>(
		NUI_EVENTS.REPORT.SEARCH_PLAYERS,
		[],
	);

	/**
	 * Search for officers by query
	 */
	async function searchOfficers(query: string): Promise<SearchResult[]> {
		if (!query.trim()) {
			state.results = [];
			return [];
		}

		state.isSearching = true;
		state.lastQuery = query;
		state.lastError = null;

		try {
			const { results, stale } = await runOfficerSearch({ query });
			// A newer query is already in flight — keep current results and let
			// the newer call own the spinner.
			if (stale) return state.results;

			const safe = Array.isArray(results) ? results : [];
			state.results = safe;
			state.isSearching = false;
			return safe;
		} catch (error) {
			console.error("Failed to search officers:", error);
			state.lastError = "Failed to search officers";
			state.results = [];
			state.isSearching = false;
			return [];
		}
	}

	/**
	 * Search for players by query
	 */
	async function searchPlayers(query: string): Promise<SearchResult[]> {
		if (!query.trim()) {
			state.results = [];
			return [];
		}

		state.isSearching = true;
		state.lastQuery = query;
		state.lastError = null;

		try {
			const { results, stale } = await runPlayerSearch({ query });
			if (stale) return state.results;

			const safe = Array.isArray(results) ? results : [];
			state.results = safe;
			state.isSearching = false;
			return safe;
		} catch (error) {
			console.error("Failed to search players:", error);
			state.lastError = "Failed to search players";
			state.results = [];
			state.isSearching = false;
			return [];
		}
	}

	/**
	 * Clear search results
	 */
	function clearResults(): void {
		state.results = [];
		state.lastQuery = "";
		state.lastError = null;
	}

	/**
	 * Get cached results for the last query
	 */
	function getResults(): SearchResult[] {
		return state.results;
	}

	return {
		get state() {
			return state;
		},
		searchOfficers,
		searchPlayers,
		clearResults,
		getResults,
	};
}

export type SearchService = ReturnType<typeof createSearchService>;