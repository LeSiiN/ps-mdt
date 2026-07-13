-- isRequestVehicle: kept only so external resources that call this ps-mdt v1
-- export don't error. The in-memory impound list it used to read was never
-- populated, so it always returned false — impound state now lives in
-- mdt_impound (see server/backend/impound.lua).
local function isRequestVehicle(_vehId)
    return false
end

exports('isRequestVehicle', isRequestVehicle)

-- IsCidFelon: checks if a citizen has felony charges
local function IsCidFelon(sentCid, cb)
    if not sentCid then
        if cb then cb(false) end
        return false
    end

    local felonyCount = MySQL.scalar.await([[
        SELECT COUNT(*)
        FROM mdt_reports_charges rc
        JOIN mdt_penal_codes pc ON rc.charge = pc.label
        WHERE rc.citizenid = ? AND pc.charge_class = 'felony'
    ]], { sentCid })

    local isFelon = (felonyCount and felonyCount > 0)
    if cb then cb(isFelon) end
    return isFelon
end

exports('IsCidFelon', IsCidFelon)