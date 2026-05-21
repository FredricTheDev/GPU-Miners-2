--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sift = require(ReplicatedStorage.Packages.Sift)
local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)

type BusinessState = BusinessTypes.BusinessState
type CustomerProfile = BusinessTypes.CustomerProfile
type CustomerRuntimeState = BusinessTypes.CustomerRuntimeState
type ShelfState = BusinessTypes.ShelfState

type CustomerServiceType = RuntimeTypes.ModuleRuntimeType & {
	registry: {
		StoreService: {
			GetSelfSellPrice: (business: BusinessState, shelf: ShelfState) -> number?,
			FindBestShelfForCustomer: (business: BusinessState, preferredGpuId: string?) -> ShelfState?,
            CanPurchaseFromShelf: (business: BusinessState, shelfId: string, budget: number) -> (boolean, string?, number?)
		},
	},

	Configure: (self: CustomerServiceType, registry: any) -> (),
	OnInit: (self: CustomerServiceType) -> (),
	OnStart: (self: CustomerServiceType) -> (),

	SpawnCustomer: (business: BusinessState) -> CustomerRuntimeState,
	ThinkForCustomer: (business: BusinessState, customer: CustomerRuntimeState) -> (),
    UpdateCustomers: (business: BusinessState, deltaSeconds: number) -> (),
}

local CustomerService = {} :: CustomerServiceType

CustomerService.Name = "CustomerService"
CustomerService.Priority = 0
CustomerService.Dependencies = { "StoreService" }
CustomerService.Disabled = false

local customerCounter = 0

local GPU_CHOICES = { "starter_gpu", "mid_gpu", "high_gpu" }

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

	local price = CustomerService.registry.StoreService.GetSelfSellPrice(business, shelf)
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

local function scoreSteal(customer: CustomerRuntimeState, business: BusinessState): number
	local crowdDensity =
		math.clamp((business.store.checkoutQueueLength + Sift.Dictionary.count(business.customers)) / 20, 0, 2)
	local theftChance = BusinessMath.CalculateTheftChance(
		business.security.securityLevel,
		crowdDensity,
		customer.profile.theftRiskTolerance
	)
	return theftChance * 100
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
	self.registry = registry
end

function CustomerService:OnInit() end

function CustomerService:OnStart() end

function CustomerService.SpawnCustomer(business: BusinessState): CustomerRuntimeState
	local customer: CustomerRuntimeState = {
		id = nextCustomerId(),
		state = "Entering",
		profile = createRandomProfile(),
		targetShelfId = nil,
		desiredGpuId = nil,
		timeInState = 0,
		satisfaction = 50,
	}

	business.customers[customer.id] = customer
	return customer
end

function CustomerService.ThinkForCustomer(business: BusinessState, customer: CustomerRuntimeState)
	local targetShelf =
		CustomerService.registry.StoreService.FindBestShelfForCustomer(business, customer.profile.preferredGpuId)
	customer.targetShelfId = if targetShelf then targetShelf.id else nil
	customer.desiredGpuId = if targetShelf then targetShelf.gpuId else customer.profile.preferredGpuId

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
    local stealScore = if targetShelf then scoreSteal(customer, business) else 0
    local leaveScore = scoreLeave(customer, business)
    customer.state = chooseWeightedAction(buyScore, stealScore, leaveScore)
    customer.timeInState = 0
end

function CustomerService.UpdateCustomers(business: BusinessState, deltaSeconds: number)
    local demand = BusinessMath.CalculateCustomerDemand(
        business.economy.marketDemand,
        business.reputation,
        0.35
    )

    if business.store.open and math.random() < math.clamp(demand * 0.15, 0.02, 0.45) then
        CustomerService.SpawnCustomer(business)
    end

    for customerId, customer in business.customers do
        customer.timeInState += deltaSeconds

        if customer.state == "Entering" then
            customer.state = "Browsing"
            customer.timeInState = 0
        elseif customer.state == "Browsing" and customer.timeInState >= 1 then
            CustomerService.ThinkForCustomer(business, customer)
        elseif customer.state == "Buying" then
            if customer.targetShelfId then
                local canPurchase = CustomerService.registry.StoreService.CanPurchaseFromShelf(business, customer.targetShelfId, customer.profile.budget)
                if canPurchase then
                    business.store.checkoutQueueLength += 1
                    customer.state = "Queueing"
                else
                    customer.state = "Leaving"
                end
            else
                customer.state = "Leaving"
            end
            customer.timeInState = 0
        elseif customer.state == "Queueing" and business.store.checkoutQueueLength <= 0 then
            customer.state = "Leaving"
        elseif customer.state == "Leaving" and customer.timeInState >= 1 then
            business.customers[customerId] = nil
        end
    end
end

return CustomerService
