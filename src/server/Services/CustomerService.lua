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
    ChoosePhysicalBrowseShelf: (businessId: string, customerId: string) -> string?
}

local CustomerService = {} :: CustomerServiceType

CustomerService.Name = "CustomerService"
CustomerService.Priority = 0
CustomerService.Dependencies = { "StoreService", "AvatarService", "SecurityService" }
CustomerService.Disabled = false

local customerCounter = 0

local GPU_CHOICES = { "starter_gpu", "mid_gpu", "high_gpu" }
local MAX_ACTIVE_CUSTOMERS = 24

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

local function createRandomProfile(): CustomerProfile
	return {
		budget = math.random(250, 1800),
		patience = math.random(25, 100),
		theftRiskTolerance = math.random(),
		priceSensitivity = math.random(),
		preferredGpuId = GPU_CHOICES[math.random(1, #GPU_CHOICES)],
	}
end

local function scoreBuy(customer: CustomerRuntimeState, shelf: ShelfState?, business: BusinessState): number
	if not shelf or not shelf.gpuId then
		return 0
	end

	local price = CustomerService._storeService.registry.StoreService.GetSelfSellPrice(business, shelf)
	if not price or price > customer.profile.budget then
		return 0
	end

	local demand = BusinessMath.CalculateCustomerDemand(
		business.economy.marketDemand,
		business.reputation,
		customer.profile.priceSensitivity
	)

	local desiredBonus = if shelf.gpuId == customer.profile.preferredGpuId then 25 else 5
	return 35 + desiredBonus + demand * 20 - business.store.checkoutQueueLength * 4
end

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
	local avatarUserId = CustomerService._avatarService.GetAvatarUserIdForOwner(business.ownerUserId)
	local customer: CustomerRuntimeState = {
		id = nextCustomerId(),
		state = "Entering",
		profile = createRandomProfile(),
		targetShelfId = nil,
		desiredGpuId = nil,
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
	if customer.physicalModelName ~= nil then
		return
	end

	local avatarUserId = customer.avatarUserId
		or CustomerService._avatarService.GetAvatarUserIdForOwner(business.ownerUserId)
	customer.avatarUserId = avatarUserId

	local modelName = `{business.id}_{customer.id}`
	local model = CustomerService._avatarService.CreateCustomerModelAsync(avatarUserId, modelName)
	customer.physicalModelName = model.Name

	model:SetAttribute("BusinessId", business.id)
	model:SetAttribute("CustomerId", customer.id)
	model:SetAttribute("OwnerUserId", business.ownerUserId)
	model:PivotTo(WorldQueryService.GetSpawnCFrame(business.id))
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

function CustomerService.ChoosePhysicalBrowseShelf(businessId: string, customerId: string): string?
	local business = CustomerService._businessService.GetBusiness(businessId)
	if not business then
		return nil
	end

	local customer = business.customers[customerId]
	if not customer then
		return nil
	end

	local targetShelf = CustomerService._storeService.FindBestShelfForCustomer(business, customer.profile.preferredGpuId)
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
    local targetShelf = CustomerService._storeService.FindBestShelfForCustomer(
        business, 
        customer.profile.preferredGpuId
    )

	customer.targetShelfId = if targetShelf then targetShelf.id else nil
	customer.desiredGpuId = if targetShelf then targetShelf.gpuId else customer.profile.preferredGpuId
    customer.lastObservedScore = observedScore or customer.lastObservedScore
    customer.lastDecisionAt = os.clock()

	local foundDesiredGpu = targetShelf ~= nil and targetShelf.gpuId == customer.profile.preferredGpuId

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

	local buyScore = scoreBuy(customer, targetShelf, business)
	local stealScore = if targetShelf then scoreSteal(customer, business, customer.lastObservedScore) else 0
	local leaveScore = scoreLeave(customer, business)

	customer.state = chooseWeightedAction(buyScore, stealScore, leaveScore)
	customer.timeInState = 0

    if customer.state == "Buying" then
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
    if not customer or customer.state ~= "Buying" or not customer.targetShelfId then
        return false
    end

    local canPurchase, _, price = CustomerService._storeService.CanPurchaseFromShelf(
        business,
        customer.targetShelfId,
        customer.profile.budget
    )

    if not canPurchase then
        customer.state = "Leaving"
		return false
    end

    CustomerService._storeService.RemoveStockAfterPurchase(business, customer.targetShelfId)
    CustomerService._businessService.AddMoney(business.id, price or 0, "PhysicalGpuSale")
    business.store.checkoutQueueLength = math.max(0, business.store.checkoutQueueLength - 1)
    customer.satisfaction = math.clamp(customer.satisfaction + 12, 0, 100)
	customer.state = "Leaving"
	customer.timeInState = 0
	return true
end

function CustomerService.TryStartPhysicalTheft(
    businessId: string,
	customerId: string,
	customerModel: Model
): boolean
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

    local detected = CustomerService._securityService.ResolvePhysicalTheftAttempt(business, customer, customerModel, observedScore)
	if not detected then
		CustomerService._storeService.RemoveStockAfterPurchase(business, customer.targetShelfId)
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

	business.reputation = math.clamp(
		business.reputation + BusinessMath.CalculateReputationDelta(customer.satisfaction, false),
		0,
		100
	)
	business.security.activeThefts[customerId] = nil
	business.customers[customerId] = nil
end

function CustomerService.UpdateCustomers(business: BusinessState, deltaSeconds: number)
	local demand = BusinessMath.CalculateCustomerDemand(business.economy.marketDemand, business.reputation, 0.35)

	-- if business.store.open and math.random() < math.clamp(demand * 0.15, 0.02, 0.45) then
	-- 	CustomerService.SpawnCustomer(business)
	-- end

    if
        business.store.open
        and countCustomers(business) < MAX_ACTIVE_CUSTOMERS
        and math.random() < math.clamp(demand * 0.15, 0.02, 0.45)
    then
        local customer = CustomerService.SpawnCustomer(business)
		task.spawn(CustomerService.SpawnPhysicalCustomerAsync, business, customer)
    end

	for customerId, customer in business.customers do
		customer.timeInState += deltaSeconds

        if customer.physicalModelName == nil then
            task.spawn(CustomerService.SpawnPhysicalCustomerAsync, business, customer)
        end

        if customer.state == "Leaving" and customer.timeInState >= 20 then
            business.customers[customerId] = nil
        end

		-- if customer.state == "Entering" then
		-- 	customer.state = "Browsing"
		-- 	customer.timeInState = 0
		-- elseif customer.state == "Browsing" and customer.timeInState >= 1 then
		-- 	CustomerService.ThinkForCustomer(business, customer)
		-- elseif customer.state == "Buying" then
		-- 	if customer.targetShelfId then
		-- 		local canPurchase = CustomerService._storeService.CanPurchaseFromShelf(
		-- 			business,
		-- 			customer.targetShelfId,
		-- 			customer.profile.budget
		-- 		)
		-- 		if canPurchase then
		-- 			business.store.checkoutQueueLength += 1
		-- 			customer.state = "Queueing"
		-- 		else
		-- 			customer.state = "Leaving"
		-- 		end
		-- 	else
		-- 		customer.state = "Leaving"
		-- 	end
		-- 	customer.timeInState = 0
		-- elseif customer.state == "Queueing" and business.store.checkoutQueueLength <= 0 then
		-- 	customer.state = "Leaving"
		-- elseif customer.state == "Leaving" and customer.timeInState >= 1 then
		-- 	business.customers[customerId] = nil
		-- end
	end
end

return CustomerService
