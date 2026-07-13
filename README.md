# ps-mdt v3

Police MDT (Mobile Data Terminal) for FiveM. Built with Svelte 5 and Lua. Works on QBCore and QBX through the ps_lib abstraction layer.

## What is this

A full in-game law enforcement computer. Officers press F11 or type `/mdt` to open it. From there they can look up citizens, write reports, manage cases, track evidence, issue warrants, run BOLOs, look up vehicles and weapons, view security cameras and bodycam feeds, handle dispatch, and manage their department. Everything is permission-based so you control exactly what each rank has access to.

## Dependencies

These need to be running on your server:

| Resource | Why |
|----------|-----|
| [ps_lib](https://github.com/Project-Sloth/ps_lib) | Framework abstraction layer |
| [oxmysql](https://github.com/overextended/oxmysql) | Database |
| [ox_lib](https://github.com/overextended/ox_lib) | Utility library |
| [screenshot-basic](https://github.com/citizenfx/screenshot-basic) | Mugshot capture |


Optional but HIGHLY RECOMMENDED:

| Resource | Why |
|----------|-----|
| [ps-dispatch](https://github.com/Project-Sloth/ps-dispatch) | Dispatch integration |
| [ps-multijob](https://github.com/Project-Sloth/ps-multijob) | Officers Bodycam |

## Installation
No backwards compatibility with ps-mdtv1.

### 1. Add DOJ jobs to QBCore

First, remove the default `judge` and `lawyer` entries from `qb-core/shared/jobs.lua`:

```lua
-- REMOVE THESE
judge = { label = 'Honorary', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Judge', payment = 100 } } },
lawyer = { label = 'Law Firm', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Associate', payment = 50 } } },
```

Then add the DOJ versions in their place:

```lua
judge = {
    label = 'Department of Justice',
    type = 'doj',
    defaultDuty = true,
    offDutyPay = false,
    grades = {
        ['0'] = { name = 'Clerk', payment = 75 },
        ['1'] = { name = 'Magistrate', payment = 100 },
        ['2'] = { name = 'Judge', isboss = true, payment = 150 },
    },
},
lawyer = {
    label = 'Law Firm',
    type = 'doj',
    defaultDuty = true,
    offDutyPay = false,
    grades = {
        ['0'] = { name = 'Paralegal', payment = 50 },
        ['1'] = { name = 'Associate', payment = 75 },
        ['2'] = { name = 'Partner', isboss = true, payment = 125 },
    },
},
```

### 2. Import the database

Run `sql/qbcore.sql` against your FiveM database. This creates all the tables the MDT needs. Use phpMyAdmin, HeidiSQL, or whatever database tool you prefer.

### 3. Set your FiveManage API keys

Image uploads (mugshots, evidence photos, suspect photos) and activity log forwarding go through [FiveManage](https://www.fivemanage.com/). You need API keys from their site.

Add these lines to your `server.cfg`:

```
set ps_mdt_fivemanage_key_images "YOUR_IMAGES_API_KEY_HERE"
set ps_mdt_fivemanage_key_logs   "YOUR_LOGS_API_KEY_HERE"
```

| Convar | What it does |
|--------|-------------|
| `ps_mdt_fivemanage_key_images` | Used for uploading mugshots, evidence photos, and suspect photos |
| `ps_mdt_fivemanage_key_logs` | Used for forwarding audit trail activity to FiveManage Logs |

Both are optional. Without the images key you won't be able to upload any images. Without the logs key the audit trail still works locally in the database, it just won't forward to FiveManage.

### 4. Build the frontend

If you grabbed a release with `web/dist` already in it, skip this step.

Otherwise:

```
cd resources/[qb]/ps-mdt/web
npm install
npm run build
```

### 5. Add to server.cfg

```
ensure ps_lib
ensure oxmysql
ensure ox_lib
ensure ps-mdt
```

ps-mdt has to start after its dependencies.

## Configuration

All config lives in `config.lua`.

### Jobs

Which jobs can access the MDT:

```lua
Config.PoliceJobType = "leo"
Config.PoliceJobs = { 'lspd', 'bcso', 'sahp', 'fib', 'gov' }

Config.DojJobType = "doj"
Config.DojJobs = { 'lawyer', 'judge' }

Config.MedicalJobType = "ems"
Config.MedicalJobs = { 'ambulance' }
```

DOJ access works two ways. Either the job name is in `Config.DojJobs`, or the job has `type = 'doj'` matching `Config.DojJobType`. You can use one or both.

### Keybind and command

```lua
Config.OnlyShowOnDuty = true   -- false = can open off duty

Config.Keys = {
    OpenMDT = {
        enabled = true,
        key = 'F11',
    },
}

Config.Commands = {
    Open = { enabled = true, command = 'mdt' },
    MessageOfTheDay = { enabled = true, command = 'motd' },
}
```

Commands the resource registers:

| Command | What it does |
|---------|-------------|
| `/mdt` | Opens the MDT |
| `/motd` | Message of the day |
| `/mdtimpound` | Impounds the vehicle you're in or standing next to (name set by `Config.Impound.OnSite.Command`) |
| `/complaint` | Opens the standalone IA complaint form. Works for civilians, no MDT needed |
| `/cameraplacer` | Places security cameras around the map |

### Date and time format

How every date and time in the MDT is rendered:

```lua
Config.DateTime = {
    TimeFormat = '24',           -- '24' or '12'
    DateFormat = 'DD-MM-YYYY',   -- 'MM-DD-YYYY', 'DD-MM-YYYY', or 'YYYY-MM-DD'
}
```

This applies everywhere: reports, warrants, the court calendar, audit logs, and the timestamp burned into camera, bodycam, and dashcam footage.

### Data sharing between departments

```lua
Config.Sharing = {
    -- All these departments see each other's data
    Mutual = {
        types = { 'reports', 'bodycams', 'evidence', 'bolos', 'warrants' },
        departments = { 'lspd', 'bcso', 'sahp' }
    },

    -- FIB/GOV can see patrol data but patrol can't see theirs
    OneWay = {
        {
            viewers = { 'fib', 'gov' },
            targets = { 'lspd', 'bcso', 'sahp' },
            types = { 'reports', 'bodycams', 'evidence', 'bolos', 'warrants' }
        },
    },
}
```

### Impound

Lots, reasons, fees, and the on-site impound flow all live under `Config.Impound`:

```lua
Config.Impound = {
    Lots = {
        { id = 'lspd',   label = 'LSPD Impound' },
        { id = 'paleto', label = 'Paleto Impound' },
    },

    -- Each reason carries a default fee. The officer can still edit it.
    Reasons = {
        { label = 'Evidence / Investigation', fee = 0 },
        { label = 'DUI',                      fee = 1500 },
        { label = 'Illegal Modifications',    fee = 1000 },
        -- ...
    },

    DefaultFee     = 500,
    MaxFee         = 50000,
    FeeAccount     = 'bank',   -- 'bank' or 'cash'
    RequireFeePaid = true,     -- fee must be collected before release

    -- Storage grows for every day the vehicle sits in the lot, then stops.
    Storage = {
        PerDay  = 500,
        MaxDays = 7,
    },

    OnSite = {
        Command     = 'mdtimpound',
        MaxDistance = 6.0,

        -- The officer writes the vehicle up, then radios it in. Both steps are
        -- cancellable: walk away and nothing is written.
        Sequence = { NotepadMs = 4500, RadioMs = 6000 },
        FadeMs   = 1500,

        -- Payout for clearing an unowned vehicle off the street.
        Cleanup = {
            RewardMin = 100, RewardMax = 200, Account = 'cash',
            Cooldown  = 120, MaxPerShift = 20,
        },
    },
}
```

Storage fees are worked out from the impound date rather than counted up by a timer, so they survive restarts and can't drift.

### Other stuff worth changing

| Setting | Default | What it does |
|---------|---------|-------------|
| `Config.Fines.MaxAmount` | 100000 | Cap on fine amounts |
| `Config.Fines.CooldownMs` | 30000 | Cooldown between fines (ms) |
| `Config.Warrants.DefaultExpiryDays` | 7 | Days until a warrant expires |
| `Config.RegisterWeaponsAutomatically` | true | Auto-register weapons on purchase |
| `Config.RegisterCreatedWeapons` | false | Auto-register crafted weapons |
| `Config.UseWolfknightRadar` | true | Wolfknight plate reader integration |
| `Config.Fuel` | 'LegacyFuel' | Your fuel resource name |
| `Config.Radio.Enabled` | true | Push-to-talk from inside the MDT |
| `Config.Radio.VoiceSystem` | 'auto' | `auto`, `pma-voice`, `saltychat`, or `yaca` |
| `Config.Dashcam.Positions` | — | Per-model dashcam positions. Vehicles not listed here can't be viewed |
| `Config.OfficerStatus.Default` | 'active' | Status an officer starts a shift on |
| `Config.VehicleInsurance` / `Config.VehicleRegistration` / `Config.VehiclePoints` | — | Turn each vehicle column on or off. Disabled ones vanish from the grid entirely |
| `Config.CivilianAccess` | — | Civilian mode: profile and legislation view |
| `Config.Debug` | false | Debug logging |

## Preview
<img width="2445" height="1305" alt="Screenshot 2026-03-22 185605" src="https://github.com/user-attachments/assets/7f228a36-5d82-40ba-ade9-d9da78d249fd" />
<img width="2455" height="1310" alt="Screenshot 2026-03-22 185655" src="https://github.com/user-attachments/assets/e0291f16-efa6-4d86-b3ad-f82ccdb8deb3" />
<img width="2445" height="1316" alt="Screenshot 2026-03-22 185712" src="https://github.com/user-attachments/assets/f6c4bb93-c178-4b64-bb8c-3f38b7f09eba" />
<img width="2447" height="1306" alt="Screenshot 2026-03-22 185704" src="https://github.com/user-attachments/assets/d6dbba26-189c-427b-9e10-4c5c2d20056c" />
<img width="2431" height="1297" alt="Screenshot 2026-03-22 185726" src="https://github.com/user-attachments/assets/5ed25446-3706-4e35-8cc9-d18c265d1ed0" />


## Features

### Citizens
Look up any player. See their name, photo, gender, DOB, phone, fingerprint, job, vehicles, properties, arrest count, and linked reports. Edit licenses, add tags, upload photos, and take mugshots.

### Reports
Write incident reports with a rich text editor. Add suspects, victims, officers, charges, and evidence. Tag and restrict reports by department or rank. Two officers can write the same report at once and see each other's cursors live.

### Cases
Group related reports into investigations. Assign officers, set priority and status, attach files, track everything in one place.

### Evidence
Register evidence with type, serial, and location. Upload photos, track chain of custody, transfer between officers, link to cases and reports.

### Warrants
Issue warrants with expiry dates. Track felony/misdemeanor/infraction counts. Close them when served.

### BOLOs
Be On Lookout alerts for people and vehicles. Set status, share across departments.

### Vehicles
Search by plate, view registration and owner, manage DMV records and licence points. Insurance and registration checks hook into external resources, and each of those columns disappears from the grid entirely when you turn the feature off.

### Impound
Impound a vehicle from the MDT (only while it's sitting in a garage) or on the street with `/mdtimpound`. The on-site flow opens the same impound form the MDT uses, so an officer only ever learns one screen.

Every impound records the reason, officer, lot, fee, notes, and an optional photo link. Releasing doesn't wipe the record, so each vehicle keeps a full impound history. The fee grows with a daily storage charge that stops at a configurable cap, and a lot view lists everything currently held with its outstanding fees. Impounding a vehicle with an active BOLO resolves that BOLO automatically.

Vehicles nobody owns are a separate case: they're simply hauled away and the officer earns a small payout for keeping the streets clear, rate-limited by a cooldown and a per-shift cap.

### Weapons
Firearm registry with serial tracking and ownership history.

### Security Cameras
Place cameras around the map (23 prop models available). View feeds with pan, zoom, and FOV controls.

### Bodycams
Watch live feeds from on-duty officers.

### Dashcams
Live feeds from police vehicles, with per-model camera positions. Cars that haven't been configured are blocked server-side rather than showing a broken view.

### Map and Patrols
A live map of on-duty officers and police vehicles. Draw patrol zones, assign officers to them, and get entry and exit notifications. Dispatch calls show up on the same map, and units can be dragged onto a call to attach them.

### Officer Status
Officers set their own status (available, busy, on a call), which feeds the roster, the map, and dispatch.

### Radio
Push-to-talk from inside the MDT, so an officer can keep talking while typing a report. Detects pma-voice, SaltyChat, or YaCA automatically.

### Court and DOJ
A shared calendar for hearings and training, with per-category permissions and missed-hearing tracking. Reminders arrive as notifications even when the MDT is closed.

### Bulletin Board
Department noticeboard with per-job categories you can reorder, pin, and restrict.

### SOP
Standard operating procedures, grouped into categories, with acknowledgement tracking so you can see who has read what.

### FTO
Field training: assign trainees to training officers, record daily observation reports, and rate competencies.

### Civilian Mode
A cut-down MDT (profile and legislation only) that civilian resources can open — phone apps, courthouse scripts, and the like.

### Dashboard
Stats overview: reports this week vs last week, active units, job info.

### Dispatch
View and respond to dispatch calls. Hooks into ps-dispatch.

### Roster
All officers with duty status, callsign, and department.

### Leaderboard
Rankings by arrests, reports, and activity.

### Charges
Manage penal codes and charge definitions. Create, edit, and categorize charges by class (felony, misdemeanor, infraction) with configurable fines, jail time, and points.

### Awards
Recognize officers with department awards. Track commendations and achievements on officer profiles.

### Internal Affairs (IA)
File and manage internal affairs complaints against officers. Track complaint status through investigation stages (Open, Under Investigation, Investigated, Sustained, Exonerated, Unfounded, Closed). Includes a standalone complaint form accessible via `/complaint` command or export for civilian-facing resources. IA complaints appear in officer profiles under the IA History tab.

### PPR (Performance Planning & Review)
Create performance reviews for officers covering coachable moments, commendations, and developmental feedback. Supervisors can document incidents from cases, traffic stops, or any notable officer conduct. PPR records are tied to officer profiles and accessible from both the Personnel sidebar and the officer's profile PPR tab.

### Management
Admin panel for the department. Set permissions per rank, post bulletins, view audit logs, manage tags. There are 62 permissions you can assign per role, covering citizens, reports, cases, evidence, BOLOs, warrants, vehicles and impounds, weapons, charges, dispatch, cameras, bodycams, dashcams, patrols, the bulletin board, SOPs, FTO, the court calendar, and management access.

### Audit Trail
Every action gets logged. Who did what, when. Covers: logins, reports, cases, evidence, warrants, vehicles, weapons, charges, searches, dispatch, officers, sentencing, arrests, ICU. Each category toggles on/off from the settings page.

## Exports

For other resources to interact with the MDT.

### Client Exports

| Export | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `OpenMDT` | - | — | Opens the MDT interface for the current player |
| `CloseMDT` | - | — | Closes the MDT and restores player controls |
| `IsMDTOpen` | - | `boolean` | Returns whether the MDT is currently open |
| `IsLEOJob` | `jobName: string?` | `boolean` | Checks if a job is law enforcement. If no argument is passed, checks the current player's job |
| `isViewingCamera` | - | `boolean` | Returns whether the player is currently viewing a security camera feed |
| `openComplaint` | - | — | Opens the standalone IA complaint form (works outside the MDT, useful for civilian resources) |
| `openCivilianMDT` | - | — | Opens the MDT in civilian mode (profile + legislation view only). Use from phone apps, courthouse scripts, etc. |
| `impoundNearbyVehicle` | - | — | Runs the on-site impound on the vehicle the officer is in or standing next to. Hang this off a target or a keybind instead of the command |

### Server Exports

| Export | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `IsCidFelon` | `citizenid: string`, `cb: function?` | `boolean` | Checks if a citizen has any felony charges on record. Supports both callback and direct return |
| `registerWeapon` | `citizenid: string`, `weaponName: string`, `serial: string`, `info: string?` | - | Registers a weapon in the MDT firearms registry with ownership history |
| `GetCitizenPhoneNumber` | `citizenid: string` | `string?` | Returns a citizen's phone number |
| `isRequestVehicle` | `vehicleId: number` | `boolean` | **Deprecated.** Always returns `false`. Kept so v1 resources that call it don't error — impound state now lives in the `mdt_impound` table |

# 1of1 Servers - VPS & Dedicated Servers

[![1of1 Servers](https://github.com/user-attachments/assets/29e4ef8e-7b24-4821-a6ce-7c9e3c111fd1)](https://billing.1of1servers.com/aff.php?aff=1)

We are a VPS and dedicated server provider, specializing in strong gaming DDoS protection and 99.9% uptime.  

We host some of the biggest FiveM servers in the industry such as Prodigy RP, Smile RP, The Academy RP, and many more.  

---

### Features
- 6 Tbps DDoS Protection by Gcore or 477 Tbps by Magic Transit CloudFlare 
- 99.9% Network Uptime  
- NVMe SSD Storage  
- Unlimited Player Slots  
- Free transfer of files and setup  
- Free Windows licenses  
- Windows Remote Desktop  
- 24/7 Support with ~30 min average ticket response