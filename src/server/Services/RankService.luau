--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AccountDataStore = require(ServerScriptService.Server.Accounts.Store)
local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)
local Ranks = require(ReplicatedStorage.Shared.Constants.Ranks)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local Objects = require(ReplicatedStorage.Shared.Util.Objects)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)

type Account = AccountTypes.Account
type CustomerReview = AccountTypes.CustomerReview
type RankField = AccountTypes.RankField
type RankFieldProgress = AccountTypes.RankFieldProgress
type BusinessState = BusinessTypes.BusinessState

type RankServiceType = RuntimeTypes.ModuleRuntimeType & {
	GetRankForValue: (field: RankField, value: number) -> RankFieldProgress,
	GetDefaultRankFields: () -> { [RankField]: RankFieldProgress },
	ApplyCustomerReviewToAccount: (account: Account, review: CustomerReview) -> Account,
	SetRankValue: (player: Player, field: RankField, value: number) -> boolean,
	AddRankValue: (player: Player, field: RankField, delta: number) -> boolean,
	SetBusinessRankValue: (business: BusinessState, field: RankField, value: number) -> boolean,
	AddBusinessRankValue: (business: BusinessState, field: RankField, delta: number) -> boolean,
	RecordCustomerReview: (player: Player, review: CustomerReview) -> boolean,
}

local RankService = {} :: RankServiceType

RankService.Name = "RankService"
RankService.Priority = 0
RankService.Dependencies = {}
RankService.Disabled = false

local VALUE_PER_RANK = 100
local FIELD_ORDER: { RankField } = { "CustomerService", "Security", "Stock", "Mining" }
local VALID_FIELDS: { [string]: boolean } = {
	CustomerService = true,
	Security = true,
	Stock = true,
	Mining = true,
}

local function getRankNames(field: RankField, value: number): ({ string }, string)
	local rankData = Ranks :: any
	if field == "CustomerService" then
		if value < 0 then
			return rankData.CustomerService.Negative, "Negative"
		end

		return rankData.CustomerService.Positive, "Positive"
	elseif field == "Security" then
		return rankData.Security, "Positive"
	elseif field == "Stock" then
		return rankData.Stock, "Positive"
	else
		return rankData.Mining, "Positive"
	end
end

local function isValidField(field: string): boolean
	return VALID_FIELDS[field] == true
end

local function getFieldValue(account: Account, field: RankField): number
	local accountData = account :: any
	local rankFields = accountData.RankFields
	if type(rankFields) ~= "table" then
		return 0
	end

	local progress = rankFields[field]
	if type(progress) ~= "table" or typeof(progress.Value) ~= "number" then
		return 0
	end

	return progress.Value
end

local function makeProgress(field: RankField, value: number): RankFieldProgress
	if field ~= "CustomerService" then
		value = math.max(0, value)
	end

	local rankNames, polarity = getRankNames(field, value)
	local magnitude = math.abs(value)
	local rankIndex = math.clamp(math.floor(magnitude / VALUE_PER_RANK) + 1, 1, #rankNames)

	return {
		Field = field,
		Value = value,
		RankIndex = rankIndex,
		RankName = rankNames[rankIndex] or rankNames[1] or "",
		Polarity = polarity,
	}
end

local function getDefaultRankFields(): { [RankField]: RankFieldProgress }
	return {
		CustomerService = makeProgress("CustomerService", 0),
		Security = makeProgress("Security", 0),
		Stock = makeProgress("Stock", 0),
		Mining = makeProgress("Mining", 0),
	}
end

local function getNormalizedRankFields(account: Account): { [RankField]: RankFieldProgress }
	local fields = getDefaultRankFields()
	for _, field in FIELD_ORDER do
		fields[field] = makeProgress(field, getFieldValue(account, field))
	end
	return fields
end

local function isStronger(left: RankFieldProgress, right: RankFieldProgress?): boolean
	if right == nil then
		return true
	end

	if left.RankIndex ~= right.RankIndex then
		return left.RankIndex > right.RankIndex
	end

	return math.abs(left.Value) > math.abs(right.Value)
end

local function calculateOverallRank(fields: { [RankField]: RankFieldProgress }): RankFieldProgress
	local strongest: RankFieldProgress? = nil
	for _, field in FIELD_ORDER do
		local progress = fields[field]
		if isStronger(progress, strongest) then
			strongest = progress
		end
	end

	return strongest or makeProgress("CustomerService", 0)
end

local function withRankState(account: Account, fields: { [RankField]: RankFieldProgress }): Account
	local overall = calculateOverallRank(fields)
	return Objects.join(account, {
		RankFields = fields,
		OverallRank = overall,
		OverallKnownRank = overall.RankName,
	})
end

local function getPlayerForBusiness(business: BusinessState): Player?
	return Players:GetPlayerByUserId(business.ownerUserId)
end

local function getReviewDelta(review: CustomerReview): number
	local starDelta = (review.stars - 3) * 60
	local satisfactionDelta = review.satisfaction - 50
	local spendingBonus = math.min(review.spentAmount / 50, 80)
	local theftPenalty = math.min(review.stolenValue / 50, 120)
	local sentimentDelta = if review.sentiment == "Positive" then 50 elseif review.sentiment == "Angry" then -50 else 0

	return starDelta + satisfactionDelta + spendingBonus - theftPenalty + sentimentDelta
end

function RankService:OnInit() end

function RankService:OnStart() end

function RankService.GetRankForValue(field: RankField, value: number): RankFieldProgress
	return makeProgress(field, value)
end

function RankService.GetDefaultRankFields(): { [RankField]: RankFieldProgress }
	return getDefaultRankFields()
end

function RankService.ApplyCustomerReviewToAccount(account: Account, review: CustomerReview): Account
	local fields = getNormalizedRankFields(account)
	local current = fields.CustomerService.Value
	fields.CustomerService = makeProgress("CustomerService", current + getReviewDelta(review))
	return withRankState(account, fields)
end

function RankService.SetRankValue(player: Player, field: RankField, value: number): boolean
	if not isValidField(field) then
		return false
	end

	local currentAccount = AccountStore.getAccount(player.Name)
	if currentAccount then
		local currentProgress = getNormalizedRankFields(currentAccount)[field]
		local nextProgress = makeProgress(field, value)
		if not isStronger(nextProgress, currentProgress) then
			return false
		end
	end

	AccountDataStore:updateImmutable(player, function(account: Account)
		local fields = getNormalizedRankFields(account)
		fields[field] = makeProgress(field, value)
		return withRankState(account, fields)
	end)

	return true
end

function RankService.AddRankValue(player: Player, field: RankField, delta: number): boolean
	if not isValidField(field) or delta == 0 then
		return false
	end

	AccountDataStore:updateImmutable(player, function(account: Account)
		local fields = getNormalizedRankFields(account)
		fields[field] = makeProgress(field, fields[field].Value + delta)
		return withRankState(account, fields)
	end)

	return true
end

function RankService.SetBusinessRankValue(business: BusinessState, field: RankField, value: number): boolean
	local player = getPlayerForBusiness(business)
	if not player then
		return false
	end

	return RankService.SetRankValue(player, field, value)
end

function RankService.AddBusinessRankValue(business: BusinessState, field: RankField, delta: number): boolean
	local player = getPlayerForBusiness(business)
	if not player then
		return false
	end

	return RankService.AddRankValue(player, field, delta)
end

function RankService.RecordCustomerReview(player: Player, review: CustomerReview): boolean
	AccountDataStore:updateImmutable(player, function(account: Account)
		return RankService.ApplyCustomerReviewToAccount(account, review)
	end)

	return true
end

return RankService