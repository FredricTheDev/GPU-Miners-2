--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)

type BusinessState = BusinessTypes.BusinessState
type ShelfState = BusinessTypes.ShelfState

local activeBusinesses: { [string]: BusinessState } = {}
local businessByOwner: { [number]: string } = {}

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
	local business: BusinessState = {
		id = businessId,
		ownerUserId = player.UserId,
		cash = 5000,
		reputation = 50,
		store = {
			shelves = createDefaultShelves(), -- mock shelves
			checkoutQueueLength = 0,
			checkoutQueueSlots = {},
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
	return true    
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
end

return BusinessService
