--!nocheck

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharmSync = require(ReplicatedStorage.Shared.Modules.CharmSync)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local AppStore = require("../Stores/AppStore")

CharmSync.client.addSignals({
	[`account-{Players.LocalPlayer.Name}`] = AppStore.setAccount,
	[`business-{Players.LocalPlayer.UserId}`] = AppStore.setBusiness,
})

Remotes.patch.OnClientEvent:Connect(function(patches)
	CharmSync.client.patch(patches)
end)
