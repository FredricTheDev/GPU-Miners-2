--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sift = require(ReplicatedStorage.Packages.Sift)
local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

type BusinessState = BusinessTypes.BusinessState
type CustomerRuntimeState = BusinessTypes.CustomerRuntimeState
type StaffTask = BusinessTypes.StaffTask
type StaffTaskType = BusinessTypes.StaffTaskType

type SecurityServiceType = RuntimeTypes.ModuleRuntimeType & {
	_registry: any,

	_storeService: any?,
	_staffService: any?,
	_worldQueryService: any?,
	_rankService: any?,

	Configure: (self: SecurityServiceType, registry: any) -> (),
	OnInit: (self: SecurityServiceType) -> (),
	OnStart: (self: SecurityServiceType) -> (),

	CalculateSecurityLevel: (business: BusinessState) -> number,
	TryDetectTheft: (business: BusinessState, customer: CustomerRuntimeState) -> boolean,
	UpdateSecurity: (business: BusinessState, deltaSeconds: number) -> (),
	GetCustomerObservedScore: (businessId: string, customerModel: Model) -> number,
	ResolvePhysicalTheftAttempt: (
		business: BusinessState,
		customer: CustomerRuntimeState,
		customerModel: Model,
		observedScore: number
	) -> boolean,
}

local SecurityService = {} :: SecurityServiceType

local DEFAULT_GUARD_VIEW_RANGE = 45
local DEFAULT_GUARD_FOV_DEGREES = 95
local DEFAULT_CAMERA_VIEW_RANGE = 70
local DEFAULT_CAMERA_FOV_DEGREES = 70

SecurityService.Name = "SecurityService"
SecurityService.Priority = 0
SecurityService.Dependencies = { "RankService" }
SecurityService.Disabled = false

local function countCustomers(business: BusinessState): number
	local count = 0
	for _ in business.customers do
		count += 1
	end
	return count
end

local function countGuards(business: BusinessState): number
	local guards = 0
	for _, staffMember in business.staff do
		if staffMember.role == "Guard" then
			guards += 1
		end
	end
	return guards
end

local function getObserverScore(
	observer: Instance,
	target: Instance,
	rangeStuds: number,
	fovDegrees: number,
	weight: number
): number
	local observerCFrame = SecurityService._worldQueryService.GetCFrame(observer)
	local targetCFrame = SecurityService._worldQueryService.GetCFrame(target)
	if not observerCFrame or not targetCFrame then
		return 0
	end

	local offset = targetCFrame.Position - observerCFrame.Position
	local distance = offset.Magnitude
	if distance <= 0 or distance > rangeStuds then
		return 0
	end

	local directionToTarget = offset.Unit
	local facingDot = observerCFrame.LookVector:Dot(directionToTarget)
	local requiredDot = math.cos(math.rad(fovDegrees / 2))
	if facingDot < requiredDot then
		return 0
	end

	if not SecurityService._worldQueryService.HasLineOfSight(observerCFrame.Position, target, { observer, target }) then
		return 0
	end

	local distanceScore = 1 - distance / rangeStuds
	local facingScore = math.clamp((facingDot - requiredDot) / math.max(0.01, 1 - requiredDot), 0, 1)
	return math.clamp(distanceScore * 0.55 + facingScore * 0.45, 0, 1) * weight
end

function SecurityService:Configure(registry)
	self._registry = registry

	self._storeService = registry.StoreService
	self._staffService = registry.StaffService
	self._worldQueryService = registry.WorldQueryService
	self._rankService = registry.RankService
end

function SecurityService:OnInit() end

function SecurityService:OnStart() end

function SecurityService.CalculateSecurityLevel(business: BusinessState): number
	local guardContribution = countGuards(business) * 15
	local cameraCount =
		#SecurityService._worldQueryService.GetTaggedInstancesForBusiness(WorldTags.SecurityCamera, business.id)
	local physicalCameraCoverage = math.clamp(cameraCount * 0.15, 0, 1)
	local cameraCoverage = math.max(business.security.cameraCoverage, physicalCameraCoverage)
	local cameraContribution = cameraCoverage * 35
	local alarmContribution = business.security.alarmLevel * 10
	return math.clamp(10 + guardContribution + cameraContribution + alarmContribution, 0, 100)
end

function SecurityService.TryDetectTheft(business: BusinessState, customer: CustomerRuntimeState): boolean
	local guardCount = countGuards(business)
	local crowdDensity =
		math.clamp((business.store.checkoutQueueLength + Sift.Dictionary.count(business.customers)) / 20, 0, 2)
	local theftChance = BusinessMath.CalculateTheftChance(
		business.security.securityLevel,
		crowdDensity,
		customer.profile.theftRiskTolerance
	)

	if math.random() > theftChance then
		return false
	end

	local detectionChance = math.clamp(0.15 + guardCount * 0.18 + business.security.cameraCoverage * 0.35, 0, 0.95)
	return math.random() < detectionChance
end

function SecurityService.GetCustomerObservedScore(businessId: string, customerModel: Model): number
	local score = 0

	for _, staffInstance in
		SecurityService._worldQueryService.GetTaggedInstancesForBusiness(WorldTags.StaffNpc, businessId)
	do
		local role = staffInstance:GetAttribute("Role")
		if role == "Guard" or role == "Cashier" or role == nil then
			local rangeStuds = staffInstance:GetAttribute("ViewRange")
			local fovDegrees = staffInstance:GetAttribute("ViewFovDegrees")
			score += getObserverScore(
				staffInstance,
				customerModel,
				if typeof(rangeStuds) == "number" then rangeStuds else DEFAULT_GUARD_VIEW_RANGE,
				if typeof(fovDegrees) == "number" then fovDegrees else DEFAULT_GUARD_FOV_DEGREES,
				if role == "Guard" then 0.45 else 0.25
			)
		end
	end

	for _, cameraInstance in
		SecurityService._worldQueryService.GetTaggedInstancesForBusiness(WorldTags.SecurityCamera, businessId)
	do
		if cameraInstance:GetAttribute("Enabled") ~= false then
			local rangeStuds = cameraInstance:GetAttribute("ViewRange")
			local fovDegrees = cameraInstance:GetAttribute("ViewFovDegrees")
			score += getObserverScore(
				cameraInstance,
				customerModel,
				if typeof(rangeStuds) == "number" then rangeStuds else DEFAULT_CAMERA_VIEW_RANGE,
				if typeof(fovDegrees) == "number" then fovDegrees else DEFAULT_CAMERA_FOV_DEGREES,
				0.35
			)
		end
	end

	return math.clamp(score, 0, 1)
end

function SecurityService.ResolvePhysicalTheftAttempt(
	business: BusinessState,
	customer: CustomerRuntimeState,
	customerModel: Model,
	observedScore: number
): boolean
	local crowdDensity = math.clamp((business.store.checkoutQueueLength + countCustomers(business)) / 20, 0, 2)
	local theftChance = BusinessMath.CalculateTheftChance(
		business.security.securityLevel,
		crowdDensity,
		customer.profile.theftRiskTolerance
	)

	local attemptChance = math.clamp(theftChance - observedScore * 0.25, 0.01, 0.75)
	if math.random() > attemptChance then
		customer.state = "Leaving"
		return true
	end

	local detectionChance = math.clamp(0.1 + observedScore * 0.8 + business.security.alarmLevel * 0.05, 0, 0.98)
	local detected = math.random() < detectionChance
	business.security.activeThefts[customer.id] = true

	if detected then
		customer.state = "Leaving"
		business.security.lastTheftDetectedAt = os.clock()
		SecurityService._staffService.CreateTask(business, "ChaseThief", 95, customer.id, 20)
		if SecurityService._rankService then
			SecurityService._rankService.AddBusinessRankValue(business, "Security", 80)
		end
		-- todo: tell client theft was detected
	end

	local root = customerModel:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		CollectionService:AddTag(root, WorldTags.StoreInteractable)
	end

	return detected
end

function SecurityService.UpdateSecurity(business: BusinessState, deltaSeconds: number)
	business.security.securityLevel = SecurityService.CalculateSecurityLevel(business)
	if SecurityService._rankService then
		SecurityService._rankService.SetBusinessRankValue(business, "Security", business.security.securityLevel)
	end
	
	for customerId, customer in business.customers do
		if customer.physicalModelName ~= nil then
			continue
		end

		if customer.state == "Stealing" and not business.security.activeThefts[customerId] then
			business.security.activeThefts[customerId] = true

			local detected = SecurityService.TryDetectTheft(business, customer)
			if detected then
				business.security.lastTheftDetectedAt = os.clock()
				SecurityService._staffService.CreateTask(business, "ChaseThief", 90, customerId, 15)
				if SecurityService._rankService then
					SecurityService._rankService.AddBusinessRankValue(business, "Security", 60)
				end
				-- todo: tell client that the thief was stopped
				-- todo: allow user to report caught thiefs, so if they come back they can be kicked out
			else
				local shelfId = customer.targetShelfId
				if shelfId then
					SecurityService._storeService.RemoveStockAfterPurchase(business, shelfId)
				end
				business.customers[customerId] = nil
			end
		elseif customer.state ~= "Stealing" then
			business.security.activeThefts[customerId] = nil
		end
	end
end

return SecurityService
