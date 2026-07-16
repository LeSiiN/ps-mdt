<script lang="ts">
	import { onMount } from "svelte";
	import { formatDate } from "../utils/datetime";
	import { fetchNui } from "../utils/fetchNui";
	import { globalNotifications } from "../services/notificationService.svelte";
	import { NUI_EVENTS } from "../constants/nuiEvents";
	import type { AuthService } from "../services/authService.svelte";

	interface CivilianProfile {
		citizenid: string;
		firstName: string;
		lastName: string;
		gender: string;
		dob: string;
		phone: string;
		fingerprint?: string;
		dna?: string;
		image?: string;
		arrests: number;
		activeWarrants?: any[];
		activeBolos?: any[];
		linkedReports?: any[];
		ownedVehicles?: any[];
		weapons?: any[];
		licenses?: { driver: boolean; weapon: boolean };
		customLicenses?: any[];
	}

	interface Charge {
		code: string;
		label: string;
		description: string;
		time: number;
		fine: number;
		type: string;
		category: string;
	}

	let { authService }: { authService: AuthService } = $props();

	let activeTab = $state<"profile" | "legislation">("profile");
	let profile = $state<CivilianProfile | null>(null);
	let charges = $state<Charge[]>([]);
	let loadingProfile = $state(true);
	let loadingCharges = $state(true);
	let searchQuery = $state("");

	let playerName = $derived(profile ? `${profile.firstName} ${profile.lastName}` : "Loading...");

	let filteredCharges = $derived(() => {
		if (!searchQuery.trim()) return charges;
		const q = searchQuery.toLowerCase();
		return charges.filter(c =>
			c.label.toLowerCase().includes(q) ||
			c.description.toLowerCase().includes(q) ||
			c.code.toLowerCase().includes(q)
		);
	});

	let chargesByType = $derived(() => {
		const grouped: Record<string, Charge[]> = { felony: [], misdemeanor: [], infraction: [] };
		for (const c of filteredCharges()) {
			const t = c.type || "infraction";
			if (!grouped[t]) grouped[t] = [];
			grouped[t].push(c);
		}
		return grouped;
	});

	onMount(async () => {
		await Promise.all([loadProfile(), loadCharges(), loadImpounds()]);
	});

	// ── My impounds ───────────────────────────────────────────────────────────
	// Settling the bill used to require finding an officer and asking them to press
	// Collect. It's paperwork, not police work — the owner can do it themselves.
	interface MyImpound {
		id: number;
		plate: string;
		vehicle: string;
		image?: string;
		reason?: string;
		lot?: string;
		time?: string;
		fee: number;
		storage: number;
		total: number;
		fee_paid: boolean;
		notes?: string;
		photo?: string;
		hold?: { active?: boolean; label?: string; until?: string } | null;
	}

	// Click to enlarge. A 34px thumbnail tells you which car it is; it doesn't let you
	// look at the damage.
	let lightbox = $state<{ url: string; label: string } | null>(null);

	let impounds = $state<MyImpound[]>([]);
	let impoundsEnabled = $state(false);
	let loadingImpounds = $state(true);
	let payingPlate = $state<string | null>(null);
	let confirmPlate = $state<string | null>(null);

	let totalOutstanding = $derived(
		impounds.filter((i) => !i.fee_paid).reduce((sum, i) => sum + (i.total ?? 0), 0),
	);

	function money(n: number) {
		return "$" + (n ?? 0).toLocaleString("en-US");
	}

	async function loadImpounds() {
		loadingImpounds = true;
		try {
			const res = await fetchNui<{ success: boolean; enabled?: boolean; impounds?: MyImpound[] }>(
				NUI_EVENTS.CIVILIAN.GET_MY_IMPOUNDS,
				{},
				{ success: true, enabled: true, impounds: [] },
			);
			impoundsEnabled = res?.enabled !== false;
			impounds = res?.impounds ?? [];
		} catch {
			impounds = [];
		} finally {
			loadingImpounds = false;
		}
	}

	async function payImpound(plate: string) {
		if (payingPlate) return;
		payingPlate = plate;
		try {
			const res = await fetchNui<{ success: boolean; message?: string }>(
				NUI_EVENTS.CIVILIAN.PAY_MY_IMPOUND_FEE,
				{ plate },
			);
			if (res?.success) {
				globalNotifications.success(res.message || "Fee paid");
				confirmPlate = null;
				await loadImpounds();
			} else {
				globalNotifications.error(res?.message || "Payment failed");
			}
		} catch {
			globalNotifications.error("Payment failed");
		} finally {
			payingPlate = null;
		}
	}

	async function loadProfile() {
		loadingProfile = true;
		try {
			const result = await fetchNui<{ success: boolean; profile?: CivilianProfile }>(
				NUI_EVENTS.CIVILIAN.GET_MY_PROFILE,
				{},
				{
					success: true,
					profile: {
						citizenid: "ABC123", firstName: "John", lastName: "Doe",
						gender: "Male", dob: "1990-01-01", phone: "555-0100",
						arrests: 0, activeWarrants: [], linkedReports: [],
						ownedVehicles: [], weapons: [],
						licenses: { driver: true, weapon: false }, customLicenses: []
					}
				},
			);
			if (result?.success && result.profile) {
				profile = result.profile;
			}
		} catch { /* silent */ }
		finally { loadingProfile = false; }
	}

	async function loadCharges() {
		loadingCharges = true;
		try {
			const result = await fetchNui<Charge[]>(
				NUI_EVENTS.CHARGE.GET_CHARGES,
				{},
				[],
			);
			charges = result || [];
		} catch { charges = []; }
		finally { loadingCharges = false; }
	}

	function closeTerminal() {
		fetchNui(NUI_EVENTS.NAVIGATION.CLOSE_UI);
	}

	const TYPE_LABELS: Record<string, string> = {
		felony: "Felony",
		misdemeanor: "Misdemeanor",
		infraction: "Infraction",
	};

	const TYPE_COLORS: Record<string, string> = {
		felony: "rgba(239, 68, 68, 0.8)",
		misdemeanor: "rgba(234, 179, 8, 0.8)",
		infraction: "rgba(34, 197, 94, 0.8)",
	};
</script>

<div class="civilian-view">
	<div class="civ-header">
		<div class="civ-header-left">
			<span class="material-icons civ-icon">person</span>
			<span class="civ-title">{playerName}</span>
			<span class="civ-badge">Civilian Access</span>
		</div>
		<div class="civ-tabs">
			<button class="civ-tab" class:active={activeTab === "profile"} onclick={() => activeTab = "profile"}>
				<span class="material-icons tab-icon">badge</span> My Profile
			</button>
			<button class="civ-tab" class:active={activeTab === "legislation"} onclick={() => activeTab = "legislation"}>
				<span class="material-icons tab-icon">gavel</span> Legislation
			</button>
		</div>
		<button class="close-btn" onclick={closeTerminal}>
			<span class="material-icons">close</span>
		</button>
	</div>

	<div class="civ-content">
		{#if activeTab === "profile"}
			{#if loadingProfile}
				<div class="loading-state">
					<div class="spinner"></div>
					<span>Loading profile...</span>
				</div>
			{:else if !profile}
				<div class="empty-state">
					<span class="material-icons">error_outline</span>
					<span>Could not load your profile</span>
				</div>
			{:else}
				<div class="profile-layout">
					<div class="profile-sidebar">
						<!-- This is a case file, and the top of a case file is the photograph.
						     A circle floating in whitespace is an avatar; a portrait plate with
						     the name on it is a record. Same information, and it finally looks
						     like the thing it is. -->
						{#if profile.image}
							{@const avatar = profile.image}
							{@const who = `${profile.firstName} ${profile.lastName}`}
							<button class="id-plate" onclick={() => (lightbox = { url: avatar, label: who })}>
								<img src={avatar} alt="Profile" />
								<span class="id-scrim">
									<span class="id-name">{who}</span>
									<span class="id-cid">{profile.citizenid}</span>
								</span>
								<span class="id-zoom material-icons">zoom_in</span>
							</button>
						{:else}
							<div class="id-plate empty">
								<span class="material-icons id-icon">person</span>
								<span class="id-scrim">
									<span class="id-name">{profile.firstName} {profile.lastName}</span>
									<span class="id-cid">{profile.citizenid}</span>
								</span>
							</div>
						{/if}

						<!-- Four numbers that summarise the file. Arrests was previously one row
						     among six, which made it read as trivia; it isn't, and the other three
						     tell you how much there is to look at below. -->
						<div class="stat-strip">
							<div class="stat" class:flagged={(profile.arrests ?? 0) > 0}>
								<span class="stat-n">{profile.arrests ?? 0}</span>
								<span class="stat-l">Arrests</span>
							</div>
							<div class="stat">
								<span class="stat-n">{profile.ownedVehicles?.length ?? 0}</span>
								<span class="stat-l">Vehicles</span>
							</div>
							<div class="stat">
								<span class="stat-n">{profile.weapons?.length ?? 0}</span>
								<span class="stat-l">Weapons</span>
							</div>
							<div class="stat">
								<span class="stat-n">{profile.linkedReports?.length ?? 0}</span>
								<span class="stat-l">Reports</span>
							</div>
						</div>

						<div class="side-block">
							<h3 class="side-title">Details</h3>
							<div class="data-row">
								<span class="data-label">Gender</span>
								<span class="data-value">{profile.gender}</span>
							</div>
							<div class="data-row">
								<span class="data-label">Date of Birth</span>
								<span class="data-value">{profile.dob}</span>
							</div>
							<div class="data-row">
								<span class="data-label">Phone</span>
								<span class="data-value">{profile.phone}</span>
							</div>
						</div>

						<div class="side-block">
							<h3 class="side-title">Biometrics</h3>
							<!-- Sunk into the panel rather than sitting on it: these are raw
							     identifiers, read a character at a time, not prose. -->
							<div class="bio-inset">
								<div class="bio">
									<span class="bio-label">Fingerprint</span>
									<span class="bio-value" class:missing={!profile.fingerprint}>
										{profile.fingerprint || "Not on file"}
									</span>
								</div>
								<div class="bio">
									<span class="bio-label">DNA</span>
									<span class="bio-value" class:missing={!profile.dna}>
										{profile.dna || "Not on file"}
									</span>
								</div>
							</div>
						</div>

						<div class="side-block">
							<h3 class="side-title">Licenses</h3>
							<!-- Held or not held. A grey row saying "None" is something you have to
							     read; a lit dot is something you can see. -->
							<div class="lic-list">
								<div class="lic" class:held={profile.licenses?.driver}>
									<span class="lic-dot"></span>
									<span class="lic-name">Driver</span>
									<span class="lic-state">{profile.licenses?.driver ? "Held" : "—"}</span>
								</div>
								<div class="lic" class:held={profile.licenses?.weapon}>
									<span class="lic-dot"></span>
									<span class="lic-name">Weapon</span>
									<span class="lic-state">{profile.licenses?.weapon ? "Held" : "—"}</span>
								</div>
								{#if profile.customLicenses && profile.customLicenses.length > 0}
									{#each profile.customLicenses as lic}
										<div class="lic" class:held={lic.active}>
											<span class="lic-dot"></span>
											<span class="lic-name">{lic.name}</span>
											<span class="lic-state">{lic.active ? "Held" : "—"}</span>
										</div>
									{/each}
								{/if}
							</div>
						</div>
					</div>

					<div class="profile-main">
					<div class="main-inner">
						<!-- Impounds lead. If your car is in a lot, that is the single most
						     actionable thing on this screen, and the one thing here you can
						     actually do something about. -->
						{#if impoundsEnabled && !loadingImpounds && impounds.length > 0}
							<div class="section-card impound-card">
								<h3 class="section-header">
									<span class="material-icons">local_parking</span> Impounded Vehicles
									{#if totalOutstanding > 0}
										<span class="imp-owed">{money(totalOutstanding)} outstanding</span>
									{/if}
								</h3>

								<div class="imp-grid">
								{#each impounds as imp (imp.id)}
									<div class="imp-row" class:paid={imp.fee_paid}>
										<div class="imp-head">
											<!-- A car with no photo still gets a tile. Without one the whole
											     header shifted left and no two cards in the grid lined up. -->
											{#if imp.image}
												<button class="row-thumb" onclick={() =>
													(lightbox = { url: imp.image!, label: `${imp.vehicle} · ${imp.plate}` })}>
													<img src={imp.image} alt="" />
												</button>
											{:else}
												<span class="row-thumb empty">
													<span class="material-icons">directions_car</span>
												</span>
											{/if}
											<span class="imp-plate">{imp.plate}</span>
											<span class="imp-model">{imp.vehicle}</span>
											{#if imp.fee_paid}
												<span class="imp-badge ok">
													<span class="material-icons">check_circle</span> Paid
												</span>
											{:else}
												<span class="imp-badge due">{money(imp.total)} due</span>
											{/if}
										</div>

										<div class="imp-meta">
											{#if imp.reason}<span>{imp.reason}</span>{/if}
											{#if imp.lot}<span class="imp-lot">
												<span class="material-icons">place</span>{imp.lot}
											</span>{/if}
										</div>

										<!-- What the officer wrote, in their words. This was recorded at the
										     scene and then shown to nobody — the owner had to find an officer
										     and ask what happened to their own car. -->
										{#if imp.notes}
											<div class="imp-note">
												<span class="material-icons">sticky_note_2</span>
												<span class="imp-note-text">{imp.notes}</span>
											</div>
										{/if}

										<!-- The scene photo is evidence, so it needs to be readable — but a
										     full-bleed banner across a 1000px card cropped it to a letterbox
										     slot and threw most of the picture away. A tile at a sane aspect
										     ratio shows the whole thing; the lightbox is there for detail. -->
										{#if imp.photo}
											<div class="imp-photo-row">
												<button class="imp-photo" onclick={() =>
													(lightbox = { url: imp.photo!, label: `${imp.plate} — impound photo` })}>
													<img src={imp.photo} alt="{imp.plate} at the time of impound" />
													<span class="imp-photo-zoom material-icons">zoom_in</span>
												</button>
												<span class="imp-photo-cap">
													<span class="imp-photo-cap-title">
														<span class="material-icons">photo_camera</span> Photo at impound
													</span>
													<span class="imp-photo-cap-sub">Click to enlarge</span>
												</span>
											</div>
										{/if}

										<!-- The bill, itemised. A number with no explanation reads as a
										     penalty; storage that grows daily is the part people need to
										     see, because it's the part they can stop growing. -->
										{#if !imp.fee_paid}
											<div class="imp-bill">
												<div class="imp-line">
													<span>Impound fee</span><span>{money(imp.fee)}</span>
												</div>
												{#if imp.storage > 0}
													<div class="imp-line">
														<span>Storage</span><span>{money(imp.storage)}</span>
													</div>
												{/if}
												<div class="imp-line total">
													<span>Total</span><span>{money(imp.total)}</span>
												</div>
											</div>
										{/if}

										<!-- Paying is not the same as getting the car back. Saying so here
										     is the difference between a fair fee and a nasty surprise. -->
										{#if imp.hold?.active}
											<div class="imp-hold">
												<span class="material-icons">lock_clock</span>
												<span>
													Held{imp.hold.label ? ` — ${imp.hold.label}` : ""}. Paying the fee
													does not lift the hold.
												</span>
											</div>
										{/if}

										{#if !imp.fee_paid}
											{#if confirmPlate === imp.plate}
												<div class="imp-confirm">
													<span>Pay {money(imp.total)} from your bank account?</span>
													<button class="imp-btn ghost" disabled={payingPlate === imp.plate}
														onclick={() => (confirmPlate = null)}>Cancel</button>
													<button class="imp-btn pay" disabled={payingPlate === imp.plate}
														onclick={() => payImpound(imp.plate)}>
														{payingPlate === imp.plate ? "Paying…" : "Confirm"}
													</button>
												</div>
											{:else}
												<button class="imp-btn pay wide" onclick={() => (confirmPlate = imp.plate)}>
													<span class="material-icons">payments</span>
													Pay {money(imp.total)}
												</button>
											{/if}
										{:else}
											<div class="imp-cleared">
												<span class="material-icons">info</span>
												Fee settled — an officer can now release this vehicle.
											</div>
										{/if}
									</div>
								{/each}
								</div>
							</div>
						{/if}

						{#if profile.activeWarrants && profile.activeWarrants.length > 0}
							<div class="section-card danger">
								<h3 class="section-header"><span class="material-icons">warning</span> Active Warrants</h3>
								{#each profile.activeWarrants as warrant}
									<div class="list-item">
										<span class="item-id">Report #{warrant.reportid}</span>
										<span class="item-name">Expires: {formatDate(warrant.expirydate)}</span>
									</div>
								{/each}
							</div>
						{/if}

						{#if profile.activeBolos && profile.activeBolos.length > 0}
							<div class="section-card danger">
								<h3 class="section-header"><span class="material-icons">notification_important</span> Active BOLOs</h3>
								{#each profile.activeBolos as bolo}
									<div class="list-item">
										<span class="item-id">#{bolo.reportId}</span>
										<span class="item-name">{bolo.notes || 'No details'}</span>
										<span class="item-tag">{bolo.type}</span>
									</div>
								{/each}
							</div>
						{/if}

						{#if profile.linkedReports && profile.linkedReports.length > 0}
							<div class="section-card">
								<h3 class="section-header"><span class="material-icons">description</span> Linked Reports</h3>
								{#each profile.linkedReports as report}
									<div class="list-item">
										<span class="item-id">#{report.id}</span>
										<span class="item-name">{report.title}</span>
										<span class="item-tag">{report.type}</span>
									</div>
								{/each}
							</div>
						{/if}

						{#if profile.ownedVehicles && profile.ownedVehicles.length > 0}
							<div class="section-card">
								<h3 class="section-header"><span class="material-icons">directions_car</span> Vehicles</h3>
								{#each profile.ownedVehicles as vehicle}
									<div class="list-item with-thumb">
										{#if vehicle.image}
											<button class="row-thumb" onclick={() =>
												(lightbox = { url: vehicle.image!, label: vehicle.label || vehicle.plate })}>
												<img src={vehicle.image} alt="" />
											</button>
										{:else}
											<span class="row-thumb empty"><span class="material-icons">directions_car</span></span>
										{/if}
										<span class="item-id">{vehicle.plate}</span>
										<span class="item-name">{vehicle.label || vehicle.vehicle}</span>
									</div>
								{/each}
							</div>
						{/if}

						{#if profile.weapons && profile.weapons.length > 0}
							<div class="section-card">
								<h3 class="section-header"><span class="material-icons">security</span> Registered Weapons</h3>
								{#each profile.weapons as weapon}
									<div class="list-item with-thumb">
										{#if weapon.image}
											<button class="row-thumb contain" onclick={() =>
												(lightbox = { url: weapon.image!, label: weapon.label || weapon.serial })}>
												<img src={weapon.image} alt="" />
											</button>
										{:else}
											<span class="row-thumb empty"><span class="material-icons">security</span></span>
										{/if}
										<span class="item-id">{weapon.serial}</span>
										<span class="item-name">{weapon.label || weapon.weaponModel}</span>
									</div>
								{/each}
							</div>
						{/if}

						{#if !profile.activeWarrants?.length && !profile.activeBolos?.length && !profile.linkedReports?.length && !profile.ownedVehicles?.length && !profile.weapons?.length}
							<div class="empty-state">
								<span class="material-icons">check_circle</span>
								<span>No records on file</span>
							</div>
						{/if}
					</div>
					</div>
				</div>
			{/if}

		{:else if activeTab === "legislation"}
			<div class="legislation-layout">
				<div class="search-bar">
					<span class="material-icons search-icon">search</span>
					<input type="text" placeholder="Search penal codes..." bind:value={searchQuery} />
				</div>

				{#if loadingCharges}
					<div class="loading-state">
						<div class="spinner"></div>
						<span>Loading penal codes...</span>
					</div>
				{:else}
					{#each Object.entries(chargesByType()) as [type, typeCharges]}
						{#if typeCharges.length > 0}
							<div class="charge-group">
								<h3 class="charge-group-title" style="color: {TYPE_COLORS[type] || '#fff'}">
									{TYPE_LABELS[type] || type} ({typeCharges.length})
								</h3>
								<div class="charge-table">
									<div class="charge-header-row">
										<span class="ch-code">Code</span>
										<span class="ch-label">Charge</span>
										<span class="ch-fine">Fine</span>
										<span class="ch-time">Jail</span>
									</div>
									{#each typeCharges as charge}
										<div class="charge-row">
											<span class="ch-code">{charge.code}</span>
											<span class="ch-label">
												<strong>{charge.label}</strong>
												{#if charge.description}
													<span class="ch-desc">{charge.description}</span>
												{/if}
											</span>
											<span class="ch-fine">${charge.fine.toLocaleString()}</span>
											<span class="ch-time">{charge.time} mo</span>
										</div>
									{/each}
								</div>
							</div>
						{/if}
					{/each}
					{#if filteredCharges().length === 0}
						<div class="empty-state">
							<span class="material-icons">search_off</span>
							<span>No charges found</span>
						</div>
					{/if}
				{/if}
			</div>
		{/if}
	</div>
</div>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
{#if lightbox}
	<div class="lightbox" onclick={() => (lightbox = null)}>
		<!-- The card swallows the click, so clicking the photo doesn't dismiss the very
		     thing you opened. Clicking the dark area around it does. -->
		<div class="lightbox-card" onclick={(e) => e.stopPropagation()}>
			<div class="lightbox-bar">
				<span class="lightbox-label">{lightbox.label}</span>
				<button class="lightbox-close" aria-label="Close" onclick={() => (lightbox = null)}>
					<span class="material-icons">close</span>
				</button>
			</div>
			<img src={lightbox.url} alt={lightbox.label} />
		</div>
	</div>
{/if}

<style>
	.civilian-view {
		display: flex;
		flex-direction: column;
		height: 100%;
		background: var(--dark-bg, #111);
	}

	.civ-header {
		display: flex;
		align-items: center;
		padding: 0 20px;
		height: 44px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		flex-shrink: 0;
		gap: 16px;
	}

	.civ-header-left {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.civ-icon { font-size: 18px; color: rgba(255, 255, 255, 0.5); }

	.civ-title {
		font-size: 13px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.8);
	}

	.civ-badge {
		font-size: 9px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.4);
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.08);
		padding: 2px 8px;
		border-radius: 8px;
		text-transform: uppercase;
		letter-spacing: 0.5px;
	}

	.civ-tabs {
		display: flex;
		gap: 4px;
		margin-left: auto;
	}

	.civ-tab {
		display: flex;
		align-items: center;
		gap: 5px;
		padding: 6px 14px;
		background: transparent;
		border: none;
		border-bottom: 2px solid transparent;
		color: rgba(255, 255, 255, 0.4);
		font-size: 12px;
		font-weight: 500;
		cursor: pointer;
		transition: all 0.12s;
	}

	.civ-tab:hover { color: rgba(255, 255, 255, 0.6); }
	.civ-tab.active { color: rgba(255, 255, 255, 0.9); border-bottom-color: var(--accent-60); }
	.tab-icon { font-size: 14px; }

	.close-btn {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 28px;
		height: 28px;
		background: transparent;
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 4px;
		color: rgba(255, 255, 255, 0.3);
		cursor: pointer;
		transition: all 0.12s;
	}

	.close-btn:hover { color: rgba(255, 255, 255, 0.7); background: rgba(255, 255, 255, 0.04); }
	.close-btn .material-icons { font-size: 16px; }

	/* A frame, not a scroller. It used to scroll AND contain a child with height:100%,
	   which resolves against a parent whose height is auto — so the chain broke and the
	   cards collapsed. One owner per axis: this element owns the height, the column
	   inside it owns the scrolling. */
	.civ-content {
		flex: 1;
		min-height: 0;
		overflow: hidden;
	}

	/* Profile Layout */
	.profile-layout {
		display: flex;
		height: 100%;
		min-height: 0;
	}

	.profile-sidebar {
		flex: 0 0 300px;
		min-height: 0;
		border-right: 1px solid rgba(255, 255, 255, 0.06);
		padding: 22px 20px;
		overflow-y: auto;
		background: rgba(0, 0, 0, 0.15);
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
	}













	/* Profile Main */
	/* The scroller is full width — capping IT would narrow the scroll viewport and park
	   the scrollbar in the middle of the screen. The cap belongs on the content inside. */




	/* ── The ID plate ───────────────────────────────────────────────────────── */
	.id-plate {
		position: relative;
		display: block;
		width: 100%;
		aspect-ratio: 4 / 5;
		padding: 0;
		margin-bottom: 14px;
		border-radius: 10px;
		overflow: hidden;
		border: 1px solid rgba(255, 255, 255, 0.08);
		background: rgba(255, 255, 255, 0.03);
		cursor: pointer;
		transition: border-color 0.15s;
	}
	.id-plate:hover:not(.empty) { border-color: rgba(var(--accent-rgb), 0.55); }
	.id-plate.empty { cursor: default; display: grid; place-items: center; }
	.id-plate img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}
	.id-icon { font-size: 56px; color: rgba(255, 255, 255, 0.1); }

	/* A gradient, not a solid bar — the photo keeps going underneath instead of being
	   chopped off by a label. */
	.id-scrim {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		display: flex;
		flex-direction: column;
		gap: 3px;
		padding: 22px 12px 11px;
		text-align: left;
		background: linear-gradient(
			to top,
			rgba(0, 0, 0, 0.92) 0%,
			rgba(0, 0, 0, 0.7) 45%,
			rgba(0, 0, 0, 0) 100%
		);
	}
	.id-name {
		font-size: 15px;
		font-weight: 600;
		line-height: 1.15;
		color: rgba(255, 255, 255, 0.98);
	}
	.id-cid {
		font-family: "Courier New", monospace;
		font-size: 10px;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.5);
	}

	/* Only shows on hover — the photo shouldn't wear a button it doesn't need. */
	.id-zoom {
		position: absolute;
		top: 9px;
		right: 9px;
		display: grid;
		place-items: center;
		width: 26px;
		height: 26px;
		border-radius: 50%;
		background: rgba(0, 0, 0, 0.55);
		border: 1px solid rgba(255, 255, 255, 0.14);
		color: rgba(255, 255, 255, 0.85);
		font-size: 15px;
		opacity: 0;
		transition: opacity 0.15s;
	}
	.id-plate:hover .id-zoom { opacity: 1; }

	/* ── Four numbers that summarise the file ───────────────────────────────── */
	.stat-strip {
		display: grid;
		grid-template-columns: repeat(4, 1fr);
		gap: 5px;
		margin-bottom: 22px;
	}
	.stat {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 1px;
		padding: 9px 2px;
		border-radius: 7px;
		border: 1px solid rgba(255, 255, 255, 0.06);
		background: rgba(255, 255, 255, 0.02);
	}
	/* A clean record and a record with arrests on it must not look identical. */
	.stat.flagged {
		border-color: rgba(239, 68, 68, 0.32);
		background: rgba(239, 68, 68, 0.09);
	}
	.stat-n {
		font-size: 16px;
		font-weight: 700;
		line-height: 1.1;
		color: rgba(255, 255, 255, 0.92);
	}
	.stat.flagged .stat-n { color: rgba(252, 165, 165, 1); }
	.stat-l {
		font-size: 8px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.35);
	}

	/* ── Biometrics ─────────────────────────────────────────────────────────── */
	.bio-inset {
		display: flex;
		flex-direction: column;
		gap: 9px;
		padding: 10px 11px;
		border-radius: 7px;
		background: rgba(0, 0, 0, 0.28);
		border: 1px solid rgba(255, 255, 255, 0.04);
	}
	.bio { display: flex; flex-direction: column; gap: 2px; }
	.bio-label {
		font-size: 9px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.6px;
		color: rgba(255, 255, 255, 0.3);
	}
	.bio-value {
		font-family: "Courier New", monospace;
		font-size: 11px;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.75);
		word-break: break-all;
	}
	.bio-value.missing {
		font-family: inherit;
		font-size: 11px;
		font-style: italic;
		letter-spacing: 0;
		color: rgba(255, 255, 255, 0.25);
	}

	.side-block { margin-bottom: 20px; }
	.side-title {
		margin: 0 0 9px;
		font-size: 9px;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 1px;
		color: rgba(255, 255, 255, 0.3);
	}

	.data-row {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 10px;
		padding: 7px 0;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
	}
	.data-row:last-child { border-bottom: none; }
	.data-label {
		font-size: 11px;
		color: rgba(255, 255, 255, 0.42);
		white-space: nowrap;
	}
	.data-value {
		font-size: 11px;
		color: rgba(255, 255, 255, 0.85);
		text-align: right;
	}

	.lic-list { display: flex; flex-direction: column; gap: 5px; }
	.lic {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 8px 10px;
		border-radius: 6px;
		border: 1px solid rgba(255, 255, 255, 0.05);
		background: rgba(255, 255, 255, 0.015);
	}
	.lic.held {
		border-color: rgba(16, 185, 129, 0.25);
		background: rgba(16, 185, 129, 0.06);
	}
	.lic-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		flex-shrink: 0;
		background: rgba(255, 255, 255, 0.14);
	}
	.lic.held .lic-dot {
		background: rgb(16, 185, 129);
		box-shadow: 0 0 6px rgba(16, 185, 129, 0.7);
	}
	.lic-name {
		flex: 1;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.55);
	}
	.lic.held .lic-name { color: rgba(255, 255, 255, 0.9); }
	.lic-state {
		font-size: 9px;
		font-weight: 700;
		letter-spacing: 0.4px;
		text-transform: uppercase;
		color: rgba(255, 255, 255, 0.25);
	}
	.lic.held .lic-state { color: rgba(52, 211, 153, 0.9); }

	.profile-main {
		flex: 1;
		min-width: 0;
		min-height: 0;
		overflow-y: auto;
		padding: 22px;
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.1) transparent;
	}
	.profile-main::-webkit-scrollbar { width: 8px; }
	.profile-main::-webkit-scrollbar-thumb {
		background: rgba(255, 255, 255, 0.1);
		border-radius: 4px;
	}
	.profile-main::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.2); }

	.main-inner {
		max-width: 1040px;
		margin: 0 auto;
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	/* Impounds are the one thing on this screen the citizen can act on, so the card is
	   allowed a little more presence than the read-only ones around it. */
	.impound-card {
		border-color: rgba(var(--accent-rgb), 0.22);
	}
	.impound-card .section-header { display: flex; align-items: center; gap: 6px; }
	.imp-owed {
		margin-left: auto;
		padding: 2px 8px;
		border-radius: 3px;
		background: rgba(239, 68, 68, 0.15);
		border: 1px solid rgba(239, 68, 68, 0.3);
		color: rgba(252, 165, 165, 1);
		font-size: 10px;
		font-weight: 700;
	}

	/* Three across. One per row left a metre of empty card beside every vehicle, and a
	   citizen with three impounds had to scroll past two screens of whitespace. auto-fit
	   with a floor means it drops to two, then one, rather than crushing the columns. */
	.imp-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(270px, 1fr));
		gap: 10px;
		padding: 10px;
	}

	.imp-row {
		display: flex;
		flex-direction: column;
		/* One gap for the whole column beats a margin-top on every child — those were what
		   the `margin-top: auto` on the button kept colliding with. */
		gap: 9px;
		padding: 11px;
		border-radius: 7px;
		border: 1px solid rgba(255, 255, 255, 0.07);
		background: rgba(255, 255, 255, 0.022);
	}
	.imp-row.paid { opacity: 0.7; }

	.imp-head {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 7px;
	}
	.imp-plate {
		padding: 2px 7px;
		border-radius: 3px;
		background: rgba(255, 255, 255, 0.07);
		font-family: "Courier New", monospace;
		font-size: 12px;
		font-weight: 700;
		letter-spacing: 0.5px;
		color: rgba(255, 255, 255, 0.95);
	}
	.imp-model { font-size: 12px; color: rgba(255, 255, 255, 0.6); text-transform: capitalize; }

	.imp-badge {
		display: inline-flex;
		align-items: center;
		gap: 3px;
		margin-left: auto;
		padding: 2px 8px;
		border-radius: 3px;
		font-size: 10px;
		font-weight: 700;
	}
	.imp-badge .material-icons { font-size: 12px; }
	.imp-badge.due {
		background: rgba(239, 68, 68, 0.12);
		border: 1px solid rgba(239, 68, 68, 0.3);
		color: rgba(252, 165, 165, 1);
	}
	.imp-badge.ok {
		background: rgba(16, 185, 129, 0.12);
		border: 1px solid rgba(16, 185, 129, 0.3);
		color: rgba(52, 211, 153, 1);
	}

	.imp-meta {
		display: flex;
		flex-wrap: wrap;
		gap: 10px;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.4);
	}
	.imp-lot { display: inline-flex; align-items: center; gap: 2px; }
	.imp-lot .material-icons { font-size: 12px; }

	/* The officer's own words, quoted — hence the rule down the side. */
	.imp-note {
		display: flex;
		align-items: flex-start;
		gap: 7px;
		padding: 8px 10px;
		border-radius: 4px;
		border-left: 2px solid rgba(255, 255, 255, 0.14);
		background: rgba(255, 255, 255, 0.025);
	}
	.imp-note .material-icons {
		font-size: 14px;
		flex-shrink: 0;
		color: rgba(255, 255, 255, 0.3);
	}
	.imp-note-text {
		font-size: 11px;
		line-height: 1.45;
		color: rgba(255, 255, 255, 0.7);
		white-space: pre-wrap;
		word-break: break-word;
	}

	.imp-photo-row {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	/* A fixed tile, not a full-width banner. Stretched across the card, `cover` cropped
	   the photo to a 1000×190 slot and discarded most of it — the one thing the photo is
	   for is seeing the state the vehicle was in. */
	.imp-photo {
		position: relative;
		flex-shrink: 0;
		/* Sized for a grid column, not a full-width card. */
		width: 116px;
		aspect-ratio: 3 / 2;
		padding: 0;
		border-radius: 6px;
		overflow: hidden;
		border: 1px solid rgba(255, 255, 255, 0.09);
		background: rgba(0, 0, 0, 0.3);
		cursor: pointer;
		transition: border-color 0.12s;
	}
	.imp-photo:hover { border-color: rgba(var(--accent-rgb), 0.6); }
	.imp-photo img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}
	.imp-photo-zoom {
		position: absolute;
		top: 6px;
		right: 6px;
		display: grid;
		place-items: center;
		width: 22px;
		height: 22px;
		border-radius: 4px;
		background: rgba(0, 0, 0, 0.6);
		border: 1px solid rgba(255, 255, 255, 0.14);
		color: rgba(255, 255, 255, 0.85);
		font-size: 14px;
		opacity: 0;
		transition: opacity 0.12s;
	}
	.imp-photo:hover .imp-photo-zoom { opacity: 1; }

	/* The caption sits BESIDE the photo now, rather than on top of it — a gradient over
	   evidence hides part of the evidence. */
	.imp-photo-cap {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}
	.imp-photo-cap-title {
		display: flex;
		align-items: center;
		gap: 5px;
		font-size: 11px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.7);
	}
	.imp-photo-cap-title .material-icons {
		font-size: 13px;
		color: rgba(255, 255, 255, 0.35);
	}
	.imp-photo-cap-sub {
		font-size: 10px;
		color: rgba(255, 255, 255, 0.32);
	}

	.imp-bill {
		padding: 8px 9px;
		border-radius: 4px;
		background: rgba(0, 0, 0, 0.22);
	}
	.imp-line {
		display: flex;
		justify-content: space-between;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.5);
		padding: 2px 0;
	}
	.imp-line.total {
		margin-top: 4px;
		padding-top: 5px;
		border-top: 1px solid rgba(255, 255, 255, 0.08);
		font-size: 12px;
		font-weight: 700;
		color: rgba(255, 255, 255, 0.95);
	}

	.imp-hold {
		display: flex;
		align-items: flex-start;
		gap: 6px;
		padding: 7px 9px;
		border-radius: 4px;
		border: 1px solid rgba(245, 158, 11, 0.28);
		background: rgba(245, 158, 11, 0.08);
		font-size: 11px;
		line-height: 1.4;
		color: rgba(252, 211, 77, 0.95);
	}
	.imp-hold .material-icons { font-size: 14px; flex-shrink: 0; }

	.imp-cleared {
		display: flex;
		align-items: center;
		gap: 5px;
		font-size: 11px;
		color: rgba(255, 255, 255, 0.4);
	}
	.imp-cleared .material-icons { font-size: 13px; }

	.imp-confirm {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 7px 9px;
		border-radius: 4px;
		border: 1px solid rgba(var(--accent-rgb), 0.3);
		background: rgba(var(--accent-rgb), 0.08);
		font-size: 11px;
		color: rgba(255, 255, 255, 0.8);
	}
	.imp-confirm span { flex: 1; }

	.imp-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 4px;
		padding: 5px 12px;
		border-radius: 4px;
		border: 1px solid transparent;
		font-size: 11px;
		font-weight: 600;
		font-family: inherit;
		cursor: pointer;
		transition: all 0.1s;
	}
	.imp-btn .material-icons { font-size: 14px; }
	/* Cards in a row are as tall as the tallest, so the action is anchored to the bottom
	   and the Pay buttons sit on one line. The `.imp-bill + .imp-btn` rule that used to
	   live here reset this to a fixed 9px — and since the bill ALWAYS precedes the button,
	   `auto` never once applied and the buttons floated at whatever height the content
	   happened to end. */
	.imp-btn.wide { width: 100%; margin-top: auto; padding: 8px; }
	.imp-btn.pay {
		background: rgba(16, 185, 129, 0.15);
		border-color: rgba(16, 185, 129, 0.4);
		color: rgba(52, 211, 153, 1);
	}
	.imp-btn.pay:hover:not(:disabled) {
		background: rgba(16, 185, 129, 0.28);
		border-color: rgba(16, 185, 129, 0.7);
		color: rgba(167, 243, 208, 1);
	}
	.imp-btn.ghost {
		background: none;
		border-color: rgba(255, 255, 255, 0.12);
		color: rgba(255, 255, 255, 0.5);
	}
	.imp-btn.ghost:hover:not(:disabled) { color: rgba(255, 255, 255, 0.9); }
	.imp-btn:disabled { opacity: 0.5; cursor: not-allowed; }

	.section-card {
		background: rgba(255, 255, 255, 0.022);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 10px;
		overflow: hidden;
		transition: border-color 0.15s;
	}
	.section-card:hover { border-color: rgba(255, 255, 255, 0.11); }

	.section-card.danger {
		border-color: rgba(239, 68, 68, 0.2);
		background: rgba(239, 68, 68, 0.03);
	}

	/* The header is a bar, not a line of text floating above a list — it gives the card
	   a lid and stops the first row reading as part of the title. */
	.section-header {
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0;
		padding: 12px 16px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.05);
		background: rgba(255, 255, 255, 0.02);
		font-size: 12px;
		font-weight: 600;
		letter-spacing: 0.2px;
		color: rgba(255, 255, 255, 0.88);
	}
	.section-header .material-icons {
		font-size: 16px;
		color: rgba(255, 255, 255, 0.4);
	}

	.section-header .material-icons { font-size: 16px; color: rgba(255, 255, 255, 0.4); }
	.section-card.danger .section-header .material-icons { color: rgba(239, 68, 68, 0.7); }

	/* Thumbnails share one column, so rows with a photo and rows without still line up. */
	.list-item.with-thumb {
		grid-template-columns: 40px 130px minmax(0, 1fr) auto;
	}

	.row-thumb {
		width: 40px;
		height: 40px;
		/* In the lists this sits in a grid column and can't shrink. In the impound card's
		   header it's a flex child — without this, a long model name squashes it into a
		   sliver and the cards stop lining up again. */
		flex-shrink: 0;
		padding: 0;
		border-radius: 6px;
		overflow: hidden;
		border: 1px solid rgba(255, 255, 255, 0.09);
		background: rgba(255, 255, 255, 0.03);
		cursor: pointer;
		display: grid;
		place-items: center;
		transition: border-color 0.12s, transform 0.12s;
	}
	.row-thumb:hover:not(.empty) {
		border-color: rgba(var(--accent-rgb), 0.7);
		transform: scale(1.06);
	}
	.row-thumb:hover { border-color: rgba(var(--accent-rgb), 0.6); }
	.row-thumb img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}
	/* Weapon icons are transparent PNGs — cropping them to a square looks wrong. */
	.row-thumb.contain img {
		object-fit: contain;
		padding: 3px;
		box-sizing: border-box;
	}
	.row-thumb.empty {
		cursor: default;
		color: rgba(255, 255, 255, 0.18);
	}
	.row-thumb.empty:hover { border-color: rgba(255, 255, 255, 0.08); }
	.row-thumb.empty .material-icons { font-size: 16px; }

	.lightbox {
		position: fixed;
		inset: 0;
		z-index: 1000;
		display: grid;
		place-items: center;
		padding: 40px;
		/* Solid rgba, never backdrop-filter — CEF renders blur as a black block. */
		background: rgba(0, 0, 0, 0.78);
		cursor: zoom-out;
	}

	/* A framed card, not a full-screen takeover. These photos are small to begin with —
	   a 512px mugshot stretched to 78vh isn't "bigger", it's the same picture upscaled
	   into mush, and it swallows the screen for no gain. The card sizes to the image. */
	.lightbox-card {
		display: flex;
		flex-direction: column;
		max-width: min(560px, 90vw);
		max-height: 100%;
		border-radius: 10px;
		overflow: hidden;
		border: 1px solid rgba(255, 255, 255, 0.1);
		background: rgb(20, 21, 23);
		box-shadow: 0 24px 70px rgba(0, 0, 0, 0.65);
		cursor: default;
	}

	.lightbox-bar {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 10px 10px 10px 14px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		background: rgba(255, 255, 255, 0.02);
	}
	.lightbox-label {
		flex: 1;
		min-width: 0;
		font-size: 12px;
		color: rgba(255, 255, 255, 0.8);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.lightbox img {
		display: block;
		/* Never upscale past the file's own resolution — beyond that there is nothing
		   more to see, only bigger pixels. */
		max-width: 100%;
		max-height: calc(100vh - 160px);
		width: auto;
		height: auto;
		object-fit: contain;
		background: rgba(0, 0, 0, 0.35);
	}

	.lightbox-close {
		flex-shrink: 0;
		display: grid;
		place-items: center;
		width: 26px;
		height: 26px;
		border-radius: 5px;
		border: 1px solid rgba(255, 255, 255, 0.1);
		background: rgba(255, 255, 255, 0.04);
		color: rgba(255, 255, 255, 0.6);
		cursor: pointer;
		transition: all 0.1s;
	}
	.lightbox-close .material-icons { font-size: 15px; }
	.lightbox-close:hover {
		background: rgba(255, 255, 255, 0.14);
		color: rgba(255, 255, 255, 0.95);
	}

	/* A grid, not a flex row. With flex, `.item-name { flex: 1 }` stretched the name to
	   fill whatever was left and a serial longer than the min-width shoved everything
	   along — so no two rows started in the same place. Fixed columns fix that: ids in
	   one column, names in another, tags right. */
	.list-item {
		display: grid;
		grid-template-columns: 130px minmax(0, 1fr) auto;
		align-items: center;
		gap: 14px;
		padding: 11px 16px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.035);
		font-size: 12px;
		transition: background 0.1s;
	}
	.list-item:hover { background: rgba(255, 255, 255, 0.02); }

	.list-item:last-child { border-bottom: none; }

	.item-id {
		font-size: 10px;
		color: rgba(255, 255, 255, 0.38);
		font-family: "Courier New", monospace;
		letter-spacing: 0.3px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.item-name {
		color: rgba(255, 255, 255, 0.8);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.item-tag {
		font-size: 9px;
		font-weight: 600;
		letter-spacing: 0.3px;
		color: rgba(255, 255, 255, 0.45);
		background: rgba(255, 255, 255, 0.05);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 4px;
		padding: 3px 8px;
		white-space: nowrap;
	}

	/* Legislation */
	/* .civ-content is now a frame (overflow: hidden) so the profile column can own its
	   own scrolling. This tab used to lean on the parent for that, so it needs its own
	   scroller now — otherwise the penal code list simply runs off the bottom. */
	.legislation-layout {
		height: 100%;
		min-height: 0;
		overflow-y: auto;
		padding: 22px;
		scrollbar-width: thin;
		scrollbar-color: rgba(255, 255, 255, 0.1) transparent;
	}
	.legislation-layout::-webkit-scrollbar { width: 8px; }
	.legislation-layout::-webkit-scrollbar-thumb {
		background: rgba(255, 255, 255, 0.1);
		border-radius: 4px;
	}
	.legislation-layout::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.2); }

	.search-bar {
		position: relative;
		margin-bottom: 16px;
	}

	.search-icon {
		position: absolute;
		left: 12px;
		top: 50%;
		transform: translateY(-50%);
		font-size: 16px;
		color: rgba(255, 255, 255, 0.3);
	}

	.search-bar input {
		width: 100%;
		padding: 10px 12px 10px 38px;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 6px;
		color: rgba(255, 255, 255, 0.9);
		font-size: 13px;
		outline: none;
	}

	.search-bar input:focus { border-color: var(--accent-35); }
	.search-bar input::placeholder { color: rgba(255, 255, 255, 0.3); }

	.charge-group {
		margin-bottom: 20px;
	}

	.charge-group-title {
		font-size: 13px;
		font-weight: 600;
		margin: 0 0 8px;
		padding-bottom: 6px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
	}

	.charge-table {
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 8px;
		overflow: hidden;
	}

	.charge-header-row {
		display: flex;
		padding: 8px 14px;
		background: rgba(255, 255, 255, 0.03);
		border-bottom: 1px solid rgba(255, 255, 255, 0.06);
		font-size: 10px;
		font-weight: 600;
		color: rgba(255, 255, 255, 0.4);
		text-transform: uppercase;
		letter-spacing: 0.5px;
	}

	.charge-row {
		display: flex;
		padding: 8px 14px;
		border-bottom: 1px solid rgba(255, 255, 255, 0.03);
		font-size: 12px;
		align-items: flex-start;
	}

	.charge-row:last-child { border-bottom: none; }
	.charge-row:hover { background: rgba(255, 255, 255, 0.02); }

	.ch-code { width: 70px; min-width: 70px; color: rgba(255, 255, 255, 0.35); font-family: monospace; font-size: 10px; }
	.ch-label { flex: 1; color: rgba(255, 255, 255, 0.8); }
	.ch-label strong { font-weight: 500; }
	.ch-desc { display: block; font-size: 10px; color: rgba(255, 255, 255, 0.35); margin-top: 2px; }
	.ch-fine { width: 80px; min-width: 80px; text-align: right; color: rgba(234, 179, 8, 0.7); font-size: 11px; }
	.ch-time { width: 60px; min-width: 60px; text-align: right; color: rgba(239, 68, 68, 0.6); font-size: 11px; }

	/* States */
	.loading-state, .empty-state {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 48px;
		color: rgba(255, 255, 255, 0.35);
		font-size: 12px;
	}

	.empty-state .material-icons { font-size: 32px; color: rgba(255, 255, 255, 0.15); }

	.spinner {
		width: 24px;
		height: 24px;
		border: 2px solid rgba(255, 255, 255, 0.06);
		border-left-color: var(--accent-60);
		border-radius: 50%;
		animation: spin 0.8s linear infinite;
	}

	@keyframes spin {
		0% { transform: rotate(0deg); }
		100% { transform: rotate(360deg); }
	}
</style>