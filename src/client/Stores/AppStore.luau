--!nocheck

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Shared.Modules.Charm)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)

type Account = AccountTypes.Account

local getAccount, setAccount = Charm.signal(AccountTypes.accountTemplate)
local getBusiness, setBusiness = Charm.signal(nil :: BusinessTypes.BusinessState?)

local getCash = Charm.computed(function()
	return getAccount().Cash
end)

local getClock = Charm.computed(function(previousClock)
	local account = getAccount() :: Account

	local currentDay = account.CurrentDay
	local currentMinute = account.CurrentMinute

	if previousClock
		and previousClock.CurrentDay == currentDay
		and previousClock.CurrentMinute == currentMinute
	then
		return previousClock
	end

	return {
		CurrentDay = currentDay,
		CurrentMinute = currentMinute
	}
end)

local getCustomers = Charm.computed(function()
	local business = getBusiness()
	return if business then business.customers else {}
end)

return {
	getAccount = getAccount,
	setAccount = setAccount,
	getCash = getCash,
	getClock = getClock,
	getBusiness = getBusiness,
	setBusiness = setBusiness,
	getCustomers = getCustomers,
}
