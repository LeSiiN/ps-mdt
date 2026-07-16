local resourceName = tostring(GetCurrentResourceName())

RegisterNUICallback('globalSearch', function(data, cb)
    if not MDTOpen then cb({ results = {} }) return end
    local result = ps.callback(resourceName .. ':server:globalSearch', data or {})
    cb(result or { results = {} })
end)
