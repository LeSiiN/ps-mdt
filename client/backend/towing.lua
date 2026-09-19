-- Tow jobs (client/backend/towing.lua)
-- A standalone list, not an MDT tab: a tow driver has no MDT access, and the
-- job is done out in the world.

local resourceName = GetCurrentResourceName()
local listOpen = false

local function towCfg()
    return (Config and Config.Towing) or {}
end

local function openList()
    if towCfg().Enabled == false then return end
    listOpen = true
    SendNUIMessage({ action = 'showTowJobs' })
    SetNuiFocus(true, true)
end

RegisterCommand(towCfg().Command or 'towjobs', function() openList() end, false)
TriggerEvent('chat:addSuggestion', '/' .. (towCfg().Command or 'towjobs'), 'Open the tow job list')
exports('OpenTowJobs', openList)

RegisterNUICallback('closeTowJobs', function(_, cb)
    listOpen = false
    SetNuiFocus(false, false)
    cb({})
end)

-- For the officer's impound form: which companies have somebody working.
RegisterNUICallback('getTowCompanies', function(_, cb)
    cb(MDT.callback(resourceName .. ':server:getTowCompanies') or {})
end)

--- Distance is the other half of the decision — a $750 job across the map is
--- worth less than a $500 one round the corner — and only the client knows
--- where the driver is standing.
local function withDistance(res)
    if type(res) ~= 'table' then return { jobs = {}, mine = nil } end
    local ped = cache and cache.ped or PlayerPedId()
    local here = GetEntityCoords(ped)

    local function tag(job)
        if type(job) ~= 'table' or type(job.coords) ~= 'string' then return end
        local x, y, z = job.coords:match('([%-%d%.]+),%s*([%-%d%.]+),%s*([%-%d%.]+)')
        if not x then return end
        job.distance = math.floor(#(vec3(tonumber(x), tonumber(y), tonumber(z)) - here))
    end

    for _, j in ipairs(res.jobs or {}) do tag(j) end
    tag(res.mine)

    -- Nearest first. The server orders by age, which matters for fairness, but
    -- a driver picking up work wants the one they can reach.
    table.sort(res.jobs or {}, function(a, b)
        return (a.distance or 99999) < (b.distance or 99999)
    end)
    return res
end

RegisterNUICallback('getTowJobs', function(_, cb)
    cb(withDistance(MDT.callback(resourceName .. ':server:getTowJobs')))
end)

RegisterNUICallback('takeTowJob', function(data, cb)
    cb(MDT.callback(resourceName .. ':server:takeTowJob', data and data.jobId)
        or { success = false, error = 'The server callback failed' })
end)

RegisterNUICallback('dropTowJob', function(data, cb)
    cb(MDT.callback(resourceName .. ':server:dropTowJob', data and data.jobId) or { success = true })
end)

RegisterNUICallback('deliverTowJob', function(data, cb)
    cb(MDT.callback(resourceName .. ':server:deliverTowJob', data)
        or { success = false, error = 'The server callback failed' })
end)

--- Waypoint to the vehicle, or to the drop-off once it is in tow.
RegisterNUICallback('towWaypoint', function(data, cb)
    local c = data and data.coords
    if type(c) == 'string' then
        local x, y = c:match('([%-%d%.]+),%s*([%-%d%.]+)')
        if x and y then SetNewWaypoint(tonumber(x), tonumber(y)) end
    elseif type(c) == 'table' and c.x then
        SetNewWaypoint(c.x + 0.0, c.y + 0.0)
    end
    cb({})
end)

-- A real dispatch call, with a blip to drive to. Falls back to a notification
-- where ps-dispatch isn't running, because the job list is the source of truth
-- either way.
--- Job NAME and TYPE both. ps-dispatch shows an alert to either, but its
--- respond button only checks the type — so with the name alone the call
--- appeared and the button did nothing.
local function jobTargets(job)
    local out = { job or MDT.getJobName() }
    local jobType = MDT.getJobType()
    if jobType and jobType ~= out[1] then out[#out + 1] = jobType end
    return out
end

RegisterNetEvent('ps-mdt:client:towJobPosted', function(data)
    if type(data) ~= 'table' then return end

    local c = data.coords
    if GetResourceState('ps-dispatch') == 'started' and type(c) == 'table' and c.x then
        exports['ps-dispatch']:CustomAlert({
            -- Job NAME and TYPE both. ps-dispatch shows an alert to either,
            -- but its respond button only checks the type — so with the name
            -- alone the call appeared and the button did nothing.
            jobs = jobTargets(data.job),
            coords = { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0 },
            message = 'Tow Requested',
            dispatchCode = '10-52',
            description = ('Impound tow — $%s'):format(data.pay or 0),
            firstStreet = data.location or '',
            model = data.model,
            plate = data.plate,
            name = data.officer or 'Law Enforcement',
            radius = 0,
            sprite = 68,
            color = 5,
            scale = 1.0,
            length = 5,
            -- No respond prompt. ps-dispatch offers this for alerts that are an
            -- answer rather than a job; here the reason is different but the
            -- outcome is the same — responding would attach the driver to a
            -- call, while taking the work happens in the job list, and two ways
            -- to accept one job is how two drivers end up on it.
            footer = {
                text = ('Accept in /%s'):format((towCfg().Command or 'towjobs')),
                icon = 'fas fa-truck-pickup',
            },
        })
    else
        MDT.notify(('Tow requested: %s (%s)%s')
            :format(data.model or 'vehicle', data.plate or '—',
                    data.location and (' — ' .. data.location) or ''), 'inform')
    end
end)

RegisterNUICallback('setTowAvailable', function(data, cb)
    cb(MDT.callback(resourceName .. ':server:setTowAvailable', data and data.available)
        or { success = false })
end)

RegisterNUICallback('getTowAvailable', function(_, cb)
    cb(MDT.callback(resourceName .. ':server:getTowAvailable') or { available = true })
end)
