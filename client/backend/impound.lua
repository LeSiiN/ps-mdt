-- Impound NUI callbacks - bridge between the Svelte UI and the server.

local resourceName = tostring(GetCurrentResourceName())

local function bridge(name, event, requirePlate)
    RegisterNUICallback(name, function(data, cb)
        if not MDTOpen then
            cb({ success = false, message = 'MDT is not open' })
            return
        end
        if requirePlate and (type(data) ~= 'table' or not data.plate) then
            cb({ success = false, message = 'Missing plate number' })
            return
        end
        local result = ps.callback(resourceName .. ':server:' .. event, data or {})
        cb(result or { success = false, message = 'Request failed' })
    end)
end

bridge('impoundVehicle',    'impoundVehicle',    true)
bridge('releaseImpound',    'releaseImpound',    true)
bridge('payImpoundFee',     'payImpoundFee',     true)
bridge('getImpoundHistory', 'getImpoundHistory', true)
bridge('getImpoundLot',     'getImpoundLot',     false)
bridge('getImpoundConfig',  'getImpoundConfig',  false)