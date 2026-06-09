--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)

type LogisticsServiceType = RuntimeTypes.ModuleRuntimeType & {
	registry: {
		StaffService: {
			CreateTask: (
				business: BusinessState,
				taskType: StaffTaskType,
				priority: number,
				targetId: string?,
				expiresAfterSeconds: number?
			) -> StaffTask,
		},
		RankService: any?,
	},

	Configure: (self: LogisticsServiceType, registry: any) -> (),
	OnInit: (self: LogisticsServiceType) -> (),
	OnStart: (self: LogisticsServiceType) -> (),

	CreateDeliveryOrder: (business: BusinessState, gpuId: string, quantity: number, unitCost: number) -> DeliveryOrder,
	UpdateDeliveries: (business: BusinessState, deltaSeconds: number) -> (),
}

type BusinessState = BusinessTypes.BusinessState
type DeliveryOrder = BusinessTypes.DeliveryOrder
type StaffTaskType = BusinessTypes.StaffTaskType
type StaffTask = BusinessTypes.StaffTask

local LogisticsService = {} :: LogisticsServiceType

LogisticsService.Name = "LogisticsService"
LogisticsService.Priority = 0
LogisticsService.Dependencies = { "StaffService", "RankService" }
LogisticsService.Disabled = false

local deliveryCounter = 0

local function nextDeliveryId(): string
	deliveryCounter += 1
	return `delivery_{deliveryCounter}`
end

function LogisticsService:Configure(registry)
	self.registry = registry
end

function LogisticsService:OnInit() end

function LogisticsService:OnStart() end

function LogisticsService.CreateDeliveryOrder(
	business: BusinessState,
	gpuId: string,
	quantity: number,
	unitCost: number
): DeliveryOrder
	local order: DeliveryOrder = {
		id = nextDeliveryId(),
		gpuId = gpuId,
		quantity = math.max(1, math.floor(quantity)),
		unitCost = unitCost,
		state = "Preparing",
		secondsRemaining = 5,
		assignedStaffId = nil,
	}

	business.deliveries[order.id] = order
	return order
end

function LogisticsService.UpdateDeliveries(business: BusinessState, deltaSeconds: number)
	for _, delivery in business.deliveries do
		if delivery.state == "Preparing" or delivery.state == "InTransit" then
			delivery.secondsRemaining -= deltaSeconds

			if delivery.secondsRemaining <= 0 then
				if delivery.state == "Preparing" then
					delivery.state = "InTransit"
					delivery.secondsRemaining = 20
				else
					delivery.state = "Arrived"
					delivery.secondsRemaining = 0
					LogisticsService.registry.StaffService.CreateTask(business, "UnloadDelivery", 60, delivery.id, 60)

					-- todo: tell client the delivery arrived
				end
			end
		elseif delivery.state == "Arrived" then
			delivery.state = "Unloading"
		elseif delivery.state == "Unloading" then
			local availableCapacity = math.max(0, business.warehouse.capacity - business.warehouse.usedCapacity)
			local addedQuantity = math.min(delivery.quantity, availableCapacity)
			business.warehouse.inventory[delivery.gpuId] = (business.warehouse.inventory[delivery.gpuId] or 0)
				+ addedQuantity
			business.warehouse.usedCapacity += addedQuantity
			if addedQuantity > 0 and LogisticsService.registry.RankService then
				LogisticsService.registry.RankService.AddBusinessRankValue(business, "Stock", addedQuantity * 15)
			end
			delivery.state = "Complete"
		end
	end
end

return LogisticsService
