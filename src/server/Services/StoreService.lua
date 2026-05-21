--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)

type BusinessState = BusinessTypes.BusinessState
type ShelfState = BusinessTypes.ShelfState

local StoreService = {}

StoreService.Name = "StoreService"
StoreService.Priority = 0
StoreService.Dependencies = {}
StoreService.Disabled = false

-- mock for testing until have real gpus
local BASE_GPU_PRICES: { [string]: number } = {
	starter_gpu = 300,
	mid_gpu = 750,
	high_gpu = 1400,
}

function StoreService:OnInit() end

function StoreService:OnStart() end

function StoreService.GetBaseGpuPrice(gpuId: string): number
	return BASE_GPU_PRICES[gpuId] or 500
end

function StoreService.GetShelf(business: BusinessState, shelfId: string): ShelfState?
	return business.store.shelves[shelfId]
end

function StoreService.GetShelfSellPrice(business: BusinessState, shelf: ShelfState): number?
	if not shelf.gpuId then
		return nil
	end

	return BusinessMath.CalculateGpuSellPrice(
		StoreService.GetBaseGpuPrice(shelf.gpuId),
		business.reputation,
		shelf.priceMultiplier
	)
end

function StoreService.HasGpuOnShelves(business: BusinessState, gpuId: string): boolean
	for _, shelf in business.store.shelves do
		if shelf.gpuId == gpuId and shelf.stockAmount > 0 then
			return true
		end
	end
	return false
end

function StoreService.FindBestShelfForCustomer(business: BusinessState, preferredGpuId: string?): ShelfState?
	local fallbackShelf: ShelfState? = nil

	for _, shelf in business.store.shelves do
		if shelf.gpuId ~= nil and shelf.stockAmount > 0 then
            if shelf.gpuId == preferredGpuId then
                return shelf
            end
            fallbackShelf = fallbackShelf or shelf
        end
	end

    return fallbackShelf
end

function StoreService.CanPurchaseFromShelf(business: BusinessState, shelfId: string, budget: number): (boolean, string?, number?)
    local shelf = business.store.shelves[shelfId]
    if not shelf or not shelf.gpuId then
        return false, "Shelf has no GPU assigned", nil
    end

    if shelf.stockAmount <= 0 then
        return false, "Shelf is out of stock", nil
    end

    local price = StoreService.GetShelfSellPrice(business, shelf)
    if not price or price > budget then
        return false, "Customer cannot afford GPU", price
    end

    return true, nil, price
end

function StoreService.RemoveStockAfterPurchase(business: BusinessState, shelfId: string): string?
    local shelf = business.store.shelves[shelfId]
    if not shelf or not shelf.gpuId or shelf.stockAmount <= 0 then
        return nil
    end

    local gpuId = shelf.gpuId
    shelf.stockAmount -= 1
    return gpuId
end

function StoreService.SetGpuPriceMultiplier(business: BusinessState, shelfId: string, priceMultiplier: number): boolean
    local shelf = business.store.shelves[shelfId]
    if not shelf then
        return false
    end

    shelf.priceMultiplier = math.clamp(priceMultiplier, 0.5, 3)
    return true
end

function StoreService.RestockShelfFromInventory(business: BusinessState, shelfId: string): number
    local shelf = business.store.shelves[shelfId]
    if not shelf or not shelf.gpuId then
        return 0
    end

    local available = business.warehouse.inventory[shelf.gpuId] or 0
    local needed = shelf.maxStock - shelf.stockAmount
    local moved = math.min(available, needed)
    if moved <= 0 then
        return 0
    end

	business.warehouse.inventory[shelf.gpuId] = available - moved
	shelf.stockAmount += moved
	business.warehouse.usedCapacity = math.max(0, business.warehouse.usedCapacity - moved)
	return moved
end

return StoreService
