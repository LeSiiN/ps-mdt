/**
 * Centralised date/time formatting for the entire MDT.
 *
 * Every user-facing date or time in the UI should go through here so the whole
 * app honours a single `Config.DateTime` setting:
 *
 *   Config.DateTime = {
 *       TimeFormat = '24' | '12',
 *       DateFormat = 'MM-DD-YYYY' | 'DD-MM-YYYY' | 'YYYY-MM-DD',
 *   }
 *
 * The config is pushed from Lua on MDT open (see VisibilityProvider) and stored
 * via `setDateTimeConfig`. Until it arrives, sensible defaults are used.
 */

export type TimeFormat = "24" | "12";
export type DateFormat = "MM-DD-YYYY" | "DD-MM-YYYY" | "YYYY-MM-DD";

export interface DateTimeConfig {
	timeFormat: TimeFormat;
	dateFormat: DateFormat;
}

// Module-level current config. Plain object (not a store) so the pure helpers
// below can be called from anywhere — including non-Svelte code. A version
// counter lets reactive callers re-run when the config changes.
let current: DateTimeConfig = { timeFormat: "24", dateFormat: "DD-MM-YYYY" };

/** Bumped whenever the config changes, so Svelte `$derived`/`$effect` can react. */
let _version = 0;
export function dateTimeVersion(): number {
	return _version;
}

/** Set once on MDT open (and whenever the config changes). Tolerates partial input. */
export function setDateTimeConfig(cfg: Partial<{ TimeFormat: string; DateFormat: string; timeFormat: string; dateFormat: string }> | null | undefined): void {
	if (!cfg) return;
	const tf = String(cfg.TimeFormat ?? cfg.timeFormat ?? current.timeFormat);
	const df = String(cfg.DateFormat ?? cfg.dateFormat ?? current.dateFormat).toUpperCase();
	current = {
		timeFormat: tf === "12" ? "12" : "24",
		dateFormat: (df === "MM-DD-YYYY" || df === "YYYY-MM-DD") ? (df as DateFormat) : "DD-MM-YYYY",
	};
	_version++;
}

export function getDateTimeConfig(): DateTimeConfig {
	return current;
}

/**
 * Normalise the many timestamp shapes used across the MDT into a Date:
 *  - Date objects (passed straight through)
 *  - numbers: epoch seconds (< 1e12) or milliseconds
 *  - numeric strings: same second/millisecond heuristic
 *  - ISO / "YYYY-MM-DD HH:MM:SS" strings (the space form is made ISO-safe)
 * Returns null for anything unparseable so callers can render a fallback.
 */
export function toDate(value: unknown): Date | null {
	if (value == null || value === "") return null;
	if (value instanceof Date) return isNaN(value.getTime()) ? null : value;

	if (typeof value === "number") {
		const ms = value < 1e12 ? value * 1000 : value;
		const d = new Date(ms);
		return isNaN(d.getTime()) ? null : d;
	}

	if (typeof value === "string") {
		const s = value.trim();
		// Pure numeric string → epoch seconds/millis.
		if (/^\d+$/.test(s)) {
			const n = Number(s);
			const ms = n < 1e12 ? n * 1000 : n;
			const d = new Date(ms);
			return isNaN(d.getTime()) ? null : d;
		}
		// Legacy "MM/DD/YYYY" rows (older FTO records were stored US-style).
		// Parsed explicitly because `new Date("07/10/2026")` is engine-dependent.
		const usMatch = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s);
		if (usMatch) {
			const [, mm, dd, yyyy] = usMatch;
			const d = new Date(Number(yyyy), Number(mm) - 1, Number(dd));
			return isNaN(d.getTime()) ? null : d;
		}
		// "YYYY-MM-DD HH:MM:SS" → make it ISO-parseable across engines.
		const iso = s.includes(" ") && !s.includes("T") ? s.replace(" ", "T") : s;
		const d = new Date(iso);
		return isNaN(d.getTime()) ? null : d;
	}

	return null;
}

const pad = (n: number) => String(n).padStart(2, "0");

/** Format just the date part according to Config.DateTime.DateFormat. */
export function formatDate(value: unknown, fallback = ""): string {
	const d = toDate(value);
	if (!d) return fallback;
	const dd = pad(d.getDate());
	const mm = pad(d.getMonth() + 1);
	const yyyy = d.getFullYear();
	switch (current.dateFormat) {
		case "MM-DD-YYYY": return `${mm}.${dd}.${yyyy}`;
		case "YYYY-MM-DD": return `${yyyy}.${mm}.${dd}`;
		case "DD-MM-YYYY":
		default:           return `${dd}.${mm}.${yyyy}`;
	}
}

/** Format just the time part according to Config.DateTime.TimeFormat. */
export function formatTime(value: unknown, fallback = ""): string {
	const d = toDate(value);
	if (!d) return fallback;
	const mins = pad(d.getMinutes());
	if (current.timeFormat === "12") {
		const h = d.getHours();
		const suffix = h < 12 ? "AM" : "PM";
		const h12 = h % 12 === 0 ? 12 : h % 12;
		return `${h12}:${mins} ${suffix}`;
	}
	return `${pad(d.getHours())}:${mins}`;
}

/** Format date + time together, e.g. "10-07-2026 15:34" or "10-07-2026 3:34 PM". */
export function formatDateTime(value: unknown, fallback = ""): string {
	const d = toDate(value);
	if (!d) return fallback;
	return `${formatDate(d)} ${formatTime(d)}`;
}

/** Relative "time ago" for recent activity, with the same wording used before. */
export function formatRelative(value: unknown, fallback = "Unknown"): string {
	const d = toDate(value);
	if (!d) return fallback;
	const diff = Date.now() - d.getTime();
	const mins = Math.floor(diff / 60000);
	if (mins < 1) return "Just now";
	if (mins < 60) return `${mins}m ago`;
	const hours = Math.floor(mins / 60);
	if (hours < 24) return `${hours}h ago`;
	const days = Math.floor(hours / 24);
	if (days < 7) return `${days}d ago`;
	return formatDateTime(d);
}