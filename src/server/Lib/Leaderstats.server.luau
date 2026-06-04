local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Charm = require(ReplicatedStorage.Shared.Modules.Charm)
local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)

type Account = AccountTypes.Account

Charm.observe(AccountStore.getAccounts, function(initialAccount: Account, username: string)
	local player = Players:FindFirstChild(username) :: Player?

	if not player then
		return
	end

	local getAccount = Charm.computed(function(prevAccount: Account?)
		return AccountStore.getAccount(username) or prevAccount or initialAccount
	end)

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Parent = leaderstats

	Charm.effect(function()
		local account = getAccount()
		cash.Value = account.Cash
	end)

	return function()
		leaderstats:Destroy()
	end
end)