--!strict
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AccountStore = require(script.Parent.Parent.Stores.AccountStore)
local AccountDataStore = require(script.Parent.Parent.Accounts.Store)
local StoreNavigationService = require(script.Parent.StoreNavigationService)
local WorldQueryService = require(script.Parent.WorldQueryService)
local Sift = require(ReplicatedStorage.Packages.Sift)
local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)
local Objects = require(ReplicatedStorage.Shared.Util.Objects)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

type CustomerAction = "Buy" | "Steal" | "Leave"
type BrowseShelfResult = "Cart" | "Ignore" | "Steal" | "Leave"
type CustomerShelfEmotion =
	"Bought"
	| "BoughtWanted"
	| "BoughtBargain"
	| "WantedGpu"
	| "GoodPrice"
	| "OutOfStock"
	| "TooExpensive"
	| "NotInterested"
	| "Leaving"
	| "Stealing"

type BusinessState = BusinessTypes.BusinessState
type Account = AccountTypes.Account
type CustomerMemory = AccountTypes.CustomerMemory
type CustomerProfile = BusinessTypes.CustomerProfile
type CustomerReview = AccountTypes.CustomerReview
type CustomerReviewReason = BusinessTypes.CustomerReviewReason
type CustomerReviewSentiment = AccountTypes.CustomerReviewSentiment
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
	TryCompletePhysicalPurchase: (businessId: string, customerId: string, paymentMethod: ("Cash" | "Card")?) -> boolean,
	TryStartPhysicalTheft: (businessId: string, customerId: string, customerModel: Model) -> boolean,
	DespawnPhysicalCustomer: (businessId: string, customerId: string) -> (),
	ChoosePhysicalBrowseShelf: (businessId: string, customerId: string) -> string?,
	BuildPhysicalBrowseRoute: (businessId: string, customerId: string) -> { string },
	ConsiderBrowsedShelf: (
		businessId: string,
		customerId: string,
		shelfId: string,
		customerModel: Model
	) -> (BrowseShelfResult, CustomerShelfEmotion?),
	HasCartItems: (businessId: string, customerId: string) -> boolean,
	EnterPhysicalCheckoutQueue: (businessId: string, customerId: string) -> boolean,
	RebalancePhysicalCheckoutQueue: (businessId: string) -> (),
	GetCheckoutQueueSlot: (businessId: string, customerId: string) -> number,
	GetFrontCheckoutCustomerId: (businessId: string) -> string?,
	GetCheckoutQueueJoinSlot: (businessId: string) -> number,
	LeavePhysicalCheckoutQueue: (businessId: string, customerId: string) -> (),
	AbandonPhysicalCheckoutQueue: (businessId: string, customerId: string) -> (),
}

local CustomerService = {} :: CustomerServiceType

CustomerService.Name = "CustomerService"
CustomerService.Priority = 0
CustomerService.Dependencies = { "StoreService", "AvatarService", "SecurityService" }
CustomerService.Disabled = false

local customerCounter = 0

local GPU_CHOICES = { "fx_450", "fx_480", "fx_550", "fx_5500", "fx_6500", "fx_6600" }
local SHOPPING_GOALS: { ShoppingGoal } = { "Gaming", "Mining", "Budget", "Premium" }
local MAX_BROWSE_STOPS = 6

local MIN_SPAWN_INTERVAL = 15
local MAX_SPAWN_INTERVAL = 30
local MAX_ACTIVE_CUSTOMERS = 3
local MAX_SAVED_CUSTOMER_REVIEWS = 100
local RETURNING_CUSTOMER_CHANCE = 0.35

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
	fx_6600 = {
		Gaming = 1,
		Mining = 1,
		Budget = 0.15,
		Premium = 1,
	},
}

local GOOD_PRICE_RATIO = 0.92
local HIGH_PRICE_RATIO = 1.18

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

local function getAvatarMemoryKey(avatarUserId: number): string
	return tostring(math.floor(avatarUserId))
end

local function getOwnerPlayer(business: BusinessState): Player?
	return Players:GetPlayerByUserId(business.ownerUserId)
end

local function getOwnerAccount(business: BusinessState): Account?
	local player = getOwnerPlayer(business)
	if not player then
		return nil
	end

	return AccountStore.getAccount(player.Name)
end

local function getCustomerReviews(account: Account): { CustomerReview }
	local accountData = account :: any
	if type(accountData.CustomerReviews) == "table" then
		return accountData.CustomerReviews
	end

	return {}
end

local function getCustomerMemories(account: Account): { [string]: CustomerMemory }
	local accountData = account :: any
	if type(accountData.CustomerMemoriesByAvatarUserId) == "table" then
		return accountData.CustomerMemoriesByAvatarUserId
	end

	return {}
end

local function getGpuIdsByBasePrice(descending: boolean): { string }
	local gpuIds = table.clone(GPU_CHOICES)
	table.sort(gpuIds, function(left, right)
		local leftPrice = CustomerService._storeService.GetBaseGpuPrice(left)
		local rightPrice = CustomerService._storeService.GetBaseGpuPrice(right)
		if descending then
			return leftPrice > rightPrice
		end
		return leftPrice < rightPrice
	end)
	return gpuIds
end

local function chooseReturningCustomerMemory(business: BusinessState): CustomerMemory?
	if math.random() > RETURNING_CUSTOMER_CHANCE then
		return nil
	end

	local account = getOwnerAccount(business)
	if not account then
		return nil
	end

	local memories = getCustomerMemories(account)
	local weightedMemories: { { memory: CustomerMemory, weight: number } } = {}
	local totalWeight = 0

	for _, memory in memories do
		local weight = 0.75

		if memory.lastSentiment == "Positive" then
			weight += 1.25
		elseif memory.lastSentiment == "Angry" then
			weight += 0.55
		end

		if memory.lastReason == "GoodPrices" or memory.lastReason == "FoundWantedGpu" then
			weight += 1
		elseif memory.lastReason == "StoleExpensiveGpu" then
			weight += 0.75
		end

		weight += math.clamp(memory.visits * 0.08, 0, 0.8)
		totalWeight += weight
		table.insert(weightedMemories, {
			memory = memory,
			weight = weight,
		})
	end

	if totalWeight <= 0 then
		return nil
	end

	local roll = math.random() * totalWeight
	for _, entry in weightedMemories do
		roll -= entry.weight
		if roll <= 0 then
			return entry.memory
		end
	end

	return nil
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

local function applyReturningCustomerMemory(profile: CustomerProfile, memory: CustomerMemory)
	if memory.lastSentiment == "Positive" then
		profile.budget = math.floor(profile.budget * (1.1 + math.random() * 0.25))
		profile.maxPurchases = math.clamp(profile.maxPurchases + 1, 1, 4)
		profile.impulseBuyChance = math.clamp(profile.impulseBuyChance + 0.12, 0, 0.75)

		if memory.lastReason == "GoodPrices" then
			profile.priceSensitivity = math.clamp(profile.priceSensitivity * 0.65, 0, 1)
		elseif memory.lastReason == "FoundWantedGpu" then
			profile.patience = math.clamp(profile.patience + 20, 20, 140)
		end
	elseif memory.lastSentiment == "Angry" then
		local expensiveGpuIds = getGpuIdsByBasePrice(true)
		local wantedCount = math.min(2, #expensiveGpuIds)
		local wantedGpuIds: { string } = {}

		for index = 1, wantedCount do
			table.insert(wantedGpuIds, expensiveGpuIds[index])
		end

		profile.shoppingGoal = "Premium"
		profile.wantedGpuIds = wantedGpuIds
		profile.preferredGpuId = wantedGpuIds[1]
		profile.budget = math.floor(profile.budget * 0.7)
		profile.patience = math.clamp(profile.patience * 0.65, 15, 90)
		profile.priceSensitivity = math.clamp(profile.priceSensitivity + 0.3, 0, 1)
		profile.theftRiskTolerance = math.clamp(profile.theftRiskTolerance + 0.35, 0, 1)
		profile.impulseBuyChance = math.clamp(profile.impulseBuyChance - 0.12, 0.02, 0.5)
	elseif memory.lastSentiment == "Neutral" then
		profile.patience = math.clamp(profile.patience + 8, 20, 130)
		profile.impulseBuyChance = math.clamp(profile.impulseBuyChance + 0.04, 0, 0.65)
	end
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
	for index, shelfId in customer.cartShelfIds do
		local shelf = CustomerService._storeService.GetShelf(business, shelfId)
		local gpuId = customer.cartGpuIds[index] or (if shelf then shelf.gpuId else nil)
		if gpuId then
			total += BusinessMath.CalculateGpuSellPrice(
				CustomerService._storeService.GetBaseGpuPrice(gpuId),
				business.reputation,
				if shelf then shelf.priceMultiplier else 1
			)
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

local function getShelfPriceRatio(business: BusinessState, shelf: ShelfState): number?
	if not shelf.gpuId then
		return nil
	end

	local price = CustomerService._storeService.GetShelfSellPrice(business, shelf)
	if not price then
		return nil
	end

	local basePrice = CustomerService._storeService.GetBaseGpuPrice(shelf.gpuId)
	return price / math.max(1, basePrice)
end

local function chooseShelfEmotion(
	customer: CustomerRuntimeState,
	shelf: ShelfState,
	business: BusinessState
): CustomerShelfEmotion?
	if not shelf.gpuId then
		return nil
	end

	local price = CustomerService._storeService.GetShelfSellPrice(business, shelf)
	if price and price > getAvailableCartBudget(business, customer) then
		return "TooExpensive"
	end

	if contains(customer.profile.wantedGpuIds, shelf.gpuId) then
		return "WantedGpu"
	end

	local priceRatio = getShelfPriceRatio(business, shelf)
	if priceRatio and priceRatio <= GOOD_PRICE_RATIO then
		return "GoodPrice"
	elseif priceRatio and priceRatio >= HIGH_PRICE_RATIO then
		return "TooExpensive"
	end

	return nil
end

local function choosePurchasedEmotion(
	customer: CustomerRuntimeState,
	shelf: ShelfState,
	business: BusinessState
): CustomerShelfEmotion
	if shelf.gpuId and contains(customer.profile.wantedGpuIds, shelf.gpuId) then
		return "BoughtWanted"
	end

	local priceRatio = getShelfPriceRatio(business, shelf)
	if priceRatio and priceRatio <= GOOD_PRICE_RATIO then
		return "BoughtBargain"
	end

	return "Bought"
end

local REVIEW_COMMENTS: { [CustomerReviewReason]: { [CustomerReviewSentiment]: { string } } } = {
	GoodPrices = {
		Positive = {
			"The prices were fair and I left with more room in my budget than expected.",
			"I came in for a deal and the store actually delivered.",
			"Good GPU prices made it easy to buy without second guessing it.",
		},
		Neutral = {
			"The prices were decent, but the visit did not fully stand out.",
			"Some prices looked good, though I still compared everything carefully.",
		},
		Angry = {
			"I noticed one good price, but the rest of the visit still annoyed me.",
		},
	},
	FoundWantedGpu = {
		Positive = {
			"They had the GPU I wanted in stock, so I was happy to spend here.",
			"I found exactly what I came for and checkout was worth it.",
			"The selection matched my list, which made the trip feel worthwhile.",
		},
		Neutral = {
			"They had something from my list, but the visit was only okay.",
		},
		Angry = {
			"I saw what I wanted, but the visit still left a bad impression.",
		},
	},
	HighPrices = {
		Positive = {
			"The visit worked out, but a few prices were higher than I expected.",
		},
		Neutral = {
			"The GPUs looked good, but the prices made me hesitate.",
			"I might come back, but only if the prices cool down.",
		},
		Angry = {
			"Everything I wanted felt overpriced, especially the expensive GPUs.",
			"The prices pushed me away and made the premium cards feel unfair.",
			"I left annoyed because the good GPUs were priced too high.",
		},
	},
	OutOfStock = {
		Positive = {
			"The store was good overall, but some shelves were already empty.",
		},
		Neutral = {
			"A few items I checked were out of stock, so the trip was mixed.",
			"I might return if the shelves are better stocked next time.",
		},
		Angry = {
			"The GPUs I cared about were sold out, so the visit felt wasted.",
			"I came for specific cards and kept finding empty shelves.",
		},
	},
	LongQueue = {
		Positive = {
			"The purchase was worth it, even with a bit of waiting.",
		},
		Neutral = {
			"The queue slowed the visit down more than I liked.",
		},
		Angry = {
			"The checkout wait made the whole store feel frustrating.",
		},
	},
	BadSelection = {
		Positive = {
			"I still found something useful, though the selection could be better.",
		},
		Neutral = {
			"The selection was not really what I came in for.",
			"I browsed for a while but did not see enough that matched my needs.",
		},
		Angry = {
			"The selection missed what I wanted and I left irritated.",
			"I could not find the GPUs I came for, so I do not trust this store yet.",
		},
	},
	StoleExpensiveGpu = {
		Positive = {
			"The expensive GPUs were tempting, but the store still had strong options.",
		},
		Neutral = {
			"The premium cards stood out more than anything else in the store.",
		},
		Angry = {
			"The expensive GPUs were too tempting after a bad visit.",
			"I left angry and the premium GPUs were the only thing I cared about.",
			"The visit pushed me toward the high-end cards for the wrong reasons.",
		},
	},
	General = {
		Positive = {
			"The store visit went smoothly and I would come back.",
			"I had a good visit and the store felt worth another trip.",
		},
		Neutral = {
			"The visit was fine, but nothing really stood out.",
			"I might come back, but I am not excited about it yet.",
		},
		Angry = {
			"The visit left a bad impression and I would think twice before returning.",
			"I left frustrated and expected better from this store.",
		},
	},
}

local function addReviewReason(customer: CustomerRuntimeState, reason: CustomerReviewReason, score: number)
	customer.reviewReasonScores[reason] = (customer.reviewReasonScores[reason] or 0) + score
end

local function chooseReviewReason(customer: CustomerRuntimeState): CustomerReviewReason
	local bestReason: CustomerReviewReason = "General"
	local bestScore = 0

	for reason, score in customer.reviewReasonScores do
		if score > bestScore then
			bestReason = reason
			bestScore = score
		end
	end

	if bestScore <= 0 and #customer.purchasedGpuIds == 0 and #customer.stolenGpuIds == 0 then
		return "BadSelection"
	end

	return bestReason
end

local function getReviewSentiment(customer: CustomerRuntimeState): CustomerReviewSentiment
	if customer.satisfaction >= 70 then
		return "Positive"
	elseif customer.satisfaction <= 35 then
		return "Angry"
	end

	return "Neutral"
end

local function getReviewStars(customer: CustomerRuntimeState): number
	if customer.satisfaction >= 85 then
		return 5
	elseif customer.satisfaction >= 68 then
		return 4
	elseif customer.satisfaction >= 45 then
		return 3
	elseif customer.satisfaction >= 25 then
		return 2
	end

	return 1
end

local function generateReviewComment(
	sentiment: CustomerReviewSentiment,
	reason: CustomerReviewReason,
	customer: CustomerRuntimeState
): string
	local commentsBySentiment = REVIEW_COMMENTS[reason] or REVIEW_COMMENTS.General
	local comments = commentsBySentiment[sentiment] or REVIEW_COMMENTS.General[sentiment]
	local comment = comments[math.random(1, #comments)]

	if customer.returningCustomer and customer.memoryReason == reason then
		return `{comment} This matched what I remembered from last time.`
	end

	return comment
end

local function createCustomerReview(customer: CustomerRuntimeState): CustomerReview
	local sentiment = getReviewSentiment(customer)
	local reason = chooseReviewReason(customer)

	return {
		id = `{customer.id}_{os.time()}`,
		avatarUserId = customer.avatarUserId or 0,
		customerId = customer.id,
		createdAt = os.time(),
		sentiment = sentiment,
		stars = getReviewStars(customer),
		comment = generateReviewComment(sentiment, reason, customer),
		reason = reason,
		satisfaction = customer.satisfaction,
		shoppingGoal = customer.profile.shoppingGoal,
		purchasedGpuIds = table.clone(customer.purchasedGpuIds),
		stolenGpuIds = table.clone(customer.stolenGpuIds),
		wantedGpuIds = table.clone(customer.profile.wantedGpuIds),
		spentAmount = customer.spentAmount,
		stolenValue = customer.stolenValue,
	}
end

local function updateCustomerMemory(memory: CustomerMemory?, review: CustomerReview): CustomerMemory
	local updated = if memory
		then table.clone(memory)
		else nil or {
			avatarUserId = review.avatarUserId,
			visits = 0,
			lastVisitedAt = 0,
			lastSentiment = review.sentiment,
			lastStars = review.stars,
			lastReason = review.reason,
			lastComment = review.comment,
			totalStars = 0,
			positiveVisits = 0,
			neutralVisits = 0,
			angryVisits = 0,
			purchaseCount = 0,
			theftCount = 0,
			totalSpent = 0,
			totalStolenValue = 0,
		}

	updated.visits += 1
	updated.lastVisitedAt = review.createdAt
	updated.lastSentiment = review.sentiment
	updated.lastStars = review.stars
	updated.lastReason = review.reason
	updated.lastComment = review.comment
	updated.totalStars += review.stars
	updated.purchaseCount += #review.purchasedGpuIds
	updated.theftCount += #review.stolenGpuIds
	updated.totalSpent += review.spentAmount
	updated.totalStolenValue += review.stolenValue

	if review.sentiment == "Positive" then
		updated.positiveVisits += 1
	elseif review.sentiment == "Angry" then
		updated.angryVisits += 1
	else
		updated.neutralVisits += 1
	end

	return updated
end

local function saveCustomerReview(business: BusinessState, customer: CustomerRuntimeState)
	if customer.reviewSaved or not customer.avatarUserId then
		return
	end

	local player = getOwnerPlayer(business)
	if not player then
		return
	end

	local review = createCustomerReview(customer)
	local memoryKey = getAvatarMemoryKey(review.avatarUserId)

	AccountDataStore:updateImmutable(player, function(account: Account)
		local reviews = table.clone(getCustomerReviews(account))
		table.insert(reviews, 1, review)

		while #reviews > MAX_SAVED_CUSTOMER_REVIEWS do
			table.remove(reviews)
		end

		local memories = table.clone(getCustomerMemories(account))
		memories[memoryKey] = updateCustomerMemory(memories[memoryKey], review)

		return Objects.join(account, {
			CustomerReviews = reviews,
			CustomerMemoriesByAvatarUserId = memories,
		})
	end)

	customer.reviewSaved = true
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

local function getRouteDistance(fromPosition: Vector3, waypoints: { CFrame }): number
	local distance = 0
	local cursor = fromPosition

	for _, waypoint in waypoints do
		distance += getFlatDistance(cursor, waypoint.Position)
		cursor = waypoint.Position
	end

	return distance
end

local function getCheckoutSlotTravelDistance(businessId: string, fromPosition: Vector3, queueSlot: number): number
	local checkoutCFrame = WorldQueryService.GetCheckoutQueueCFrame(businessId, queueSlot)
	local route = StoreNavigationService.FindRouteToCheckout(businessId, fromPosition, checkoutCFrame)

	if route and #route > 0 then
		return getRouteDistance(fromPosition, route)
	end

	return getFlatDistance(fromPosition, checkoutCFrame.Position)
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

local function assignCheckoutQueueSlotsByTravelDistance(
	business: BusinessState,
	entries: { CheckoutQueueEntry }
): { CheckoutQueueEntry }
	for _, entry in entries do
		local position = getCustomerPosition(business.id, entry.customerId)
		entry.distance = if position then getCheckoutSlotTravelDistance(business.id, position, 1) else math.huge
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

	return entries
end

local function rebalanceCheckoutQueueSlotsByDistance(business: BusinessState)
	local entries: { CheckoutQueueEntry } = {}

	for customerId, slot in ensureCheckoutQueueSlots(business) do
		table.insert(entries, {
			customerId = customerId,
			slot = slot,
		})
	end

	applyCheckoutQueueEntries(business, assignCheckoutQueueSlotsByTravelDistance(business, entries))
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

local function publishBusiness(business: BusinessState)
	if CustomerService._businessService and CustomerService._businessService.PublishBusiness then
		CustomerService._businessService.PublishBusiness(business)
	end
end

function CustomerService.SpawnCustomer(business: BusinessState): CustomerRuntimeState
	local profile = createRandomProfile()
	local memory = chooseReturningCustomerMemory(business)
	local avatarUserId: number

	if memory then
		avatarUserId = memory.avatarUserId
		applyReturningCustomerMemory(profile, memory)
	else
		avatarUserId = CustomerService._avatarService.GetAvatarUserIdForOwner(business.ownerUserId)
	end

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
		cartGpuIds = {},
		purchasedGpuIds = {},
		stolenGpuIds = {},
		remainingBudget = profile.budget,
		spentAmount = 0,
		stolenValue = 0,
		avatarUserId = avatarUserId,
		returningCustomer = memory ~= nil,
		memoryReason = if memory then memory.lastReason else nil,
		reviewReasonScores = {},
		reviewSaved = false,
		physicalModelName = nil,
		lastObservedScore = 0,
		lastDecisionAt = 0,
		timeInState = 0,
		satisfaction = 50,
	}

	business.customers[customer.id] = customer
	publishBusiness(business)
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
	model.Parent = workspace:WaitForChild("ActiveCustomers")

	CollectionService:AddTag(model, WorldTags.Customer)
	publishBusiness(business)
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
	publishBusiness(business)
	return route
end

function CustomerService.ConsiderBrowsedShelf(
	businessId: string,
	customerId: string,
	shelfId: string,
	customerModel: Model
): (BrowseShelfResult, CustomerShelfEmotion?)
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return "Leave", "Leaving"
	end

	local customer = business.customers[customerId]
	local shelf = CustomerService._storeService.GetShelf(business, shelfId)
	if not customer or not shelf then
		return "Ignore", nil
	end

	if not shelf.gpuId then
		return "Ignore", "NotInterested"
	end

	if shelf.stockAmount <= 0 then
		customer.targetShelfId = shelfId
		customer.desiredGpuId = shelf.gpuId
		customer.browseIndex += 1
		customer.lastDecisionAt = os.clock()
		customer.satisfaction = math.clamp(customer.satisfaction - 3, 0, 100)
		addReviewReason(customer, "OutOfStock", 4)
		publishBusiness(business)
		return "Ignore", "OutOfStock"
	end

	customer.targetShelfId = shelfId
	customer.desiredGpuId = shelf.gpuId
	customer.browseIndex += 1
	customer.lastObservedScore = CustomerService._securityService.GetCustomerObservedScore(business.id, customerModel)
	customer.lastDecisionAt = os.clock()

	local shelfEmotion = chooseShelfEmotion(customer, shelf, business)
	if shelfEmotion == "GoodPrice" then
		addReviewReason(customer, "GoodPrices", 2)
	elseif shelfEmotion == "WantedGpu" then
		addReviewReason(customer, "FoundWantedGpu", 2)
	elseif shelfEmotion == "TooExpensive" then
		addReviewReason(customer, "HighPrices", 3)
	end

	if #customer.cartShelfIds < customer.profile.maxPurchases and not contains(customer.cartShelfIds, shelfId) then
		local appeal = scoreShelfAppeal(customer, shelf, business)
		local buyThreshold = if contains(customer.profile.wantedGpuIds, shelf.gpuId) then 40 else 58
		local impulseRoll = math.random()

		if appeal >= buyThreshold or (appeal >= 35 and impulseRoll <= customer.profile.impulseBuyChance) then
			local purchasedEmotion = choosePurchasedEmotion(customer, shelf, business)
			local cartGpuId = CustomerService._storeService.RemoveStockAfterPurchase(business, shelfId)
			if cartGpuId then
				table.insert(customer.cartShelfIds, shelfId)
				table.insert(customer.cartGpuIds, cartGpuId)
				customer.satisfaction = math.clamp(customer.satisfaction + 5, 0, 100)
				if purchasedEmotion == "BoughtBargain" then
					addReviewReason(customer, "GoodPrices", 5)
				elseif purchasedEmotion == "BoughtWanted" then
					addReviewReason(customer, "FoundWantedGpu", 5)
				else
					addReviewReason(customer, "General", 1)
				end
				publishBusiness(business)
				return "Cart", purchasedEmotion
			end
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
		addReviewReason(customer, "StoleExpensiveGpu", 5)
		publishBusiness(business)
		return "Steal", "Stealing"
	end

	if leaveScore > 70 and #customer.cartShelfIds == 0 then
		customer.state = "Leaving"
		addReviewReason(customer, "BadSelection", 3)
		publishBusiness(business)
		return "Leave", "Leaving"
	end

	customer.satisfaction = math.clamp(customer.satisfaction - 1, 0, 100)
	if shelfEmotion == nil then
		addReviewReason(customer, "BadSelection", 1)
	end
	publishBusiness(business)
	return "Ignore", shelfEmotion or "NotInterested"
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
	publishBusiness(business)
	return true
end

function CustomerService.RebalancePhysicalCheckoutQueue(businessId: string)
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return
	end

	rebalanceCheckoutQueueSlotsByDistance(business)
	publishBusiness(business)
end

function CustomerService.GetCheckoutQueueSlot(businessId: string, customerId: string): number
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return 1
	end

	return ensureCheckoutQueueSlots(business)[customerId] or 1
end

function CustomerService.GetFrontCheckoutCustomerId(businessId: string): string?
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return nil
	end

	for customerId, queueSlot in ensureCheckoutQueueSlots(business) do
		if queueSlot == 1 then
			return customerId
		end
	end

	return nil
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
	publishBusiness(business)
end

function CustomerService.AbandonPhysicalCheckoutQueue(businessId: string, customerId: string)
	local business = CustomerService._registry.BusinessService.GetBusiness(businessId)
	if not business then
		return
	end

	local customer = business.customers[customerId]
	if customer then
		customer.state = "Leaving"
		customer.timeInState = 0
		customer.satisfaction = math.clamp(customer.satisfaction - 12, 0, 100)
		addReviewReason(customer, "LongQueue", 8)
	end

	ensureCheckoutQueueSlots(business)[customerId] = nil
	compactCheckoutQueueSlots(business)
	publishBusiness(business)
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
	publishBusiness(business)
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
	if foundDesiredGpu then
		addReviewReason(customer, "FoundWantedGpu", 3)
	end
	if targetShelf then
		local priceRatio = getShelfPriceRatio(business, targetShelf)
		if priceRatio and priceRatio <= GOOD_PRICE_RATIO then
			addReviewReason(customer, "GoodPrices", 2)
		elseif priceRatio and priceRatio >= HIGH_PRICE_RATIO then
			addReviewReason(customer, "HighPrices", 2)
		end
	end
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
			addReviewReason(customer, "General", 1)
		end
		return "Buy"
	elseif customer.state == "Stealing" then
		addReviewReason(customer, "StoleExpensiveGpu", 4)
		return "Steal"
	else
		addReviewReason(customer, "BadSelection", 2)
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
	publishBusiness(business)
	return action, customer.targetShelfId
end

function CustomerService.TryCompletePhysicalPurchase(
	businessId: string,
	customerId: string,
	paymentMethod: "Cash" | "Card"?
): boolean
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
	local spentTotal = 0

	for index, shelfId in customer.cartShelfIds do
		local shelf = CustomerService._storeService.GetShelf(business, shelfId)
		local gpuId = customer.cartGpuIds[index] or (if shelf then shelf.gpuId else nil)
		if gpuId then
			local price = BusinessMath.CalculateGpuSellPrice(
				CustomerService._storeService.GetBaseGpuPrice(gpuId),
				business.reputation,
				if shelf then shelf.priceMultiplier else 1
			)
			if price and price <= availableBudget then
				table.insert(customer.purchasedGpuIds, gpuId)
				availableBudget -= price
				customer.spentAmount += price
				spentTotal += price
				purchasedAny = true
			end
		end
	end

	if spentTotal > 0 then
		if paymentMethod == "Card" then
			CustomerService._businessService.AddPendingCardPayout(business.id, spentTotal, "PhysicalGpuCardSale")
		else
			CustomerService._businessService.AddMoney(business.id, spentTotal, "PhysicalGpuCashSale")
		end
	end

	customer.remainingBudget = math.max(0, availableBudget)
	if business.store.checkoutQueueLength >= 3 then
		addReviewReason(customer, "LongQueue", business.store.checkoutQueueLength)
	end

	customer.cartShelfIds = {}
	customer.cartGpuIds = {}
	CustomerService.LeavePhysicalCheckoutQueue(businessId, customerId)

	if purchasedAny then
		customer.satisfaction = math.clamp(customer.satisfaction + 10 + #customer.purchasedGpuIds * 4, 0, 100)
	else
		customer.satisfaction = math.clamp(customer.satisfaction - 12, 0, 100)
		addReviewReason(customer, "BadSelection", 4)
	end

	customer.state = "Leaving"
	customer.timeInState = 0
	publishBusiness(business)
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
		local shelf = CustomerService._storeService.GetShelf(business, customer.targetShelfId)
		local gpuId = CustomerService._storeService.RemoveStockAfterPurchase(business, customer.targetShelfId)
		if gpuId then
			table.insert(customer.stolenGpuIds, gpuId)
			customer.stolenValue += BusinessMath.CalculateGpuSellPrice(
				CustomerService._storeService.GetBaseGpuPrice(gpuId),
				business.reputation,
				if shelf then shelf.priceMultiplier else 1
			)
			addReviewReason(customer, "StoleExpensiveGpu", 8)
		end
		customer.satisfaction = math.clamp(customer.satisfaction - 20, 0, 100)
		customer.state = "Leaving"
	end

	publishBusiness(business)
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
	saveCustomerReview(business, customer)
	business.security.activeThefts[customerId] = nil
	CustomerService.LeavePhysicalCheckoutQueue(businessId, customerId)
	business.customers[customerId] = nil
	publishBusiness(business)
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
			saveCustomerReview(business, customer)
			business.customers[customerId] = nil
		end
	end
	publishBusiness(business)
end

return CustomerService
