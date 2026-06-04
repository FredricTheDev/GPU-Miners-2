--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)

type BusinessState = BusinessTypes.BusinessState

type SimulationServiceType = RuntimeTypes.ModuleRuntimeType & {
	_registry: any,

	_businessService: any?,
	_economyService: any?,
	_customerService: any?,
	_staffService: any?,
	_securityService: any?,
	_logisticsService: any?,
	_miningService: any?,

	Configure: (self: SimulationServiceType, registry: any) -> (),
	OnInit: (self: SimulationServiceType) -> (),
	OnStart: (self: SimulationServiceType) -> (),

	StepBusiness: (self: SimulationServiceType, business: BusinessState, deltaSeconds: number) -> (),
	StepBusinessById: (self: SimulationServiceType, businessId: string, deltaSeconds: number) -> (),
	StepAllBusinesses: (self: SimulationServiceType, deltaSeconds: number) -> (),
}

local SimulationService = {} :: SimulationServiceType

SimulationService.Name = "SimulationService"
SimulationService.Priority = 0
SimulationService.Dependencies = {
	"BusinessService",
	"CustomerService",
	"EconomyService",
	"LogisticsService",
	"MiningService",
	"SecurityService",
	"StaffService",
}
SimulationService.Disabled = false

local TICK_SECONDS = 1
local MAX_CATCHUP_STEPS = 3

local running = false

function SimulationService:Configure(registry)
	self._registry = registry

	self._businessService = registry.BusinessService
	self._economyService = registry.EconomyService
	self._customerService = registry.CustomerService
	self._staffService = registry.StaffService
	self._securityService = registry.SecurityService
	self._logisticsService = registry.LogisticsService
	self._miningService = registry.MiningService
end

function SimulationService:OnInit() end

function SimulationService:OnStart()
	if running then
		return
	end

	running = true

	task.spawn(function()
		local lastTime = os.clock()
		local accumulator = 0

		while running do
			local now = os.clock()
			local frameDelta = now - lastTime
			lastTime = now

			accumulator += frameDelta

			local steps = 0

			while accumulator >= TICK_SECONDS and steps < MAX_CATCHUP_STEPS do
				local success, result = xpcall(function()
					self:StepAllBusinesses(TICK_SECONDS)
				end, function(err)
					return `Handled Error: {err} \n {debug.traceback()}`
				end)

				if not success then
					warn("[SimulationService] Step failed:", result)
				end

				accumulator -= TICK_SECONDS
				steps += 1
			end

			if steps >= MAX_CATCHUP_STEPS then
				accumulator = 0
			end

			task.wait(0.1)
		end
	end)
end

function SimulationService:StepBusiness(business: BusinessState, deltaSeconds: number)
	-- fixed order to prevent side effects
	self._economyService.UpdateBusinessEconomy(business, deltaSeconds)
	self._customerService.UpdateCustomers(business, deltaSeconds)
	self._staffService.UpdateStaff(business, deltaSeconds)
	self._securityService.UpdateSecurity(business, deltaSeconds)
	self._logisticsService.UpdateDeliveries(business, deltaSeconds)
	self._miningService.UpdateMiningRigs(business, deltaSeconds)
	self._businessService.PublishBusiness(business)
end

function SimulationService:StepBusinessById(businessId: string, deltaSeconds: number)
	local business = self._businessService.GetBusiness(businessId)

	if not business then
		return
	end

	self:StepBusiness(business, deltaSeconds)
end

function SimulationService:StepAllBusinesses(deltaSeconds: number)
	local businesses = self._businessService.GetActiveBusinesses()

	for _, business in businesses do
		self:StepBusiness(business, deltaSeconds)
	end
end

return SimulationService
