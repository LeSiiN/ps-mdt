local resourceName = tostring(GetCurrentResourceName())

local function appCfg()
    return (Config and Config.Applications) or {}
end

-- Open the standalone application form for a department. Like the complaint form, this
-- runs WITHOUT the MDT being open — any civilian can apply.
local function OpenApplicationForm(department)
    SendNUIMessage({ action = 'showApplicationForm', data = { department = department } })
    SetNuiFocus(true, true)
end

-- Register one command per configured department (e.g. /applypolice, /applyems). Doing
-- it from config means adding a department is a config edit, not a code change.
CreateThread(function()
    if appCfg().Enabled ~= true then return end
    for _, dept in ipairs(appCfg().Departments or {}) do
        if dept.command and dept.id then
            local deptId = dept.id
            RegisterCommand(dept.command, function()
                OpenApplicationForm(deptId)
            end, false)

            -- Chat autocomplete description, same as the MDT open command. Prefer an
            -- explicit dept.description from config, otherwise build one from the label.
            local label = dept.label or dept.id
            local description = dept.description or ('Apply to ' .. label)
            TriggerEvent('chat:addSuggestion', '/' .. dept.command, description)
        end
    end
end)

-- Applicant fetches the form definition (questions) for their department.
RegisterNUICallback('getApplicationForm', function(data, cb)
    data = data or {}
    if not data.department then cb({ success = false, message = 'Missing department' }) return end
    local result = ps.callback(resourceName .. ':server:getApplicationForm', data.department)
    cb(result or { success = false })
end)

-- Submit. No MDTOpen check — standalone form, same as complaints.
RegisterNUICallback('submitApplication', function(data, cb)
    if not data or not data.department then
        cb({ success = false, message = 'Missing department' })
        return
    end
    local result = ps.callback(resourceName .. ':server:submitApplication', data)
    cb(result or { success = false })
end)

RegisterNUICallback('closeApplication', function(_, cb)
    SetNuiFocus(false, false)
    cb({ success = true })
end)

-- ── Editor callbacks (MDT-side) ──────────────────────────────────────────────
-- These back Management → Applications and are only meaningful with the MDT open.
RegisterNUICallback('getApplicationDepartments', function(_, cb)
    if not MDTOpen then cb({ success = false, departments = {} }) return end
    local result = ps.callback(resourceName .. ':server:getApplicationDepartments')
    cb(result or { success = false, departments = {} })
end)

RegisterNUICallback('getApplicationQuestions', function(data, cb)
    if not MDTOpen then cb({ success = false, questions = {} }) return end
    data = data or {}
    local result = ps.callback(resourceName .. ':server:getApplicationQuestions', data.department)
    cb(result or { success = false, questions = {} })
end)

RegisterNUICallback('saveApplicationQuestion', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    local result = ps.callback(resourceName .. ':server:saveApplicationQuestion', data)
    cb(result or { success = false })
end)

RegisterNUICallback('deleteApplicationQuestion', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    local result = ps.callback(resourceName .. ':server:deleteApplicationQuestion', data)
    cb(result or { success = false })
end)

RegisterNUICallback('reorderApplicationQuestions', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    local result = ps.callback(resourceName .. ':server:reorderApplicationQuestions', data)
    cb(result or { success = false })
end)

-- ── Reviewing applications (Roster → Applications) ────────────────────────────
RegisterNUICallback('getApplications', function(data, cb)
    if not MDTOpen then cb({ success = false, applications = {} }) return end
    local result = ps.callback(resourceName .. ':server:getApplications', data or {})
    cb(result or { success = false, applications = {} })
end)

RegisterNUICallback('getApplication', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    local result = ps.callback(resourceName .. ':server:getApplication', data or {})
    cb(result or { success = false })
end)

RegisterNUICallback('decideApplication', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    local result = ps.callback(resourceName .. ':server:decideApplication', data or {})
    cb(result or { success = false })
end)