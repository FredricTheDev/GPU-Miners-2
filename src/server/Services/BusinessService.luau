--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)
local Objects = require(ReplicatedStorage.Shared.Util.Objects)
local Store = require(ServerScriptService.Server.Accounts.Store)
local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)
local BusinessStore = require(ServerScriptService.Server.Stores.BusinessStore)

type Account = AccountTypes.Account
type BusinessState = BusinessTypes.BusinessState
type ShelfState = BusinessTypes.ShelfState

local activeBusinesses: { [string]: BusinessState } = {}
local businessByOwner: { [number]: string } = {}

local function getNumber(value: any, fallback: number): number
	return if typeof(value) == "number" then value else fallback
end

local function withFinanceDefaults(account: Account): Account
	local accountData = account :: any
	local defaults = {}

	if typeof(accountData.PendingCardPayout) ~= "number" then
		defaults.PendingCardPayout = 0
	end
	if typeof(accountData.ClaimableCardPayout) ~= "number" then
		defaults.ClaimableCardPayout = 0
	end
	if typeof(accountData.LastBankDay) ~= "number" then
		defaults.LastBankDay = 0
	end

	return Objects.join(account, defaults)
end

local function syncFinanceToProfile(business: BusinessState)
	local player = Players:GetPlayerByUserId(business.ownerUserId)
	if not player then
		return
	end

	Store:updateImmutable(player, function(account: Account)
		return Objects.join(withFinanceDefaults(account), {
			Cash = business.cash,
			PendingCardPayout = business.store.pendingCardPayout,
			ClaimableCardPayout = business.store.claimableCardPayout,
			LastBankDay = business.store.currentBankDay,
		})
	end)
end

local function publishBusiness(business: BusinessState)
	BusinessStore.setBusiness(business)
end

local BusinessService = {}

BusinessService.Name = "BusinessService"
BusinessService.Priority = 0
BusinessService.Dependencies = {}
BusinessService.Disabled = false

-- for testing
local function createDefaultShelves(): { [string]: ShelfState }
	return {
		left_display_1 = {
			id = "left_display_1",
			gpuId = "fx_450",
			stockAmount = 6,
			maxStock = 12,
			priceMultiplier = 1,
		},
		left_display_2 = {
			id = "left_display_2",
			gpuId = "fx_480",
			stockAmount = 6,
			maxStock = 12,
			priceMultiplier = 1,
		},
		left_display_3 = {
			id = "left_display_3",
			gpuId = "fx_550",
			stockAmount = 6,
			maxStock = 12,
			priceMultiplier = 1,
		},
		right_display_1 = {
			id = "right_display_1",
			gpuId = "fx_5500",
			stockAmount = 6,
			maxStock = 12,
			priceMultiplier = 1,
		},
		right_display_2 = {
			id = "right_display_2",
			gpuId = "fx_6500",
			stockAmount = 6,
			maxStock = 12,
			priceMultiplier = 1,
		},
		right_display_3 = {
			id = "right_display_3",
			gpuId = "fx_6600",
			stockAmount = 6,
			maxStock = 12,
			priceMultiplier = 1,
		},
	}
end

function BusinessService:Configure(registry)
	self.registry = registry
end

function BusinessService:OnInit() end

function BusinessService:OnStart() end

function BusinessService.CreateBusinessForPlayer(player: Player): BusinessState
	local existingBusinessId = businessByOwner[player.UserId]
	if existingBusinessId then
		return activeBusinesses[existingBusinessId]
	end

	local businessId = `business_{player.UserId}`
	local account = AccountStore.getAccount(player.Name)
	local accountData = account :: any
	local startingCash = 5000
	local pendingCardPayout = 0
	local claimableCardPayout = 0
	local currentBankDay = 0
	if account then
		if getNumber(accountData.LastJoinTime, 0) ~= 0 or getNumber(accountData.Cash, 0) > 0 then
			startingCash = getNumber(accountData.Cash, startingCash)
		end
		pendingCardPayout = getNumber(accountData.PendingCardPayout, 0)
		claimableCardPayout = getNumber(accountData.ClaimableCardPayout, 0)
		currentBankDay = getNumber(accountData.LastBankDay, 0)
	end

	local business: BusinessState = {
		id = businessId,
		ownerUserId = player.UserId,
		cash = startingCash,
		reputation = 50,
		store = {
			shelves = createDefaultShelves(), -- mock shelves
			checkoutQueueLength = 0,
			checkoutQueueSlots = {},
			pendingCardPayout = pendingCardPayout,
			claimableCardPayout = claimableCardPayout,
			currentBankDay = currentBankDay,
			open = true,
		},
		warehouse = {
			inventory = {
				fx_450 = 24,
				fx_480 = 12,
				fx_550 = 12,
				fx_5500 = 12,
				fx_6500 = 12,
				fx_6600 = 12,
			},
			capacity = 250,
			usedCapacity = 84,
		},
		customerSpawnBudget = 0,
		staff = {},
		staffTasks = {},
		deliveries = {},
		miningRigs = {},
		security = {
			securityLevel = 10,
			cameraCoverage = 0,
			alarmLevel = 0,
			activeThefts = {},
			lastTheftDetectedAt = nil,
		},
		economy = {
			marketDemand = 1,
			cryptoPriceIndex = 1,
			electricityPricePerKwh = 0.18,
			lastWagePaidAt = os.clock(),
		},
		customers = {},
	}

	activeBusinesses[businessId] = business
	businessByOwner[player.UserId] = businessId -- can easily access busy through userId
	syncFinanceToProfile(business)
	publishBusiness(business)
	return business
end

function BusinessService.GetBusiness(businessId: string): BusinessState?
	return activeBusinesses[businessId]
end

function BusinessService.GetBusinessForPlayer(player: Player): BusinessState?
	local businessId = businessByOwner[player.UserId]
	if not businessId then
		return nil
	end
    return activeBusinesses[businessId]
end

function BusinessService.GetActiveBusinesses(): { [string]: BusinessState }
    return activeBusinesses
end

function BusinessService.PublishBusiness(business: BusinessState)
	publishBusiness(business)
end

function BusinessService.ValdiateOwnership(player: Player, businessId: string): boolean
    local business = activeBusinesses[businessId]
	return business ~= nil and business.ownerUserId == player.UserId
end

-- adding live data will be stored locally on the server as a snapshot and be periodically updated 
-- to the players data profile
function BusinessService.AddMoney(businessId: string, amount: number, reason: string?): boolean
    local business = activeBusinesses[businessId]
	if not business then
		return false
	end

	business.cash += math.max(0, amount)
	syncFinanceToProfile(business)
	publishBusiness(business)
	return true    
end

function BusinessService.AddPendingCardPayout(businessId: string, amount: number, reason: string?): boolean
	local business = activeBusinesses[businessId]
	if not business then
		return false
	end

	business.store.pendingCardPayout += math.max(0, amount)
	syncFinanceToProfile(business)
	publishBusiness(business)
	return true
end

function BusinessService.AdvanceCardPayoutDay(business: BusinessState)
	business.store.currentBankDay += 1
	if business.store.pendingCardPayout > 0 then
		business.store.claimableCardPayout += business.store.pendingCardPayout
		business.store.pendingCardPayout = 0
	end
	syncFinanceToProfile(business)
	publishBusiness(business)
end

function BusinessService.ClaimCardPayout(player: Player): number
	local business = BusinessService.GetBusinessForPlayer(player)
	if not business then
		return 0
	end

	local amount = math.max(0, business.store.claimableCardPayout)
	if amount <= 0 then
		return 0
	end

	business.store.claimableCardPayout = 0
	business.cash += amount
	syncFinanceToProfile(business)
	publishBusiness(business)
	return amount
end

function BusinessService.LoadBusiness(player: Player): BusinessState
    -- replace with real data
	return BusinessService.CreateBusinessForPlayer(player)
end

function BusinessService.SaveBusiness(businessId: string): boolean
    -- save data to player profile
	return activeBusinesses[businessId] ~= nil
end

function BusinessService.RemoveBusiness(businessId: string)
    local business = activeBusinesses[businessId]
    if not business then
        return
    end

    businessByOwner[business.ownerUserId] = nil
    activeBusinesses[businessId] = nil
	BusinessStore.removeBusiness(businessId)
end

return BusinessService
