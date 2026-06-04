local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)
local Store = require(script.Parent.Store)

Players.PlayerAdded:Connect(function(player)
	Store:load(player)
end)

Players.PlayerRemoving:Connect(function(player)
	Store:unload(player)
	AccountStore.removeAccount(player.Name)
end)

game:BindToClose(function()
	Store:closeAsync()
end)
