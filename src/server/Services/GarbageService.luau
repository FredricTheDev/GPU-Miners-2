local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Packages.Trove)
local PlayerUtil = require(ReplicatedStorage.Shared.Util.PlayerUtil)

local GarbageFolder = Workspace:WaitForChild("Garbage") :: Folder

type GarbageServiceType = {
	OnPlayerAdded: (self: GarbageServiceType, player: Player) -> (),

	OnPlayerRemoving: (self: GarbageServiceType, player: Player) -> (),

	AddObject: (self: GarbageServiceType, userId: number, instance: BasePart | Model, cleanupMethod: string?) -> (),

	GetContainer: (self: GarbageServiceType, userId: number) -> typeof(Trove.new()),
}

local garbageNameTag = "Garbage_"

local GarbageService = {} :: GarbageServiceType

GarbageService.Name = "GarbageService"
GarbageService.Priority = 0

function GarbageService:OnInit()
	self.containers = {}
end

function GarbageService:OnStart()
	for _, player: Player in ipairs(Players:GetPlayers()) do
		self:OnPlayerAdded(player)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:OnPlayerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:OnPlayerRemoving(player)
	end)
end

function GarbageService:OnPlayerAdded(player: Player): ()
	if self.containers[player.UserId] ~= nil then
		return
	end

	self.containers[player.UserId] = Trove.new()

	if not self.GetGarbageFolder(player.UserId) then
		local garbageFolder = Instance.new("Folder")
		garbageFolder.Name = `{garbageNameTag}{player.UserId}`
		garbageFolder.Parent = GarbageFolder
	end
end

function GarbageService:OnPlayerRemoving(player: Player): ()
	local garbageTrove = self.containers[player.UserId]
	if garbageTrove then
		garbageTrove:Destroy()
	end

	self.containers[player.UserId] = nil

	local garbageFolder = self.GetGarbageFolder(player.UserId)
	if not garbageFolder then
		return
	end
	garbageFolder:Destroy()
end

function GarbageService:AddObject(userId: number, instance: Instance, cleanupMethod: string?): ()
	local container = self.containers[userId]
	if not container then
		local player = PlayerUtil.GetPlayerByUserId(userId)
		if player then
			self:OnPlayerAdded(player)
			container = self.containers[userId]
		end

		if not container then
			warn("No trove container found for", userId)
			return
		end
	end

	local garbageFolder = self.GetGarbageFolder(userId)
	if garbageFolder then
		instance.Parent = garbageFolder
	end

	container:Add(instance, cleanupMethod)
end

function GarbageService.GetGarbageFolder(userId: number): Folder
	return GarbageFolder:FindFirstChild(`{garbageNameTag}{userId}`)
end

function GarbageService.GetContainer(userId: number): typeof(Trove.new())
	local container = GarbageService.containers[userId]
	if container then
		return container
	end

	local player = PlayerUtil.GetPlayerByUserId(userId)
	if player then
		GarbageService:OnPlayerAdded(player)
	end

	return GarbageService.containers[userId]
end

return GarbageService
