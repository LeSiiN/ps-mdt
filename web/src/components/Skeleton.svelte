<script lang="ts">
	/**
	 * A single shimmer bar. Everything is a variant of this — a row is a strip of them,
	 * a card is a stack. Kept deliberately small so a page can compose its own skeleton
	 * in the exact shape of what it's loading, rather than showing a generic spinner and
	 * then reflowing when the real content arrives.
	 */
	interface Props {
		width?: string;
		height?: string;
		radius?: string;
		/** A circle for avatars/thumbnails. */
		circle?: boolean;
		class?: string;
	}

	let {
		width = "100%",
		height = "12px",
		radius,
		circle = false,
		class: extra = "",
	}: Props = $props();

	let resolvedRadius = $derived(circle ? "50%" : (radius ?? "4px"));
	let resolvedWidth = $derived(circle ? height : width);
</script>

<span
	class="mdt-skeleton {extra}"
	style="width: {resolvedWidth}; height: {height}; border-radius: {resolvedRadius}; display: inline-block;"
></span>
