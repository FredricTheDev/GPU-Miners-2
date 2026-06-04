local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Objects = require(ReplicatedStorage.Shared.Util.Objects)
local Store = require(script.Store)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)

type Account = AccountTypes.Account

local function addCash(player: Player, amount: number)
	return Store:updateImmutable(player, function(account: Account)
		return Objects.join(account, {
			Cash = account.Cash + amount,
		})
	end)
end

return {
	addCash = addCash,
}
