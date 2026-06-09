--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BusinessMath = require(ReplicatedStorage.Shared.Math.BusinessMath)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)

type BusinessState = BusinessTypes.BusinessState
type MiningRig = BusinessTypes.MiningRig
type StaffTask = BusinessTypes.StaffTask
type StaffTaskType = BusinessTypes.StaffTaskType

type MiningServiceType = RuntimeTypes.ModuleRuntimeType & {
    registry: {
		StaffService: {
			CreateTask: (
                business: BusinessState, 
                taskType: StaffTaskType,
                priority: number, 
                targetId: string?, 
                expiresAfterSeconds: number?
            ) -> StaffTask
		},
        RankService: any,
	},

	Configure: (self: MiningServiceType, registry: any) -> (),
	OnInit: (self: MiningServiceType) -> (),
	OnStart: (self: MiningServiceType) -> (),

    AddMiningRig: (business: BusinessState, rig: MiningRig) -> (),
    UpdateMiningRigs: (business: BusinessState, deltaSeconds: number) -> (),
}

local MiningService = {} :: MiningServiceType

MiningService.Name = "MiningService"
MiningService.Priority = 0
MiningService.Dependencies = { "StaffService", "RankService" }
MiningService.Disabled = false

function MiningService:Configure(registry)
    self.registry = registry
end

function MiningService:OnInit() end

function MiningService:OnStart() end

function MiningService.AddMiningRig(business: BusinessState, rig: MiningRig)
    business.miningRigs[rig.id] = rig
    if MiningService.registry.RankService then
        MiningService.registry.RankService.SetBusinessRankValue(business, "Mining", rig.hashrate)
    end
end

function MiningService.UpdateMiningRigs(business: BusinessState, deltaSeconds: number)
    local totalHashrate = 0
    for _, rig in business.miningRigs do
        totalHashrate += rig.hashrate
        if rig.running and rig.condition > 0 then
            local grossProfit = BusinessMath.CalculateMiningProfit(
                rig.hashrate,
                business.economy.cryptoPriceIndex,
                rig.condition
            ) * deltaSeconds

            local electricityCost = BusinessMath.CalculateElectricityCost(
                rig.powerUsageKw,
                deltaSeconds,
                business.economy.electricityPricePerKwh
            )

            business.cash += grossProfit - electricityCost
            rig.heat = math.clamp(rig.heat + rig.powerUsageKw * 0.08 * deltaSeconds, 0, 120)
            rig.condition = math.clamp(rig.condition - (0.01 + rig.heat / 20000) * deltaSeconds, 0, 100)

            if rig.condition <= 35 and not rig.needsRepair then
                rig.needsRepair = true
                MiningService.registry.StaffService.CreateTask(business, "RepairRig", 70, rig.id, 120)
            end
        else
            rig.heat = math.max(0, rig.heat - deltaSeconds * 0.5)
        end
    end
    if totalHashrate > 0 and MiningService.registry.RankService then
        MiningService.registry.RankService.SetBusinessRankValue(business, "Mining", totalHashrate)
    end
end

return MiningService
