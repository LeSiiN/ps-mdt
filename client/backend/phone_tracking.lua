-- Phone tracking — NUI bridge.
-- Every one of these is a thin pass-through: the permission checks, the
-- approval window and the ping schedule all live server-side, because a client
-- that could be trusted with any of that could be trusted to fake a warrant.

local resourceName = tostring(GetCurrentResourceName())

RegisterNUICallback('lookupPhoneNumber', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    cb(ps.callback(resourceName .. ':server:lookupPhoneNumber', (data or {}).number) or { success = false })
end)

RegisterNUICallback('requestPhoneTrack', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    cb(ps.callback(resourceName .. ':server:requestPhoneTrack', data or {}) or { success = false })
end)

RegisterNUICallback('reviewPhoneTrack', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    data = data or {}
    cb(ps.callback(resourceName .. ':server:reviewPhoneTrack', data.id, data.decision, data.reason)
        or { success = false })
end)

RegisterNUICallback('startPhoneTrack', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    cb(ps.callback(resourceName .. ':server:startPhoneTrack', (data or {}).id) or { success = false })
end)

RegisterNUICallback('cancelPhoneTrack', function(data, cb)
    if not MDTOpen then cb({ success = false }) return end
    cb(ps.callback(resourceName .. ':server:cancelPhoneTrack', (data or {}).id) or { success = false })
end)

RegisterNUICallback('getPhoneTracks', function(_, cb)
    if not MDTOpen then cb({ success = false, mine = {}, active = {} }) return end
    cb(ps.callback(resourceName .. ':server:getPhoneTracks') or { success = false, mine = {}, active = {} })
end)

RegisterNUICallback('getPhoneTrackRequests', function(_, cb)
    if not MDTOpen then cb({ success = false, pending = {}, recent = {} }) return end
    cb(ps.callback(resourceName .. ':server:getPhoneTrackRequests')
        or { success = false, pending = {}, recent = {} })
end)
