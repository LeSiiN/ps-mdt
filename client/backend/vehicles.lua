local resourceName = tostring(GetCurrentResourceName())

RegisterNUICallback('getVehicles', function(data, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open', vehicles = {}, bolos = {} })
        return
    end
    local vehicleList = MDT.callback(resourceName .. ':server:GetVehicles')
    MDT.debug('[getVehicles] Triggered NUI callback on client', vehicleList)
    cb(vehicleList)
end)

RegisterNUICallback('getVehicleBolos', function(data, cb)
    if not MDTOpen then cb({}) return end
    local result = MDT.callback(resourceName .. ':server:getBOLO', 'vehicle')
    MDT.debug('[getVehicleBolos] Fetched vehicle BOLOs:', result)
    cb(result)
end)

RegisterNUICallback('getVehicle', function(data, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end

    if type(data) ~= 'table' or not data.plate then
        cb({ success = false, message = 'Missing plate' })
        return
    end

    local result = MDT.callback(resourceName .. ':server:GetVehicle', data.plate)
    if result then
        cb(result)
    else
        cb({ success = false, message = 'Vehicle not found' })
    end
end)

RegisterNUICallback('updateVehicle', function(data, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end

    if type(data) ~= 'table' or not data.plate then
        cb({ success = false, message = 'Missing plate' })
        return
    end

    local result = MDT.callback(resourceName .. ':server:UpdateVehicle', data)
    if result then
        cb(result)
    else
        cb({ success = false, message = 'Failed to update vehicle' })
    end
end)

RegisterNUICallback('getReportsByPlate', function(data, cb)
    if not MDTOpen then
        cb({ success = false, reports = {} })
        return
    end

    if type(data) ~= 'table' or not data.plate then
        cb({ success = false, reports = {} })
        return
    end

    local result = MDT.callback(resourceName .. ':server:getReportsByPlate', data.plate)
    cb({ success = true, reports = result or {} })
end)
