local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Charm = require(ReplicatedStorage.Shared.Modules.Charm)
local CharmSync = require(ReplicatedStorage.Shared.Modules.CharmSync)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)
local BusinessStore = require(ServerScriptService.Server.Stores.BusinessStore)

local function onPlayerAdded(player: Player)
    CharmSync.server.addSignalsToClient(player, {
        [`account-{player.Name}`] = Charm.computed(function()
            return AccountStore.getAccount(player.Name)
        end),
		[`business-{player.UserId}`] = Charm.computed(function()
			return BusinessStore.getBusinessForOwner(player.UserId)
		end),
    })
end

local function onPlayerRemoving(player: Player)
	CharmSync.server.removeClient(player)
end

CharmSync.server.connect(function(player, patches)
	Remotes.patch:FireClient(player, patches)
end)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
