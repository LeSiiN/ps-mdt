local resourceName = tostring(GetCurrentResourceName())

RegisterNUICallback('getAuditLogs', function(data, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end

    local result = MDT.callback(resourceName .. ':server:getAuditLogs', data)
    cb(result or {})
end)

RegisterNUICallback('getAuditLogsByCase', function(data, cb)
    if not MDTOpen then
        cb({ success = false, message = 'MDT is not open' })
        return
    end

    local result = MDT.callback(
        resourceName .. ':server:getAuditLogsByCase',
        data.caseId,
        data.page,
        data.limit
    )
    cb(result or {})
end)
