local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Shared.Modules.Charm)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)
local Objects = require(ReplicatedStorage.Shared.Util.Objects)

export type Account = AccountTypes.Account

type Accounts = {
    [string]: Account
}

local getAccounts, setAccounts = Charm.signal({} :: Accounts)

local function getAccount(username: string): Account?
	return getAccounts()[username]
end

local function setAccount(username: string, account: Account)
	setAccounts(function(state: Accounts)
		return Objects.set(state, username, account)
	end)
end

local function removeAccount(username: string)
	setAccounts(function(state: Accounts)
		return Objects.delete(state, username)
	end)
end

return {
	getAccounts = getAccounts,
	getAccount = getAccount,
	setAccount = setAccount,
	removeAccount = removeAccount,
}