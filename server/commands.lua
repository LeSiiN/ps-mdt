
-- Command to set the Message of the Day (MOTD) - stores as a bulletin
local motdCommandName = (Config and Config.Commands and Config.Commands.MessageOfTheDay and Config.Commands.MessageOfTheDay.command) or 'motd'
local motdEnabled = Config and Config.Commands and Config.Commands.MessageOfTheDay and Config.Commands.MessageOfTheDay.enabled ~= false

if motdEnabled then
    RegisterCommand(motdCommandName, function(source, args, rawCommand)
        local src = source
        if not src or src == 0 then return end

        if not IsPoliceJob(MDT.getJobName(src), MDT.getJobType(src)) or not MDT.isBoss(src) then
            MDT.notify(src, 'You do not have permission to use this command', 'error')
            return
        end

        local newMessage = table.concat(args, " ")
        if not newMessage or newMessage == "" then
            MDT.notify(src, 'Please provide a message', 'error')
            return
        end

        -- Remove any existing MOTD bulletin and insert the new one
        pcall(MySQL.query.await, "DELETE FROM mdt_bulletins WHERE content LIKE '[MOTD]%'")
        local ok, err = pcall(MySQL.insert.await, 'INSERT INTO mdt_bulletins (content) VALUES (?)', { '[MOTD] ' .. newMessage })
        if not ok then
            MDT.warn('Failed to save MOTD: ' .. tostring(err))
            MDT.notify(src, 'Failed to save Message of the Day', 'error')
            return
        end

        Cache.invalidate('dashboard:bulletins')
        MDT.notify(src, 'Message of the Day updated successfully', 'success')

        -- Notify online police officers
        local players = MDT.getAllPlayers()
        for _, player in pairs(players) do
            if IsPoliceJob(MDT.getJobName(player), MDT.getJobType(player)) and src ~= player then
                MDT.notify(player, 'Message of the Day has been updated', 'info')
            end
        end
    end, false)
end
