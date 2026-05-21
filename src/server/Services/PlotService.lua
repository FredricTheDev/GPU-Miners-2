local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Sift = require(ReplicatedStorage.Packages.Sift)
local Trove = require(ReplicatedStorage.Packages.Trove)
local PlayerUtil = require(ReplicatedStorage.Shared.Util.PlayerUtil)

local store = ReplicatedStorage:WaitForChild("Plot"):WaitForChild("Store") :: Model

local Plots = Workspace:WaitForChild("Plots") :: { [string]: Part } & Folder

type PlotServiceType = {
	OnPlayerAdded: (self: PlotServiceType, player: Player) -> (),

	AssignPlot: (self: PlotServiceType, player: Player, plotIndex: number) -> (),

	UnassignPlot: (self: PlotServiceType, player: Player) -> (),
}

type PlotData = {
	OwnerId: number,
	Trove: typeof(Trove.new()),
	Models: {
		Store: Model,
		Warehouse: Model,
	},
}

local function getPlotCenter(plotIndex: number): CFrame
	return Plots:FindFirstChild(plotIndex).CFrame
end

local PlotService = {} :: PlotServiceType

PlotService.Name = "PlotService"
PlotService.Priority = 0
PlotService.Dependencies = { "GarbageService", "BusinessService" }
PlotService.Disabled = false

function PlotService:Configure(registry)
	self._registry = registry
end

function PlotService:OnInit()
	self.plots = {}
end

function PlotService:OnStart()
	for _, player: Player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:OnPlayerAdded(player)
		end)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:OnPlayerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:UnassignPlot(player)
	end)
end

function PlotService:OnPlayerAdded(player: Player): ()
	player.CharacterAdded:Connect(function()
		self:SpawnPlayerAtPlot(player)
	end)

	for index in ipairs(Sift.Array.create(6, 0)) do
		if self.plots[index] then
			continue
		end

		self:AssignPlot(player, index)
		return
	end
end

function PlotService:AssignPlot(player: Player, plotIndex: number): ()
	local centerCFrame = getPlotCenter(plotIndex)

	local storeClone = store:Clone()
	storeClone:PivotTo(centerCFrame)

	self._registry.GarbageService:AddObject(player.UserId, storeClone)

	self.plots[plotIndex] = {
		OwnerId = player.UserId,
		Models = {
			Store = storeClone,
		},
	} :: PlotData

	print(`Setting {player.Name} plot {plotIndex}`)
	self:SpawnPlayerAtPlot(player)

	self._registry.BusinessService.LoadBusiness(player)
end

function PlotService:SpawnPlayerAtPlot(player: Player)
	local _, plotData = self.GetPlotByUserId(player.UserId)

	local character = PlayerUtil.GetCharacter(player)

	local storePivot = plotData.Models.Store:GetPivot()
	character:PivotTo(storePivot * CFrame.new(Vector3.new(0, 5, 0)))
end

function PlotService:UnassignPlot(player: Player)
	local index = self.GetPlotByUserId(player.UserId)
	if not index then
		return
	end
	self.plots[index] = nil
end

function PlotService.GetPlotByUserId(userId: number): (number, PlotData)
	local index = Sift.Array.findWhere(PlotService.plots, function(item: PlotData)
		return item.OwnerId == userId
	end)
	return index, PlotService.plots[index]
end

return PlotService
