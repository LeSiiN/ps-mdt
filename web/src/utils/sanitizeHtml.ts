// Allowlist HTML sanitizer for user-authored content (bulletin posts, etc.).
//
// The bulletin board renders post content with {@html}, which will execute whatever
// markup it's given — including <script>, <meta http-equiv="refresh">, event-handler
// attributes and javascript: URLs. This strips everything that isn't on a small allowlist
// of formatting tags, so a post can style text but cannot run code, redirect the page or
// pull in external resources.
//
// It's an allowlist, not a blocklist: anything not explicitly permitted is removed. That's
// the only approach that stays safe as new attack vectors appear, since it doesn't rely on
// enumerating them.

// Formatting tags a post is allowed to use. Everything advertised in the editor hint plus
// the common inline/structural tags — deliberately no <a>, since a link's href is an
// injection surface of its own and bulletin posts don't need one.
const ALLOWED_TAGS = new Set([
	"B", "STRONG", "I", "EM", "U", "S", "STRIKE", "SMALL", "MARK", "SUB", "SUP",
	"P", "BR", "HR", "SPAN", "DIV",
	"UL", "OL", "LI",
	"BLOCKQUOTE", "PRE", "CODE",
	"H1", "H2", "H3", "H4", "H5", "H6",
	"TABLE", "THEAD", "TBODY", "TR", "TH", "TD",
]);

// Attributes safe to keep. Nothing that can carry script (no on* handlers), nothing that
// can load a resource (no src/href/background), and no style — inline style can smuggle
// url() fetches and CEF-crashing values.
const ALLOWED_ATTRS = new Set(["colspan", "rowspan", "align"]);

/**
 * Sanitize an untrusted HTML string down to a safe formatting subset.
 * @param dirty raw user-authored HTML
 * @returns HTML containing only allowlisted tags and attributes
 */
export function sanitizeHtml(dirty: string): string {
	if (!dirty) return "";

	// Parse in an inert document: nodes created here are not connected to the page, so
	// <script> doesn't run and <img onerror> doesn't fire during parsing.
	const doc = new DOMParser().parseFromString(dirty, "text/html");

	const walk = (node: Node) => {
		// Iterate over a static copy — we mutate children as we go.
		for (const child of Array.from(node.childNodes)) {
			if (child.nodeType === Node.ELEMENT_NODE) {
				const el = child as Element;
				const tag = el.tagName.toUpperCase();

				if (!ALLOWED_TAGS.has(tag)) {
					// Disallowed element. Keep its text children (so removing a <div> wrapper
					// doesn't wipe the text inside it) but drop the element itself. For tags
					// whose very content is dangerous — script/style — drop it entirely.
					if (tag === "SCRIPT" || tag === "STYLE" || tag === "TEMPLATE" || tag === "IFRAME" || tag === "OBJECT" || tag === "EMBED") {
						el.remove();
					} else {
						// Sanitize the subtree first, then unwrap.
						walk(el);
						while (el.firstChild) node.insertBefore(el.firstChild, el);
						el.remove();
					}
					continue;
				}

				// Allowed element: strip every attribute that isn't explicitly permitted.
				// This removes on* handlers, style, src, href, http-equiv, id/class, etc. in
				// one pass without having to name each dangerous one.
				for (const attr of Array.from(el.attributes)) {
					if (!ALLOWED_ATTRS.has(attr.name.toLowerCase())) {
						el.removeAttribute(attr.name);
					}
				}

				// Recurse into the cleaned element.
				walk(el);
			} else if (
				child.nodeType !== Node.TEXT_NODE &&
				child.nodeType !== Node.CDATA_SECTION_NODE
			) {
				// Comments and anything else that isn't plain text have no business here —
				// conditional comments have historically been an injection vector.
				child.parentNode?.removeChild(child);
			}
		}
	};

	walk(doc.body);
	return doc.body.innerHTML;
}
