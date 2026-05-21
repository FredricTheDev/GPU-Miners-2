--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)

type BusinessState = BusinessTypes.BusinessState

local EconomyService = {}

EconomyService.Name = "EconomyService"
EconomyService.Priority = 0
EconomyService.Dependencies = {}
EconomyService.Disabled = false

function EconomyService:OnInit() end

function EconomyService:OnStart() end

function EconomyService.UpdateBusinessEnconomy(business: BusinessState, deltaSeconds: number)
    -- this is placeholder logic, later will work with global or server economy events
    local demandWave = math.sin(os.clock() / 120) * 0.05
    business.economy.marketDemand = math.clamp(1 + demandWave + business.reputation / 300, 0.25, 2)
    business.economy.cryptoPriceIndex = math.clamp(1 + math.sin(os.clock() / 180) * 0.1, 0.5, 2.5)

    local totalWages = 0
    for _, staffMember in business.staff do
        totalWages += BusinessMath.CalculateStaffWages(staffMember.wagePerMinute, deltaSeconds)
    end

    if totalWages > 0 then
        business.cash = math.max(0, business.cash - totalWages)
        business.economy.lastWagePaidAt = os.clock()
    end
end

return EconomyService