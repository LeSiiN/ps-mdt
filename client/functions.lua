-- Dispatch Functions --

-- Get Recent Dispatch Calls
-- Coalescing wrapper around the server round-trip. ps_lib keys pending
-- callbacks by NAME ONLY, so two concurrent ps.callback calls for the same
-- name overwrite each other's promise and one caller awaits forever (10s NUI
-- timeout). The NUI's list polling and the attach/assign flows can overlap,
-- so all concurrent callers share ONE in-flight request instead of racing.
-- Same pattern as the coalescing loadRequests fix in the warrant system.
local recentDispatchInflight = nil
function GetRecentDispatch()
    if recentDispatchInflight then
        return Citizen.Await(recentDispatchInflight)
    end
    recentDispatchInflight = promise.new()
    local p = recentDispatchInflight

    local resourceName = tostring(GetCurrentResourceName())
    local ok, result = pcall(function()
        return ps.callback(resourceName .. ':server:getRecentDispatches')
    end)
    local value = (ok and result) or {}

    recentDispatchInflight = nil
    p:resolve(value)
    return value
end

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    local check = ps.callback('ps-mdt:hasProfile')
end)