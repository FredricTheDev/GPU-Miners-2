--!strict
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local NPC_COLLISION_GROUP = "StoreNpc"

local CollisionService = {}

CollisionService.Name = "CollisionService"
CollisionService.Priority = 0
CollisionService.Dependencies = {}
CollisionService.Disabled = false

pcall(function()
	PhysicsService:RegisterCollisionGroup(NPC_COLLISION_GROUP)
	PhysicsService:RegisterCollisionGroup("Players")
end)

pcall(function()
	PhysicsService:CollisionGroupSetCollidable("Players", NPC_COLLISION_GROUP, false)
end)

local function onCharacterAdded(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = "Players"
		end
	end
end

function CollisionService:OnInit() end

function CollisionService:OnStart()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(onCharacterAdded)

		onCharacterAdded(player.Character or player.CharacterAdded:Wait())
	end)
end

return CollisionService
