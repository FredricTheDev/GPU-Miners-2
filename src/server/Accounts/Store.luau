--!nocheck

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Lyra = require(ReplicatedStorage.Packages.Lyra)
local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)
local Schema = require(ServerScriptService.Server.Accounts.Schema)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)

type Account = AccountTypes.Account

local function onAccountChanged(key: string, account: Account)
	local player = Players:GetPlayerByUserId(tonumber(key) :: number)
	if player then
		AccountStore.setAccount(player.Name, account)
	end
end

return Lyra.createPlayerStore({
	name = "PlayerData",
	template = AccountTypes.accountTemplate,
	schema = function(value)
		local ok, reason = Schema:matches(value)
		return ok, tostring(reason)
	end,
	changedCallbacks = { onAccountChanged },
	memoryStoreService = if RunService:IsStudio() then Lyra.MockMemoryStoreService.new() else nil,
	dataStoreService = if RunService:IsStudio() then Lyra.MockDataStoreService.new() else nil,
})