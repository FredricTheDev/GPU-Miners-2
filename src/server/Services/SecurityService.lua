--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sift = require(ReplicatedStorage.Packages.Sift)
local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)

type BusinessState = BusinessTypes.BusinessState
type CustomerRuntimeState = BusinessTypes.CustomerRuntimeState
type StaffTask = BusinessTypes.StaffTask
type StaffTaskType = BusinessTypes.StaffTaskType

type SecurityServiceType = RuntimeTypes.ModuleRuntimeType & {
	registry: {
		StoreService: {
            RemoveStockAfterPurchase: (business: BusinessState, shelfId: string) -> ()
        },
		StaffService: {
            CreateTask: (
                business: BusinessState, 
                taskType: StaffTaskType,
                priority: number, 
                targetId: string?, 
                expiresAfterSeconds: number?
            ) -> StaffTask
        },
	},

	Configure: (self: SecurityServiceType, registry: any) -> (),
	OnInit: (self: SecurityServiceType) -> (),
	OnStart: (self: SecurityServiceType) -> (),

    CalculateSecurityLevel: (business: BusinessState) -> number,
    TryDetectTheft: (business: BusinessState, customer: CustomerRuntimeState) -> boolean,
    UpdateSecurity: (business: BusinessState, deltaSeconds: number) -> ()
}

local SecurityService = {} :: SecurityServiceType

SecurityService.Name = "SecurityService"
SecurityService.Priority = 0
SecurityService.Dependencies = {}
SecurityService.Disabled = false

local function countGuards(business: BusinessState): number
    local guards = 0
    for _, staffMember in business.staff do
        if staffMember.role == "Guard" then
            guards += 1
        end
    end
    return guards
end

function SecurityService:Configure(registry)
	self.registry = registry
end

function SecurityService:OnInit() end

function SecurityService:OnStart() end

function SecurityService.CalculateSecurityLevel(business: BusinessState): number
    local guardContribution = countGuards(business) * 15
    local cameraContribution = business.security.cameraCoverage * 15
    local alarmContribution = business.security.alarmLevel * 10
    return math.clamp(10 + guardContribution + cameraContribution + alarmContribution, 0, 100)
end

function SecurityService.TryDetectTheft(business: BusinessState, customer: CustomerRuntimeState): boolean
    local guardCount = countGuards(business)
    local crowdDensity = math.clamp((business.store.checkoutQueueLength + Sift.Dictionary.count(business.customers)) / 20, 0, 2)
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

function SecurityService.UpdateSecurity(business: BusinessState, deltaSeconds: number)
    business.security.securityLevel = SecurityService.CalculateSecurityLevel(business)

    for customerId, customer in business.customers do
        if customer.state == "Stealing" and not business.security.activeThefts[customerId] then
            business.security.activeThefts[customerId] = true

            local detected = SecurityService.TryDetectTheft(business, customer)
            if detected then
                business.security.lastTheftDetectedAt = os.clock()
                SecurityService.registry.StaffService.CreateTask(business, "ChaseThief", 90, customerId, 15)

                -- todo: tell client that the thief was stopped
                -- todo: allow user to report caught thiefs, so if they come back they can be kicked out

            else
                local shelfId = customer.targetShelfId
                if shelfId then
                    SecurityService.registry.StoreService.RemoveStockAfterPurchase(business, shelfId)
                end
                business.customers[customerId] = nil
            end
        elseif customer.state ~= "Stealing" then
            business.security.activeThefts[customerId] = nil
        end
    end
end

return SecurityService
