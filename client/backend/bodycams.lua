local resourceName = tostring(GetCurrentResourceName())

-- Events
RegisterNUICallback('viewBodycam', function(data, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end

    ps.debug('viewBodycam', data)

    local bodycamId = data
    if type(data) == 'table' then
        bodycamId = data.id or data.bodycamId or data
    end

    if not bodycamId then
        cb({ success = false, message = 'Invalid bodycam ID' })
        return
    end

    local result = ps.callback(resourceName .. ':server:viewBodycam', bodycamId)

    if result and result.success then
        CloseMDT(true)
        cb({ success = true })
    else
        cb({ success = false, message = result and result.error or 'Failed to view bodycam' })
    end

end)

RegisterNUICallback('getBodycams', function(_, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open', data = {} })
        return
    end

    local bodycams = ps.callback(resourceName .. ':server:getBodycams')

    if bodycams then
        cb({ success = true, data = bodycams })
    else
        cb({ success = false, message = 'Failed to fetch bodycams', data = {} })
    end
end)

-- ── Officer-controlled power ─────────────────────────────────────────────────

local function bodycamCfg()
    return (Config and Config.Bodycam) or {}
end

local function notify(msg, kind)
    if bodycamCfg().NotifyOfficer == false then return end
    if ps.notify then
        ps.notify(msg, kind or 'info')
    else
        ps.debug(msg)
    end
end

--- Toggle own bodycam. `desired` nil flips it.
local function toggleOwnBodycam(desired)
    local res = ps.callback(resourceName .. ':server:toggleBodycam',
        { on = desired })
    if not res or not res.success then
        notify(res and res.message or 'Could not change bodycam state', 'error')
        return
    end
    -- Say plainly that switching it off is on record; that is the deterrent, not a block.
    if res.isOnline then
        notify('Bodycam activated', 'success')
    else
        notify('Bodycam deactivated — this has been logged', 'error')
    end
end

CreateThread(function()
    if bodycamCfg().Enabled == false then return end
    local cmd = bodycamCfg().Command
    if not cmd or cmd == '' then return end

    RegisterCommand(cmd, function()
        toggleOwnBodycam(nil)
    end, false)

    TriggerEvent('chat:addSuggestion', '/' .. cmd, 'Turn your bodycam on or off')
end)

-- Automatic switching with duty. The preference lives in the NUI's storage, so the
-- decision is made here and the server is simply told the outcome — it stays the
-- authority on the state and on writing the log.
local function onDutyChanged(onDuty)
    if bodycamCfg().Enabled == false then return end
    if MdtPref('bodycamAutoDuty', bodycamCfg().AutoDutyDefault ~= false) ~= true then return end
    TriggerServerEvent(resourceName .. ':server:bodycamDutyChange', onDuty == true)
end

RegisterNetEvent('QBCore:Client:SetDuty', function(duty)
    onDutyChanged(duty == true)
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    if job and job.onduty ~= nil then
        onDutyChanged(job.onduty == true)
    end
end)

-- A bodycam going dark cuts any live viewer immediately.
RegisterNetEvent(resourceName .. ':client:bodycamPowerOff', function(data)
    if not data or not data.id then return end
    SendNUIMessage({ action = 'bodycamPowerOff', data = { id = tostring(data.id) } })
end)

-- ── NUI bridges ──────────────────────────────────────────────────────────────
RegisterNUICallback('toggleBodycam', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    cb(ps.callback(resourceName .. ':server:toggleBodycam', data or {}) or { success = false })
end)

RegisterNUICallback('getMyBodycam', function(_, cb)
    if not MDTOpen then cb({ success = false }) return end
    cb(ps.callback(resourceName .. ':server:getMyBodycam') or { success = false })
end)