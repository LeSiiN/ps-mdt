local resourceName = GetCurrentResourceName()

-- NUI bridges for citations and parking tickets. Thin by design: every check
-- lives on the server, which is the only side that can be trusted with a fine.

RegisterNUICallback('getCitations', function(data, cb)
    local citizenid = type(data) == 'table' and data.citizenid or data
    cb(MDT.callback(resourceName .. ':server:getCitations', citizenid) or {})
end)

RegisterNUICallback('getCitation', function(data, cb)
    local number = type(data) == 'table' and data.number or data
    cb(MDT.callback(resourceName .. ':server:getCitation', number))
end)

RegisterNUICallback('createCitation', function(data, cb)
    -- No MDTOpen check: the ticket form is standalone and the tablet is shut.
    -- That check is why the charges list came back empty; it would have made
    -- issuing impossible too.
    local res = MDT.callback(resourceName .. ':server:createCitation', data)
    -- nil here means the server callback itself failed. Say so rather than
    -- letting the form sit until fetchNui times out.
    cb(res or { success = false, error = 'The server callback failed — check the server console for the reason.' })
end)

RegisterNUICallback('voidCitation', function(data, cb)
    local number = type(data) == 'table' and data.number or data
    cb(MDT.callback(resourceName .. ':server:voidCitation', number) or { success = false })
end)

-- Context for the ticket form: what the officer is standing in front of.
-- Gathered here rather than typed in, because a plate read off the car is
-- right and a plate typed from memory often isn't.

local function citCfg()
    return (Config and Config.Citations) or {}
end

--- Everything the paper needs about a vehicle, in one place so the picker and
--- the auto-fill can't describe the same car differently.
---@param veh number
---@return table
function DescribeVehicle(veh)
    local model = GetEntityModel(veh)
    local make = GetLabelText(GetMakeNameFromVehicleModel(model))
    local name = GetLabelText(GetDisplayNameFromVehicleModel(model))

    -- "Vapid Scout" rather than "Scout": the make is half of how a witness
    -- describes a car, and half of what makes a plate lookup unambiguous.
    local label = name
    if make and make ~= '' and make ~= 'NULL' and not name:find(make, 1, true) then
        label = make .. ' ' .. name
    end

    local primary = GetVehicleColours(veh)
    return {
        plate = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', ''):upper(),
        plateIndex = GetVehicleNumberPlateTextIndex(veh),
        label = label,
        make = make,
        model = name,
        color = VehicleColourName and VehicleColourName(primary) or nil,
    }
end

--- Nearest vehicle that isn't a police car, within the configured radius.
---@param radius number
---@return number|nil vehicle, number distance
local function nearestCivilianVehicle(radius)
    local ped = cache and cache.ped or PlayerPedId()
    local here = GetEntityCoords(ped)
    local best, bestDist

    for _, veh in ipairs(GetGamePool('CVehicle')) do
        -- An officer's own car is never the one being ticketed.
        local class = GetVehicleClass(veh)
        if class ~= 18 then
            local d = #(GetEntityCoords(veh) - here)
            if d <= radius and (not bestDist or d < bestDist) then
                best, bestDist = veh, d
            end
        end
    end
    return best, bestDist or 0
end

RegisterNUICallback('getTicketContext', function(data, cb)

    local ticketType = type(data) == 'table' and data.type or 'citation'
    -- One radius, one config key. PlateSearchRadius was renamed and the
    -- fallback chain kept a dead name alive, which made the effective distance
    -- hard to reason about.
    local radius = tonumber(citCfg().VehicleSearchRadius) or 10.0

    local ped = cache and cache.ped or PlayerPedId()
    local coords = GetEntityCoords(ped)
    local street, zone = GetStreetNameAtCoord(coords.x, coords.y, coords.z)

    local out = {
        location = ('%s, %s'):format(
            GetStreetNameFromHashKey(street) or 'Unknown',
            zone and GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z)) or ''),
        postal = nil,
    }

    -- Postals come from whatever postal resource the server runs. The UI hides
    -- the field entirely when none is configured or running, rather than
    -- showing a box that can never be filled.
    local pcfg = citCfg().Postal or {}
    local pres = pcfg.Resource
    if pres and GetResourceState(pres) == 'started' then
        local ok, postal = pcall(function()
            return exports[pres][pcfg.Export or 'getPostal']()
        end)
        if ok and postal then
            out.postal = type(postal) == 'table' and (postal.code or postal.postal) or postal
        end
        out.hasPostal = true
    else
        out.hasPostal = false
    end

    -- The header names the issuing agency, so it has to be the officer's own
    -- job label — not a hard-coded department that would be wrong on every
    -- server but one.
    local job = MDT.getJobData and MDT.getJobData() or nil
    out.agency = (job and (job.label or job.name)) or 'Police Department'
    out.officerName = MDT.getPlayerName and MDT.getPlayerName() or ''
    out.officerCallsign = MDT.getMetadata and MDT.getMetadata('callsign') or nil

    -- Only for parking tickets is a vehicle part of the ticket by default. A
    -- citation may have nothing to do with a car, so it starts without one and
    -- the officer attaches it deliberately.
    -- The nearest car is described either way. For a parking ticket it becomes
    -- the subject; for a citation the officer still has to attach it, but the
    -- colour and model are already resolved when they do.
    do
        local veh, dist = nearestCivilianVehicle(radius)
        if veh then
            local v = DescribeVehicle(veh)
            out.plate, out.vehicle, out.vehicleColor = v.plate, v.label, v.color
            out.plateIndex = v.plateIndex
            out.distance = math.floor(dist * 10) / 10
        end
    end

    cb(out)
end)

-- ── Opening the form ────────────────────────────────────────────────────────
-- Not an MDT tab: a ticket is written at the roadside, and how it is triggered
-- is the server's decision. Two commands ship as the default, and the same
-- entry point is exported so a radial menu, a target option or an item can use
-- it instead.

--- @param ticketType string 'citation' | 'parking'
local function openTicketForm(ticketType)
    if citCfg().Enabled == false then return end

    -- Refused before anything opens. Writing a ticket is something you do
    -- standing up, on your feet, with your hands free — an officer face down
    -- in the water should not be filling in a form.
    local ped = cache and cache.ped or PlayerPedId()
    local blocked =
        IsPedDeadOrDying(ped, true) and 'you are down'
        or IsPedCuffed(ped) and 'you are restrained'
        or IsPedInAnyVehicle(ped, false) and 'you are in a vehicle'
        or IsPedSwimming(ped) and 'you are in the water'
        or IsPedRagdoll(ped) and 'you are on the ground'
        or IsPedFalling(ped) and 'you are falling'
        or nil

    if blocked then
        MDT.notify(('Not now — %s.'):format(blocked), 'error')
        return
    end

    -- Finding out you are not allowed only once the form is on screen is a
    -- worse answer than a straight no.
    local jobType = MDT.getJobType and MDT.getJobType()
    if jobType ~= (Config.PoliceJobType or 'leo') then
        MDT.notify('Only law enforcement can write tickets.', 'error')
        return
    end
    if ticketType ~= 'parking' and ticketType ~= 'warning' then ticketType = 'citation' end

    -- Two stages. Who or what the ticket is for is settled first, in a small
    -- picker, and only then does the form open with everything already filled.
    -- Asking for it inside the form meant an officer could start writing
    -- against nobody and find out at the end.
    formOpen = true
    SendNUIMessage({ action = 'showTicketPicker', data = { type = ticketType } })
    SetNuiFocus(true, true)
end

exports('OpenCitationForm', function() openTicketForm('citation') end)
exports('OpenParkingTicketForm', function() openTicketForm('parking') end)

RegisterCommand('citation', function() openTicketForm('citation') end, false)
RegisterCommand('parkingticket', function() openTicketForm('parking') end, false)

TriggerEvent('chat:addSuggestion', '/citation', 'Write a traffic citation')
TriggerEvent('chat:addSuggestion', '/parkingticket', 'Write a parking ticket')

-- The form closes itself; releasing focus is the client's job.
-- The paper closes on its own path, so the two windows cannot switch each
-- other's animation off.
RegisterNUICallback('closePaper', function(_, cb)
    paperOpen = false
    suppressStartUntil = GetGameTimer() + 1500
    if not delivering then StopTicketAnim() end
    SetNuiFocus(false, false)
    cb({})
end)

RegisterNUICallback('closeTicketForm', function(_, cb)
    -- Closing ends the pose, here rather than in the UI: one path instead of
    -- several that can disagree.
    formOpen = false
    suppressStartUntil = GetGameTimer() + 1500
    if not delivering then StopTicketAnim() end
    SetNuiFocus(false, false)
    cb({})
end)

-- The ticket form runs without the MDT being open, so it cannot use the
-- charges bridge in client/backend/charges.lua — that one requires MDTOpen and
-- would hand back an empty list. Same data, no tablet required.
RegisterNUICallback('getTicketCharges', function(_, cb)
    if citCfg().Enabled == false then cb({}) return end
    cb(MDT.callback('ps-mdt:getChargeList', false) or {})
end)

-- ── Picking who the ticket is for ───────────────────────────────────────────
-- A citation is written against a person standing there; a parking ticket
-- against a car that was left. So the two look for different things, and the
-- officer picks from what is actually in front of them rather than typing an
-- id from memory.

RegisterNUICallback('getTicketTargets', function(data, cb)
    if citCfg().Enabled == false then cb({}) return end

    local ticketType = type(data) == 'table' and data.type or 'citation'
    local ped = cache and cache.ped or PlayerPedId()
    local here = GetEntityCoords(ped)
    local out = {}

    if ticketType == 'parking' then
        local radius = tonumber(citCfg().VehicleSearchRadius) or 10.0
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            if GetVehicleClass(veh) ~= 18 then
                local d = #(GetEntityCoords(veh) - here)
                if d <= radius then
                    local v = DescribeVehicle(veh)
                    v.kind = 'vehicle'
                    v.distance = math.floor(d * 10) / 10
                    out[#out + 1] = v
                end
            end
        end
    else
        local radius = tonumber(citCfg().PersonSearchRadius) or 5.0
        for _, playerId in ipairs(GetActivePlayers()) do
            local target = GetPlayerPed(playerId)
            -- With debug on the officer appears in their own list. Testing the
            -- whole flow alone is otherwise impossible.
            local includeSelf = MDT.isDebug and MDT.isDebug()
            if target and target ~= 0 and (includeSelf or target ~= ped) then
                local d = #(GetEntityCoords(target) - here)
                if d <= radius then
                    out[#out + 1] = {
                        kind = 'person',
                        serverId = GetPlayerServerId(playerId),
                        distance = math.floor(d * 10) / 10,
                    }
                end
            end
        end

        -- Testing alone: your own entry is filled from the data this client
        -- already holds. No lookup, because there is nothing to look up — the
        -- point is to have a target at all, not to prove the query works.
        for i = 1, #out do
            if out[i].serverId == GetPlayerServerId(PlayerId()) then
                local ci = MDT.getCharInfo and MDT.getCharInfo() or {}
                out[i].citizenid = MDT.getIdentifier and MDT.getIdentifier() or 'debug'
                out[i].label = ci.firstname
                    and (ci.firstname .. ' ' .. (ci.lastname or ''))
                    or (MDT.getPlayerName and MDT.getPlayerName() or 'Me')
                out[i].self = true
            end
        end

        -- Names and profile pictures come from the server: a client knows who
        -- is standing there, not who they are on paper.
        -- Only the others need looking up.
        if #out > 0 then
            local ids = {}
            for i = 1, #out do
                if not out[i].self then ids[#ids + 1] = out[i].serverId end
            end
            local info = #ids > 0 and (MDT.callback(resourceName .. ':server:describePlayers', ids) or {}) or {}
            for i = 1, #out do
                local d = info[tostring(out[i].serverId)] or info[out[i].serverId]
                if d then
                    out[i].citizenid = d.citizenid
                    out[i].label = d.name
                    out[i].image = d.image
                end
            end
        end
    end

    -- Stored images, same ones the Vehicles tab shows. Fetched in one call
    -- rather than guessing a file path per model.
    if ticketType == 'parking' and #out > 0 then
        local plates = {}
        for i = 1, #out do plates[i] = out[i].plate end
        local info = MDT.callback(resourceName .. ':server:describeVehicles', plates) or {}
        local kept = {}
        for i = 1, #out do
            local d = info[out[i].plate]
            if d then
                out[i].image = d.image
                out[i].owner = d.owner
                out[i].citizenid = d.citizenid
            end
            -- A parking ticket needs somebody to answer for the car, so an
            -- unregistered one is no use. A citation only DESCRIBES a vehicle,
            -- and an NPC car at the scene is an ordinary detail — dropping
            -- those is what made the picker look broken.
            if d or ticketType ~= 'parking' then
                kept[#kept + 1] = out[i]
            end
        end
        out = kept
    end

    if MDT.isDebug and MDT.isDebug() then
        MDT.debug(('ticket targets: %d found (%s)'):format(#out, ticketType))
    end

    table.sort(out, function(a, b) return a.distance < b.distance end)
    cb(out)
end)

-- ── Animations ──────────────────────────────────────────────────────────────
-- One prop and one task at a time, always released through stopTicketAnim.
-- Anything that leaves the player in a state where the animation no longer
-- makes sense — entering a vehicle, dying, the resource stopping — clears it,
-- because a clipboard welded to somebody's hand outlives the bug that put it
-- there.

local animProps = {}
local animActive = false
-- The form closes 1.5s after issuing, and its stop used to cut the handover
-- off mid-gesture. A delivery outlives the window that ordered it.
local delivering = false
-- Whether a ticket form is on screen at all. The animation follows this, not
-- the order in which the UI's effects happen to fire — three of them racing to
-- send start and stop is how a start arrived after the close.
local formOpen = false
-- The paper has its own flag. Sharing one with the form meant closing a copy
-- switched the form's animation off, and vice versa — two windows, two states.
local paperOpen = false
-- Svelte's effects fire in an order this side cannot see, and a stale one keeps
-- sending a start just after the close. Rather than guess at the order, ignore
-- any start that arrives in the moment after a window was shut.
local suppressStartUntil = 0

local function animCfg(key)
    local a = (citCfg().Animations) or {}
    if a.Enabled == false then return nil end
    local entry = a[key]
    if entry == false or type(entry) ~= 'table' then return nil end
    return entry
end

local function clearProp()
    for i = 1, #animProps do
        if DoesEntityExist(animProps[i]) then DeleteEntity(animProps[i]) end
    end
    animProps = {}
end

--- Release whatever the officer is holding and drop the task.
function StopTicketAnim()
    animActive = false
    clearProp()
    local ped = cache and cache.ped or PlayerPedId()
    ClearPedTasks(ped)
end

--- Attach a prop to the hand.
--- Attach every prop an animation carries. A notepad needs a pencil to go with
--- it, so this takes a list — and no props at all is a valid choice, not a
--- missing setting: the windscreen ticket is left on the car, and a notepad
--- still in hand afterwards reads wrong.
local function attachProp(entry)
    local list = entry.props
    -- Single-prop entries still work, so an old config doesn't have to change.
    if not list and entry.prop then
        list = { { name = entry.prop, bone = entry.bone, pos = entry.pos, rot = entry.rot } }
    end
    if type(list) ~= 'table' then return end

    local ped = cache and cache.ped or PlayerPedId()
    local coords = GetEntityCoords(ped)

    for i = 1, #list do
        local pr = list[i]
        if pr.name and MDT.requestModel(pr.name, 2000) then
            local obj = CreateObject(joaat(pr.name), coords.x, coords.y, coords.z, true, true, false)
            AttachEntityToEntity(
                obj, ped, GetPedBoneIndex(ped, pr.bone or 18905),
                pr.pos and pr.pos.x or 0.0, pr.pos and pr.pos.y or 0.0, pr.pos and pr.pos.z or 0.0,
                pr.rot and pr.rot.x or 0.0, pr.rot and pr.rot.y or 0.0, pr.rot and pr.rot.z or 0.0,
                true, true, false, true, 1, true)
            animProps[#animProps + 1] = obj
            SetModelAsNoLongerNeeded(joaat(pr.name))
        end
    end
end

--- Play a one-shot animation, then clean up. Returns when it is done.
local function playOnce(entry)
    if not entry then return end
    local ped = cache and cache.ped or PlayerPedId()
    if not MDT.requestAnim(entry.dict, 2000) then return end

    attachProp(entry)
    TaskPlayAnim(ped, entry.dict, entry.clip, 3.0, 3.0, entry.duration or 2000, 49, 0, false, false, false)
    Wait(entry.duration or 2000)
    clearProp()
    ClearPedTasks(ped)
end

--- Hold a looping animation until StopTicketAnim is called.
local function playLoop(entry)
    if not entry then return end
    local ped = cache and cache.ped or PlayerPedId()

    -- A scenario carries its own prop and idle variation, which reads better
    -- for standing and writing than a looped clip with a prop bolted on.
    if entry.scenario then
        animActive = true
        TaskStartScenarioInPlace(ped, entry.scenario, 0, true)
        CreateThread(function()
            while animActive do
                Wait(500)
                if not animActive then break end
                if IsPedInAnyVehicle(ped, false) or IsPedDeadOrDying(ped, true) then
                    StopTicketAnim()
                    SendNUIMessage({ action = 'closeTicketForm' })
                    SetNuiFocus(false, false)
                    break
                end
            end
        end)
        return
    end

    if not MDT.requestAnim(entry.dict, 2000) then
        MDT.error(('Animation dict failed to load: %s'):format(tostring(entry.dict)))
        return
    end

    animActive = true
    attachProp(entry)
    -- Flag 49: loop, upper body only, so the officer can still turn and walk.
    TaskPlayAnim(ped, entry.dict, entry.clip, 3.0, 3.0, -1, 49, 0, false, false, false)

    -- Re-assert the loop if something interrupts it, and give up the moment
    -- the pose stops making sense.
    CreateThread(function()
        while animActive do
            Wait(500)
            -- Checked again after the wait. The stop can land during those 500
            -- milliseconds, and the rest of this iteration would then re-assert
            -- the very animation that was just cancelled — which is why it kept
            -- coming back a moment after closing, no matter what the UI sent.
            if not animActive then break end
            if IsPedInAnyVehicle(ped, false) or IsPedDeadOrDying(ped, true) then
                StopTicketAnim()
                SendNUIMessage({ action = 'closeTicketForm' })
                SetNuiFocus(false, false)
                break
            end
            if not IsEntityPlayingAnim(ped, entry.dict, entry.clip, 3) then
                TaskPlayAnim(ped, entry.dict, entry.clip, 3.0, 3.0, -1, 49, 0, false, false, false)
            end
        end
    end)
end

RegisterNUICallback('ticketAnimStart', function(_, cb)
    -- A start that arrives after the close is ignored. The UI may send them in
    -- either order; the client decides which one is still true.
    -- The start IS the signal that the form is up. Gating it on a flag set by
    -- the command was backwards: the UI reaches stage "write" some time after
    -- the command, and anything that touched the flag in between — closing a
    -- carbon copy, for one — silenced the pose for good.
    --
    -- Stopping stays authoritative, so a stray start can still be undone.
    if GetGameTimer() < suppressStartUntil then cb({}) return end
    formOpen = true

    if not animCfg('Writing') then
        MDT.error('Config.Citations.Animations.Writing is missing or disabled')
    end
    playLoop(animCfg('Writing'))
    cb({})
end)

-- Reading a copy has its own pose: the officer holds it up rather than writes
-- on it.
RegisterNUICallback('ticketAnimRead', function(_, cb)
    if not paperOpen or GetGameTimer() < suppressStartUntil then cb({}) return end
    playLoop(animCfg('Reading'))
    cb({})
end)

RegisterNUICallback('ticketAnimStop', function(_, cb)
    -- Not while a handover is playing: that one ends on its own.
    if not delivering then StopTicketAnim() end
    cb({})
end)

--- Played once the ticket is issued: handed over, or put on the windscreen.
RegisterNUICallback('ticketAnimDeliver', function(data, cb)
    StopTicketAnim()

    local isParking = type(data) == 'table' and data.type == 'parking'
    local entry = animCfg(isParking and 'Windscreen' or 'Handover')

    -- Answer straight away; the animation is scenery, not something the form
    -- should wait on before telling the officer the ticket was issued.
    cb({})

    CreateThread(function()
        delivering = true
        if not isParking and entry and entry.recipientClip and data and data.targetServerId then
            TriggerServerEvent('ps-mdt:server:ticketReceiveAnim',
                tonumber(data.targetServerId), entry.dict, entry.recipientClip, entry.duration or 2000)
        end
        playOnce(entry)
        delivering = false
    end)
end)

-- The receiving half, so an exchange reads as one action between two people.
RegisterNetEvent('ps-mdt:client:ticketReceiveAnim', function(dict, clip, duration)
    if not dict or not clip then return end
    local ped = cache and cache.ped or PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsPedDeadOrDying(ped, true) then return end
    if not MDT.requestAnim(dict, 2000) then return end
    TaskPlayAnim(ped, dict, clip, 3.0, 3.0, duration or 2000, 49, 0, false, false, false)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        clearProp()
    end
end)

-- Told to the recipient, not shown to the officer. A parking ticket is found,
-- not handed over, so it says where to look — otherwise the first a citizen
-- knows about it is the warrant.
RegisterNetEvent('ps-mdt:client:citationReceived', function(data)
    if type(data) ~= 'table' then return end
    local amount = data.fine and ('$%s'):format(data.fine) or ''

    if data.parking then
        MDT.notify(('A parking ticket was left on your windscreen (%s, %s). You can settle it in the MDT.')
            :format(data.number, amount), 'inform')
    else
        MDT.notify(('You were issued citation %s (%s). You can settle it in the MDT.')
            :format(data.number, amount), 'inform')
    end
end)

RegisterNUICallback('payCitation', function(data, cb)
    local number = type(data) == 'table' and data.number or data
    cb(MDT.callback(resourceName .. ':server:payCitation', number)
        or { success = false, message = 'The server callback failed' })
end)

-- ── Carbon copies ───────────────────────────────────────────────────────────
-- ox_inventory calls this when either copy is used. Only the citation number
-- travels in the item; everything else — including whether it has been paid —
-- is read fresh, so a slip written yesterday cannot contradict this morning.
local function openPaper(number, carbon)
    paperOpen = true
    if type(number) ~= 'string' or number == '' then
        MDT.notify('This copy is unreadable.', 'error')
        return
    end
    SendNUIMessage({ action = 'showCitationPaper', data = { number = number, carbon = carbon } })
    SetNuiFocus(true, true)
end

--- Dig the citation number out of whatever shape the inventory hands over.
--- ox_inventory passes { name, metadata, slot }, but forks and qb-inventory
--- nest it differently, and a stacked-item path can wrap it again. Rather than
--- betting on one shape, look in all of them.
---@param data any
---@return string|nil number, string|nil itemName
local function readCopy(data)
    if type(data) ~= 'table' then return nil, nil end
    local found

    local name = data.name or (data.item and data.item.name)
    local candidates = {
        data.metadata,
        data.info,
        data.item and data.item.metadata,
        data.item and data.item.info,
        data,
    }
    for i = 1, #candidates do
        local m = candidates[i]
        if type(m) == 'table' then
            local n = m.citation or m.number or m.citation_number
            if type(n) == 'string' and n ~= '' then return n, name end
        end
    end
    -- ox_inventory hands the ITEM DEFINITION to a client export, not the slot
    -- that was used, so the payload carries a slot number and no metadata.
    -- GetSlot is server-side only; on the client the way in is Search, which
    -- returns every slot holding that item WITH its metadata.
    if name and data.slot and GetResourceState('ox_inventory') == 'started' then
        local ok, slots = pcall(function()
            return exports.ox_inventory:Search('slots', name)
        end)
        if not ok or type(slots) ~= 'table' then
            MDT.error(('Search(slots, %s) failed: %s'):format(name, tostring(slots)))
        end
        if ok and type(slots) == 'table' then
            for _, sl in pairs(slots) do
                local m = type(sl) == 'table' and sl.metadata
                if type(m) == 'table' then
                    local n = m.citation or m.number or m.citation_number
                    -- Prefer the exact slot; fall back to any copy that has a
                    -- number, since using one of several identical slips is the
                    -- same act either way.
                    if type(n) == 'string' and n ~= '' then
                        if sl.slot == data.slot then return n, name end
                        found = found or n
                    end
                end
            end
            if found then return found, name end
        end
    end

    return nil, name
end

exports('useCitationCopy', function(data)
    if MDT.isDebug and MDT.isDebug() then
        MDT.debug(('useCitationCopy: name=%s slot=%s')
            :format(tostring(data and data.name), tostring(data and data.slot)))
    end
    local number, name = readCopy(data)
    if not number then
        -- Say what actually arrived. "Unreadable" on its own tells whoever has
        -- to fix it nothing at all.
        MDT.error(('useCitationCopy got no citation number. Payload: %s')
            :format(json.encode(data)))
    end
    -- The officer's copy is a record of what they wrote; the recipient's is a
    -- thing to act on. Same sheet, different buttons.
    openPaper(number, name == 'citation_carbon')
end)

RegisterNUICallback('signCitation', function(data, cb)
    local number = type(data) == 'table' and data.number or data
    cb(MDT.callback(resourceName .. ':server:signCitation', number)
        or { success = false, error = 'The server callback failed' })
end)

-- ── Last measured speed ─────────────────────────────────────────────────────
-- Reading the number off the radar rather than off memory. An officer who has
-- walked back to the driver should not have to walk to the car again because
-- they forgot whether it was 121 or 112 — and a remembered speed is a speed
-- that gets rounded, which matters when it decides the charge.
--
-- Which resource and export to ask is configured, because radars differ. The
-- value is offered, never inserted: the officer still puts it in.

RegisterNUICallback('getRadarSpeed', function(_, cb)
    local rcfg = citCfg().Radar or {}
    local res = rcfg.Resource

    if not res or GetResourceState(res) ~= 'started' then
        cb({ ok = false, message = 'No radar running' })
        return
    end

    local ok, value = pcall(function()
        return exports[res][rcfg.Export or 'GetLastSpeed']()
    end)

    if not ok then
        cb({ ok = false, message = 'The radar did not answer' })
        return
    end

    -- Radars report in different shapes: a bare number, or a table with the
    -- speed and the plate it belongs to.
    local speed, plate
    if type(value) == 'table' then
        speed = tonumber(value.speed or value.mph or value.value)
        plate = value.plate
    else
        speed = tonumber(value)
    end

    if not speed or speed <= 0 then
        cb({ ok = false, message = 'The radar has no reading' })
        return
    end

    cb({ ok = true, speed = math.floor(speed), plate = plate })
end)

-- The other half of the signature: the officer learns it was acknowledged.
RegisterNetEvent('ps-mdt:client:citationSigned', function(data)
    if type(data) ~= 'table' then return end
    MDT.notify(('%s signed citation %s.')
        :format(data.name or 'The recipient', data.number or ''), 'success')
end)

RegisterNUICallback('getMyCitations', function(_, cb)
    cb(MDT.callback(resourceName .. ':server:getMyCitations') or {})
end)
