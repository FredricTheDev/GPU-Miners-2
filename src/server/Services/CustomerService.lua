--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldQueryService = require(script.Parent.WorldQueryService)
local Sift = require(ReplicatedStorage.Packages.Sift)
local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

type CustomerAction = "Buy" | "Steal" | "Leave"

type BusinessState = BusinessTypes.BusinessState
type CustomerProfile = BusinessTypes.CustomerProfile
type CustomerRuntimeState = BusinessTypes.CustomerRuntimeState
type ShelfState = BusinessTypes.ShelfState
type ShoppingGoal = BusinessTypes.ShoppingGoal

type CheckoutQueueEntry = {
	customerId: string,
	slot: number,
	distance: number?,
}

type CustomerServiceType = RuntimeTypes.ModuleRuntimeType & {
	_registry: any,

	_storeService: any?,
	_avatarService: any?,
	_securityService: any?,
	_businessService: any?,

	Configure: (self: CustomerServiceType, registry: any) -> (),
	OnInit: (self: CustomerServiceType) -> (),
	OnStart: (self: CustomerServiceType) -> (),

	SpawnCustomer: (business: BusinessState) -> CustomerRuntimeState,
	ThinkForCustomer: (
		business: BusinessState,
		customer: CustomerRuntimeState,
		observedScore: number?
	) -> "Buy" | "Steal" | "Leave",
	SpawnPhysicalCustomerAsync: (business: BusinessState, customer: CustomerRuntimeState) -> (),
	UpdateCustomers: (business: BusinessState, deltaSeconds: number) -> (),
	GetCustomer: (businessId: string, customerId: string) -> CustomerRuntimeState?,
	DecidePhysicalCustomerAction: (
		businessId: string,
		customerId: string,
		customerModel: Model
	) -> ("Buy" | "Steal" | "Leave", string?),
	TryCompletePhysicalPurchase: (businessId: string, customerId: string) -> boolean,
	TryStartPhysicalTheft: (businessId: string, customerId: string, customerModel: Model) -> boolean,
	DespawnPhysicalCustomer: (businessId: string, customerId: string) -> (),
	ChoosePhysicalBrowseShelf: (businessId: string, customerId: string) -> string?,
	BuildPhysicalBrowseRoute: (businessId: string, customerId: string) -> { string },
	ConsiderBrowsedShelf: (
		businessId: string,
		customerId: string,
		shelfId: string,
		customerModel: Model
	) -> "Cart" | "Ignore" | "Steal" | "Leave",
	HasCartItems: (businessId: string, customerId: string) -> boolean,
	EnterPhysicalCheckoutQueue: (businessId: string, customerId: string) -> boolean,
	RebalancePhysicalCheckoutQueue: (businessId: string) -> (),
	GetCheckoutQueueSlot: (businessId: string, customerId: string) -> number,
	GetCheckoutQueueJoinSlot: (businessId: string) -> number,
	LeavePhysicalCheckoutQueue: (businessId: string, customerId: string) -> (),
}

local CustomerService = {} :: CustomerServiceType

CustomerService.Name = "CustomerService"
CustomerService.Priority = 0
CustomerService.Dependencies = { "StoreService", "AvatarService", "SecurityService" }
CustomerService.Disabled = false

local customerCounter = 0

local GPU_CHOICES = { "fx_450", "fx_480", "fx_550", "fx_5500", "fx_6500", "fx_7500" }
local SHOPPING_GOALS: { ShoppingGoal } = { "Gaming", "Mining", "Budget", "Premium" }
local MAX_BROWSE_STOPS = 6

local MIN_SPAWN_INTERVAL = 15
local MAX_SPAWN_INTERVAL = 30
local MAX_ACTIVE_CUSTOMERS = 3

local GPU_GOAL_FIT: { [string]: { [string]: number } } = {
	fx_450 = {
		Gaming = 0.35,
		Mining = 0.3,
		Budget = 1,
		Premium = 0.1,
	},
	fx_480 = {
		Gaming = 0.85,
		Mining = 0.7,
		Budget = 0.55,
		Premium = 0.45,
	},
	fx_550 = {
		Gaming = 1,
		Mining = 1,
		Budget = 0.15,
		Premium = 1,
	},
	fx_5500 = {
		Gaming = 0.35,
		Mining = 0.3,
		Budget = 1,
		Premium = 0.1,
	},
	fx_6500 = {
		Gaming = 0.85,
		Mining = 0.7,
		Budget = 0.55,
		Premium = 0.45,
	},
	fx_7500 = {
		Gaming = 1,
		Mining = 1,
		Budget = 0.15,
		Premium = 1,
	},
}

local function countCustomers(business: BusinessState): number
	local count = 0
	for _ in business.customers do
		count += 1
	end
	return count
end

local function nextCustomerId(): string
	customerCounter += 1
	return `customer_{customerCounter}`
end

local function contains(list: { string }, value: string): boolean
	for _, item in list do
		if item == value then
			return true
		end
	end
	return false
end

local function shuffle(list: { string }): { string }
	local result = table.clone(list)
	for index = #result, 2, -1 do
		local swapIndex = math.random(1, index)
		result[index], result[swapIndex] = result[swapIndex], result[index]
	end
	return result
end

local function getGoalFit(gpuId: string?, shoppingGoal: string): number
	if not gpuId then
		return 0
	end

	local fit = GPU_GOAL_FIT[gpuId]
	if not fit then
		return 0.35
	end

	return fit[shoppingGoal] or 0.35
end

local function chooseShoppingGoal(): ShoppingGoal
	return SHOPPING_GOALS[math.random(1, #SHOPPING_GOALS)] :: any
end

local function chooseWantedGpuIds(shoppingGoal: ShoppingGoal, budget: number, maxPurchases: number): { string }
	local candidates = table.clone(GPU_CHOICES)
	table.sort(candidates, function(left, right)
		local leftAffordable = if CustomerService._storeService.GetBaseGpuPrice(left) <= budget then 0.25 else 0
		local rightAffordable = if CustomerService._storeService.GetBaseGpuPrice(right) <= budget then 0.25 else 0
		return getGoalFit(left, shoppingGoal) + leftAffordable > getGoalFit(right, shoppingGoal) + rightAffordable
	end)

	local wantedCount = math.clamp(math.random(1, maxPurchases), 1, #candidates)
	local wantedGpuIds = {}
	for index = 1, wantedCount do
		table.insert(wantedGpuIds, candidates[index])
	end

	return wantedGpuIds
end

local function createRandomProfile(): CustomerProfile
	local shoppingGoal: ShoppingGoal = chooseShoppingGoal()
	local maxPurchases = math.random(1, 3)
	local budgetByGoal = {
		Gaming = math.random(650, 2600),
		Mining = math.random(900, 3600),
		Budget = math.random(250, 1200),
		Premium = math.random(1600, 5200),
	}
	local budget = budgetByGoal[shoppingGoal]
	local wantedGpuIds = chooseWantedGpuIds(shoppingGoal, budget, maxPurchases)

	return {
		budget = budget,
		patience = math.random(35, 115),
		theftRiskTolerance = math.random(),
		priceSensitivity = if shoppingGoal == "Premium" then math.random() * 0.35 else math.random(),
		preferredGpuId = wantedGpuIds[1],
		shoppingGoal = shoppingGoal,
		wantedGpuIds = wantedGpuIds,
		maxPurchases = maxPurchases,
		impulseBuyChance = math.clamp(
			math.random() * 0.45 + getGoalFit(wantedGpuIds[1], shoppingGoal) * 0.15,
			0.08,
			0.6
		),
	}
end

local function getCartPlannedSpend(business: BusinessState, customer: CustomerRuntimeState): number
	local total = 0
	for _, shelfId in customer.cartShelfIds do
		local shelf = CustomerService._storeService.GetShelf(business, shelfId)
		if shelf then
			total += CustomerService._storeService.GetShelfSellPrice(business, shelf) or 0
		end
	end
	return total
end

local function getAvailableCartBudget(business: BusinessState, customer: CustomerRuntimeState): number
	return math.max(0, customer.profile.budget - getCartPlannedSpend(business, customer))
end

local function scoreShelfAppeal(customer: CustomerRuntimeState, shelf: ShelfState, business: BusinessState): number
	if not shelf.gpuId then
		return 0
	end

	local price = CustomerService._storeService.GetShelfSellPrice(business, shelf)
	if not price or price > getAvailableCartBudget(business, customer) then
		return 0
	end

	local demand = BusinessMath.CalculateCustomerDemand(
		business.economy.marketDemand,
		business.reputation,
		customer.profile.priceSensitivity
	)
	local basePrice = CustomerService._storeService.GetBaseGpuPrice(shelf.gpuId)
	local priceRatio = price / math.max(1, basePrice)
	local wishlistBonus = if contains(customer.profile.wantedGpuIds, shelf.gpuId) then 35 else 0
	local goalBonus = getGoalFit(shelf.gpuId, customer.profile.shoppingGoal) * 35
	local bargainBonus = math.clamp(1.15 - priceRatio, 0, 0.6) * 40
	local expensivePenalty = math.max(0, priceRatio - 1) * customer.profile.priceSensitivity * 35

	return 15 + wishlistBonus + goalBonus + bargainBonus + demand * 15 - expensivePenalty
end

local function ensureCheckoutQueueSlots(business: BusinessState): { [string]: number }
	if business.store.checkoutQueueSlots == nil then
		business.store.checkoutQueueSlots = {}
	end
	return business.store.checkoutQueueSlots
end

local function countCheckoutQueueSlots(business: BusinessState): number
	local count = 0
	for _ in ensureCheckoutQueueSlots(business) do
		count += 1
	end
	return count
end

local function getFlatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function getCustomerPosition(businessId: string, customerId: string): Vector3?
	for _, instance in CollectionService:GetTagged(WorldTags.Customer) do
		if instance:GetAttribute("BusinessId") ~= businessId then
			continue
		end
		if instance:GetAttribute("CustomerId") ~= customerId then
			continue
		end

		local cframe = WorldQueryService.GetCFrame(instance)
		if cframe then
			return cframe.Position
		end
	end

	return nil
end

local function publishCheckoutQueueSlots(business: BusinessState)
	local slots = ensureCheckoutQueueSlots(business)

	for _, instance in CollectionService:GetTagged(WorldTags.Customer) do
		if instance:GetAttribute("BusinessId") ~= business.id then
			continue
		end

		local customerId = instance:GetAttribute("CustomerId")
		if typeof(customerId) ~= "string" then
			continue
		end

		instance:SetAttribute("CheckoutQueueSlot", slots[customerId])
		instance:SetAttribute("CheckoutQueueLength", business.store.checkoutQueueLength)
	end
end

local function applyCheckoutQueueEntries(business: BusinessState, entries: { CheckoutQueueEntry })
	local slots = ensureCheckoutQueueSlots(business)
	table.clear(slots)

	for index, entry in entries do
		slots[entry.customerId] = index
	end

	business.store.checkoutQueueLength = #entries
	publishCheckoutQueueSlots(business)
end

local function compactCheckoutQueueSlots(business: BusinessState)
	local entries: { CheckoutQueueEntry } = {}
	for customerId, slot in ensureCheckoutQueueSlots(business) do
		table.insert(entries, {
			customerId = customerId,
			slot = slot,
		})
	end

	table.sort(entries, function(left, right)
		return left.slot < right.slot
	end)

	applyCheckoutQueueEntries(business, entries)
end

local function rebalanceCheckoutQueueSlotsByDistance(business: BusinessState)
	local checkoutCFrame = WorldQueryService.GetCheckoutQueueCFrame(business.id, 1)
	local entries: { CheckoutQueueEntry } = {}

	for customerId, slot in ensureCheckoutQueueSlots(business) do
		local position = getCustomerPosition(business.id, customerId)
		table.insert(entries, {
			customerId = customerId,
			slot = slot,
			distance = if position then getFlatDistance(position, checkoutCFrame.Position) else math.huge,
		})
	end

	table.sort(entries, function(left, right)
		local leftDistance = left.distance or math.huge
		local rightDistance = right.distance or math.huge

		if leftDistance == rightDistance then
			if left.slot == right.slot then
				return left.customerId < right.customerId
			end
			return left.slot < right.slot
		end
		return leftDistance < rightDistance
	end)

	applyCheckoutQueueEntries(business, entries)
end

local function getTargetCustomers(demand: number): number
	return math.clamp(math.floor(2 + demand * 6), 1, MAX_ACTIVE_CUSTOMERS)
end

local function getSpawnInterval(demand: number): number
	local alpha = math.clamp(demand / 2, 0, 1)
	return MAX_SPAWN_INTERVAL + (MIN_SPAWN_INTERVAL - MAX_SPAWN_INTERVAL) * alpha
end

-- local function scoreBuy(customer: CustomerRuntimeState, shelf: ShelfState?, business: BusinessState): number
-- 	if not shelf or not shelf.gpuId then
-- 		return 0
-- 	end

-- 	local price = CustomerService._storeService.GetSelfSellPrice(business, shelf)
-- 	if not price or price > customer.profile.budget then
-- 		return 0
-- 	end

-- 	local demand = BusinessMath.CalculateCustomerDemand(
-- 		business.economy.marketDemand,
-- 		business.reputation,
-- 		customer.profile.priceSensitivity
-- 	)

-- 	local desiredBonus = if shelf.gpuId == customer.profile.preferredGpuId then 25 else 5
-- 	return 35 + desiredBonus + demand * 20 - business.store.checkoutQueueLength * 4
-- end

local function scoreSteal(customer: CustomerRuntimeState, business: BusinessState, observedScore: number): number
	local crowdDensity =
		math.clamp((business.store.checkoutQueueLength + Sift.Dictionary.count(business.customers)) / 20, 0, 2)
	local theftChance = BusinessMath.CalculateTheftChance(
		business.security.securityLevel,
		crowdDensity,
		customer.profile.theftRiskTolerance
	)
	return math.max(0, theftChance * 100 - observedScore * 85)
end

local function scoreLeave(customer: CustomerRuntimeState, business: BusinessState): number
	local impatience = math.max(0, customer.timeInState - customer.profile.patience * 0.1)
	return 10 + business.store.checkoutQueueLength * 5 + impatience * 8
end

local function chooseWeightedAction(
	buyScore: number,
	stealScore: number,
	leaveScore: number
): "Buying" | "Leaving" | "Stealing"
	local total = buyScore + stealScore + leaveScore
	if total <= 0 then
		return "Leaving"
	end

	local roll = math.random() * total
	if roll <= buyScore then
		return "Buying"
	elseif roll <= buyScore + stealScore then
		return "Stealing"
	else
		return "Leaving"
	end
end

function CustomerService:Configure(registry)
	self._registry = registry

	self._avatarService = registry.AvatarService
	self._storeService = registry.StoreService
	self._securityService = registry.SecurityService
	self._businessService = registry.BusinessService
end

function CustomerService:OnInit() end

function CustomerService:OnStart() end

function CustomerService.SpawnCustomer(business: BusinessState): CustomerRuntimeState
	local profile = createRandomProfile()
	local avatarUserId = CustomerService._avatarService.GetAvatarUserIdForOwner(business.ownerUserId)
	local customer: CustomerRuntimeState = {
		id = nextCustomerId(),
		state = "Entering",
		profile = profile,
		isSpawningPhysicalModel = false,
		targetShelfId = nil,
		desiredGpuId = profile.preferredGpuId,
		browseShelfIds = {},
		browseIndex = 0,
		cartShelfIds = {},
		purchasedGpuIds = {},
		remainingBudget = profile.budget,
		avatarUserId = avatarUserId,
		physicalModelName = nil,
		lastObservedScore = 0,
		lastDecisionAt = 0,
		timeInState = 0,
		satisfaction = 50,
	}

	business.customers[customer.id] = customer
	return customer
end

function CustomerService.SpawnPhysicalCustomerAsync(business: BusinessState, customer: CustomerRuntimeState)
	if customer.physicalModelName ~= nil or customer.isSpawningPhysicalModel then
		return
	end

	customer.isSpawningPhysicalModel = true

	local avatarUserId = customer.avatarUserId
		or CustomerService._avatarService.GetAvatarUserIdForOwner(business.ownerUserId)
	customer.avatarUserId = avatarUserId

	local modelName = `{business.id}_{customer.id}`
	local model = CustomerService._avatarService.CreateCustomerModelAsync(avatarUserId, modelName)
	customer.physicalModelName = model.Name

	customer.isSpawningPhysicalModel = false
	model:SetAttribute("BusinessId", business.id)
	model:SetAttribute("CustomerId", customer.id)
	model:SetAttribute("OwnerUserId", business.ownerUserId)
	model:SetAttribute("ShoppingGoal", customer.profile.shoppingGoal)
	model:SetAttribute("Budget", customer.profile.budget)
	model:PivotTo(WorldQueryService.GetSpawnCFrame(business.id, customer.id))
	model.Parent = WorldQueryService.GetOrCreateCustomerFolder()

	CollectionService:AddTag(model, WorldTags.Customer)
end

function CustomerService.GetCustomer(businessId: string, customerId: string): CustomerRuntimeState?
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return nil
	end
	return business.customers[customerId]
end

function CustomerService.BuildPhysicalBrowseRoute(businessId: string, customerId: string): { string }
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return {}
	end

	local customer = business.customers[customerId]
	if not customer then
		return {}
	end

	local route = {}
	local seen: { [string]: boolean } = {}

	for _, gpuId in customer.profile.wantedGpuIds do
		local shelf = CustomerService._storeService.FindShelfByGpuId(business, gpuId)
		if shelf and not seen[shelf.id] then
			table.insert(route, shelf.id)
			seen[shelf.id] = true
		end
	end

	local stockedShelfIds = {}
	for _, shelf in CustomerService._storeService.GetStockedShelves(business) do
		if not seen[shelf.id] then
			table.insert(stockedShelfIds, shelf.id)
		end
	end

	for _, shelfId in shuffle(stockedShelfIds) do
		if #route >= MAX_BROWSE_STOPS then
			break
		end
		table.insert(route, shelfId)
		seen[shelfId] = true
	end

	customer.browseShelfIds = route
	customer.browseIndex = 0
	customer.state = "Browsing"
	customer.timeInState = 0
	return route
end

function CustomerService.ConsiderBrowsedShelf(
	businessId: string,
	customerId: string,
	shelfId: string,
	customerModel: Model
): "Cart" | "Ignore" | "Steal" | "Leave"
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return "Leave"
	end

	local customer = business.customers[customerId]
	local shelf = CustomerService._storeService.GetShelf(business, shelfId)
	if not customer or not shelf or not shelf.gpuId or shelf.stockAmount <= 0 then
		return "Ignore"
	end

	customer.targetShelfId = shelfId
	customer.desiredGpuId = shelf.gpuId
	customer.browseIndex += 1
	customer.lastObservedScore = CustomerService._securityService.GetCustomerObservedScore(business.id, customerModel)
	customer.lastDecisionAt = os.clock()

	if #customer.cartShelfIds < customer.profile.maxPurchases and not contains(customer.cartShelfIds, shelfId) then
		local appeal = scoreShelfAppeal(customer, shelf, business)
		local buyThreshold = if contains(customer.profile.wantedGpuIds, shelf.gpuId) then 40 else 58
		local impuseRoll = math.random()

		if appeal >= buyThreshold or (appeal >= 35 and impuseRoll <= customer.profile.impulseBuyChance) then
			table.insert(customer.cartShelfIds, shelfId)
			customer.satisfaction = math.clamp(customer.satisfaction + 5, 0, 100)
			return "Cart"
		end
	end

	local stealScore = scoreSteal(customer, business, customer.lastObservedScore)
	local leaveScore = scoreLeave(customer, business)
	if
		#customer.cartShelfIds == 0
		and stealScore > leaveScore + 20
		and math.random() < customer.profile.theftRiskTolerance
	then
		customer.state = "Stealing"
		return "Steal"
	end

	if leaveScore > 70 and #customer.cartShelfIds == 0 then
		customer.state = "Leaving"
		return "Leave"
	end

	customer.satisfaction = math.clamp(customer.satisfaction - 1, 0, 100)
	return "Ignore"
end

function CustomerService.HasCartItems(businessId: string, customerId: string): boolean
	local customer = CustomerService.GetCustomer(businessId, customerId)
	return customer ~= nil and #customer.cartShelfIds > 0
end

function CustomerService.EnterPhysicalCheckoutQueue(businessId: string, customerId: string): boolean
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return false
	end

	local customer = business.customers[customerId]
	if not customer or #customer.cartShelfIds == 0 then
		return false
	end

	local slots = ensureCheckoutQueueSlots(business)
	if not slots[customerId] then
		local slot = 1
		while true do
			local occupied = false
			for _, occupiedSlot in slots do
				if occupiedSlot == slot then
					occupied = true
					break
				end
			end

			if not occupied then
				slots[customerId] = slot
				break
			end
			slot += 1
		end
	end

	customer.state = "Queueing"
	rebalanceCheckoutQueueSlotsByDistance(business)
	return true
end

function CustomerService.RebalancePhysicalCheckoutQueue(businessId: string)
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return
	end

	rebalanceCheckoutQueueSlotsByDistance(business)
end

function CustomerService.GetCheckoutQueueSlot(businessId: string, customerId: string): number
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return 1
	end

	return ensureCheckoutQueueSlots(business)[customerId] or 1
end

function CustomerService.GetCheckoutQueueJoinSlot(businessId: string): number
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return 1
	end

	return countCheckoutQueueSlots(business) + 1
end

function CustomerService.LeavePhysicalCheckoutQueue(businessId: string, customerId: string)
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return
	end

	ensureCheckoutQueueSlots(business)[customerId] = nil
	compactCheckoutQueueSlots(business)
end

function CustomerService.ChoosePhysicalBrowseShelf(businessId: string, customerId: string): string?
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return nil
	end

	local customer = business.customers[customerId]
	if not customer then
		return nil
	end

	local targetShelf =
		CustomerService._storeService.FindBestShelfForCustomer(business, customer.profile.preferredGpuId)
	customer.targetShelfId = if targetShelf then targetShelf.id else nil
	customer.desiredGpuId = if targetShelf then targetShelf.gpuId else customer.profile.preferredGpuId
	customer.state = "Browsing"
	customer.timeInState = 0
	return customer.targetShelfId
end

function CustomerService.ThinkForCustomer(
	business: BusinessState,
	customer: CustomerRuntimeState,
	observedScore: number?
): CustomerAction
	local targetShelf =
		CustomerService._storeService.FindBestShelfForCustomer(business, customer.profile.preferredGpuId)
	customer.targetShelfId = if targetShelf then targetShelf.id else nil
	customer.desiredGpuId = if targetShelf then targetShelf.gpuId else customer.profile.preferredGpuId
	customer.lastObservedScore = observedScore or customer.lastObservedScore
	customer.lastDecisionAt = os.clock()

	local foundDesiredGpu = targetShelf ~= nil
		and targetShelf.gpuId ~= nil
		and contains(customer.profile.wantedGpuIds, targetShelf.gpuId)
	customer.satisfaction = math.clamp(
		customer.satisfaction
			+ BusinessMath.CalculateCustomerSatisfactionDelta(
				business.store.checkoutQueueLength,
				foundDesiredGpu,
				if targetShelf then targetShelf.priceMultiplier else 1
			),
		0,
		100
	)

	local buyScore = if targetShelf then scoreShelfAppeal(customer, targetShelf, business) else 0
	local stealScore = if targetShelf then scoreSteal(customer, business, customer.lastObservedScore) else 0
	local leaveScore = scoreLeave(customer, business)
	customer.state = chooseWeightedAction(buyScore, stealScore, leaveScore)
	customer.timeInState = 0

	if customer.state == "Buying" then
		if targetShelf then
			customer.cartShelfIds = { targetShelf.id }
		end
		return "Buy"
	elseif customer.state == "Stealing" then
		return "Steal"
	else
		return "Leave"
	end
end

function CustomerService.DecidePhysicalCustomerAction(
	businessId: string,
	customerId: string,
	customerModel: Model
): (CustomerAction, string?)
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return "Leave", nil
	end

	local customer = business.customers[customerId]
	if not customer then
		return "Leave", nil
	end

	local observedScore = CustomerService._securityService.GetCustomerObservedScore(business.id, customerModel)
	local action = CustomerService.ThinkForCustomer(business, customer, observedScore)
	return action, customer.targetShelfId
end

function CustomerService.TryCompletePhysicalPurchase(businessId: string, customerId: string): boolean
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return false
	end

	local customer = business.customers[customerId]
	if not customer or (customer.state ~= "Queueing" and customer.state ~= "Buying") or #customer.cartShelfIds == 0 then
		return false
	end

	customer.state = "Buying"
	local availableBudget = customer.profile.budget
	local purchasedAny = false

	for _, shelfId in customer.cartShelfIds do
		local canPurchase, _, price =
			CustomerService._storeService.CanPurchaseFromShelf(business, shelfId, availableBudget)
		if canPurchase and price then
			local gpuId = CustomerService._storeService.RemoveStockAfterPurchase(business, shelfId)
			if gpuId then
				CustomerService._businessService.AddMoney(business.id, price, "PhysicalGpuSale")
				table.insert(customer.purchasedGpuIds, gpuId)
				availableBudget -= price
				purchasedAny = true
			end
		end
	end

	customer.remainingBudget = math.max(0, availableBudget)
	customer.cartShelfIds = {}
	CustomerService.LeavePhysicalCheckoutQueue(businessId, customerId)

	if purchasedAny then
		customer.satisfaction = math.clamp(customer.satisfaction + 10 + #customer.purchasedGpuIds * 4, 0, 100)
	else
		customer.satisfaction = math.clamp(customer.satisfaction - 12, 0, 100)
	end

	customer.state = "Leaving"
	customer.timeInState = 0
	return purchasedAny
end

function CustomerService.TryStartPhysicalTheft(businessId: string, customerId: string, customerModel: Model): boolean
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return false
	end

	local customer = business.customers[customerId]
	if not customer or customer.state ~= "Stealing" or not customer.targetShelfId then
		return false
	end

	local observedScore = CustomerService._securityService.GetCustomerObservedScore(business.id, customerModel)
	customer.lastObservedScore = observedScore

	local detected =
		CustomerService._securityService.ResolvePhysicalTheftAttempt(business, customer, customerModel, observedScore)
	if not detected then
		local gpuId = CustomerService._storeService.RemoveStockAfterPurchase(business, customer.targetShelfId)
		if gpuId then
			table.insert(customer.purchasedGpuIds, gpuId)
		end
		customer.satisfaction = math.clamp(customer.satisfaction - 20, 0, 100)
		customer.state = "Leaving"
	end

	return not detected
end

function CustomerService.DespawnPhysicalCustomer(businessId: string, customerId: string)
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return
	end

	local customer = business.customers[customerId]
	if not customer then
		return
	end

	business.reputation =
		math.clamp(business.reputation + BusinessMath.CalculateReputationDelta(customer.satisfaction, false), 0, 100)
	business.security.activeThefts[customerId] = nil
	CustomerService.LeavePhysicalCheckoutQueue(businessId, customerId)
	business.customers[customerId] = nil
end

function CustomerService.UpdateCustomers(business: BusinessState, deltaSeconds: number)
	local demand = BusinessMath.CalculateCustomerDemand(business.economy.marketDemand, business.reputation, 0.35)

	if not business.customerSpawnBudget then
		business.customerSpawnBudget = 0
	end

	if business.store.open then
		local activeCustomers = countCustomers(business)
		local targetCustomers = getTargetCustomers(demand)

		if activeCustomers < targetCustomers then
			local spawnInterval = getSpawnInterval(demand)

			business.customerSpawnBudget += deltaSeconds / spawnInterval

			if business.customerSpawnBudget >= 1 then
				business.customerSpawnBudget -= 1

				local customer = CustomerService.SpawnCustomer(business)
				task.spawn(CustomerService.SpawnPhysicalCustomerAsync, business, customer)
			end
		else
			business.customerSpawnBudget = math.min(business.customerSpawnBudget, 1)
		end
	else
		business.customerSpawnBudget = 0
	end

	for customerId, customer in business.customers do
		customer.timeInState += deltaSeconds

		if customer.physicalModelName == nil and not customer.isSpawningPhysicalModel then
			customer.isSpawningPhysicalModel = true
			task.spawn(CustomerService.SpawnPhysicalCustomerAsync, business, customer)
		end

		if customer.state == "Leaving" and customer.timeInState >= 20 then
			business.customers[customerId] = nil
		end
	end
end

return CustomerService
