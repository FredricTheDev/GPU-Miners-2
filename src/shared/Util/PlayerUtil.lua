--!strict
local Players = game:GetService("Players")

local PlayerUtil = {}

function PlayerUtil.GetPlayerByUserId(id: number): Player?
	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId == id then
			return player
		end
	end
	return nil
end

function PlayerUtil.GetCharacter(player: Player): Model
	return player.Character or player.CharacterAdded:Wait()
end

return PlayerUtil
