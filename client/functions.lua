-- Dispatch Functions --

-- Get Recent Dispatch Calls
-- Coalescing wrapper around the server round-trip. Concurrency itself is no
-- longer a correctness problem (ox_lib keys pending callbacks per request, not
-- per name, unlike the old ps_lib implementation), but the NUI's list polling
-- and the attach/assign flows still overlap constantly, so all concurrent
-- callers share ONE in-flight request instead of each paying a round-trip.
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
        return MDT.callback(resourceName .. ':server:getRecentDispatches')
    end)
    local value = (ok and result) or {}

    recentDispatchInflight = nil
    p:resolve(value)
    return value
end

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    local check = MDT.callback('ps-mdt:hasProfile')
end)