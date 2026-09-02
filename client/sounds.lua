-- Sound definitions
local MDTSounds = {
    open = {
        audioName = 'ATM_WINDOW',
        audioRef = 'HUD_FRONTEND_DEFAULT_SOUNDSET'
    },
    close = {
        audioName = 'BACK',
        audioRef = 'HUD_FRONTEND_DEFAULT_SOUNDSET'
    },
    buttonClick = {
        audioName = 'SELECT',
        audioRef = 'HUD_FRONTEND_DEFAULT_SOUNDSET'
    },
    reminder = {
        audioName = 'Text_Arrive_Tone',
        audioRef = 'Phone_SoundSet_Default'
    },
}

-- Play sound based on input
function PlayMDTSound(soundType)
    -- Honors Settings > Appearance > "Notification Sounds" (mirrored from the
    -- NUI via preferences.lua). The toggle existed before but nothing ever
    -- read it. Guarded: if the mirror isn't loaded, sounds stay on (default).
    if MdtPref and MdtPref('notificationSounds', true) == false then return end
    if not MDTSounds[soundType] then
        MDT.debug('Unknown MDT sound type:', soundType)
        return
    end

    local sound = MDTSounds[soundType]
    MDT.playSound({
        audioName = sound.audioName,
        audioRef  = sound.audioRef,
    })

    MDT.debug('Playing MDT sound:', soundType)
end