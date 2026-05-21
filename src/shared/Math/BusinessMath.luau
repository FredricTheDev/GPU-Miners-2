--!strict

local BusinessMath = {}

function BusinessMath.CalculateGpuSellPrice(basePrice: number, reputation: number, priceMultiplier: number): number
    local reputationBonus = 1 + math.clamp(reputation, 0, 100) / 500
    return math.max(1, math.floor(basePrice * priceMultiplier * reputationBonus))
end

function BusinessMath.CalculateCustomerDemand(marketDemand: number, reputation: number, priceSensitivity: number): number
    local reputationFactor = 0.5 + math.clamp(reputation, 0, 100) / 100
    local sensitivityPenalty = math.clamp(priceSensitivity, 0, 1) * 0.25
    return math.clamp(marketDemand * reputationFactor - sensitivityPenalty, 0, 2)
end

function BusinessMath.CalculateTheftChance(securityLevel: number, crowdDensity: number, theftRiskTolerance: number): number
    local baseChance = 0.04 + math.clamp(crowdDensity, 0, 2) * 0.03
    local riskBonus = math.clamp(theftRiskTolerance, 0, 1) * 0.08
    local securityReduction = math.clamp(securityLevel, 0, 100) / 100 * 0.1
    return math.clamp(baseChance + riskBonus - securityReduction, 0, 0.4)
end

function BusinessMath.CalculateMiningProfit(hashrate: number, cryptoPriceIndex: number, condition: number): number
    local conditionFactor = math.clamp(condition, 0, 100) / 100
    return hashrate * cryptoPriceIndex * conditionFactor * 0.01
end

function BusinessMath.CalculateElectricityCost(powerUsageKw: number, seconds: number, electricityPricePerKwh: number): number
    local hours = seconds / 3600
    return powerUsageKw * hours * electricityPricePerKwh
end

function BusinessMath.CalculateStaffWages(wagePerMinute: number, seconds: number): number
    return wagePerMinute * (seconds / 60)
end

function BusinessMath.CalculateCustomerSatisfactionDelta(queueLength: number, foundDesiredGpu: boolean, priceMultipler: number): number
    local delta = 0
    if foundDesiredGpu then
        delta += 8
    else
        delta -= 10
    end

    delta -= queueLength * 2
    delta -= math.max(0, priceMultipler - 1) * 8
    return delta
end

function BusinessMath.CalculateReputationDelta(averageSatisfaction: number, theftDetected: boolean): number
    local delta = (averageSatisfaction - 50) / 100
    if theftDetected then
        delta -= 0.4
    end
    return delta
end

return BusinessMath