import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

/**
 * Accessibility warnings are off for this project.
 *
 * The MDT is a NUI overlay rendered by CEF inside GTA V. There is no screen
 * reader, no tab-navigation and no assistive technology in that environment,
 * so an aria-label on an icon button or a keydown handler next to a click
 * handler has no consumer — every one of them would be markup written for a
 * reader that cannot exist here.
 *
 * The practical cost of leaving them on was worse than cosmetic: ~170 a11y
 * notices buried the warnings that DO matter. A dead CSS rule, a non-reactive
 * $state write and a missing standard `line-clamp` were all sitting in that
 * pile unnoticed.
 *
 * Everything else still warns. To bring accessibility checks back, delete
 * both hooks below.
 */
const isA11y = (warning) =>
	typeof warning?.code === "string" && warning.code.startsWith("a11y");

export default {
	// Consult https://svelte.dev/docs#compile-time-svelte-preprocess
	// for more information about preprocessors
	preprocess: vitePreprocess(),

	// Read by svelte-check — this is the Svelte compiler's own filter API.
	compilerOptions: {
		warningFilter: (warning) => !isA11y(warning),
	},

	// Read by vite-plugin-svelte during `npm run build` and dev. It runs its
	// own warning pipeline and, depending on the plugin version, does NOT
	// consult compilerOptions.warningFilter — which is why svelte-check can
	// already be silent while the build output is still noisy. Both hooks are
	// set so neither path depends on the version installed.
	onwarn(warning, handler) {
		if (isA11y(warning)) return;
		handler(warning);
	},
};
