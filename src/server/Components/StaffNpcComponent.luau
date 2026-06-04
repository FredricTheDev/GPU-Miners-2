--!strict
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Component = require(ReplicatedStorage.Packages.Component)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

local WorldQueryService = require(ServerScriptService.Server.Services.WorldQueryService)

local StaffNpcComponent = Component.new {
    Tag = WorldTags.StaffNpc,
    Ancestors = { workspace }
}

local NPC_COLLISION_GROUP = "StoreNpc"
local THINK_INTERVAL_SECONDS = 0.75
local CUSTOMER_SCAN_RANGE = 45

local collisionGroupReady = false

local function ensureCollisionGroup()
	if collisionGroupReady then
		return
	end

	pcall(function()
		PhysicsService:RegisterCollisionGroup(NPC_COLLISION_GROUP)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, NPC_COLLISION_GROUP, false)
	end)

	collisionGroupReady = true
end

local function configureModelCollision(model: Model)
	ensureCollisionGroup()

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = NPC_COLLISION_GROUP
			descendant:SetNetworkOwner(nil)
		end
	end
end

local function configureHumanoid(humanoid: Humanoid)
	humanoid.AutoJumpEnabled = false
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
end

function StaffNpcComponent:Construct()
	self.Model = self.Instance :: Model
	self.BusinessId = self.Model:GetAttribute("BusinessId")
	self.Role = self.Model:GetAttribute("Role")
	self.Running = false

	local humanoid = self.Model:FindFirstChildWhichIsA("Humanoid")
	local root = self.Model:FindFirstChild("HumanoidRootPart")
	self.Humanoid = if humanoid and humanoid:IsA("Humanoid") then humanoid else nil
	self.Root = if root and root:IsA("BasePart") then root else nil
end

function StaffNpcComponent:Start()
    if typeof(self.BusinessId) ~= "string" or not self.Root then
        return
    end

	self.Model.PrimaryPart = self.Root
	configureModelCollision(self.Model)
	if self.Humanoid then
		configureHumanoid(self.Humanoid)
	end

    self.Running = true
    task.spawn(function()
        self:RunLookAndPatrolLoop()
    end)
end

function StaffNpcComponent:Stop()
	self.Running = false
end

function StaffNpcComponent:GetNearestCustomer(): Model?
    local nearestCustomer: Model? = nil
    local nearestDistance = CUSTOMER_SCAN_RANGE

	for _, instance in CollectionService:GetTagged(WorldTags.Customer) do
		if instance:IsA("Model") and instance:GetAttribute("BusinessId") == self.BusinessId then
			local cframe = WorldQueryService.GetCFrame(instance)
			if cframe and self.Root then
				local distance = (cframe.Position - self.Root.Position).Magnitude
				if distance < nearestDistance then
					nearestDistance = distance
					nearestCustomer = instance
				end
			end
		end
	end

	return nearestCustomer
end

function StaffNpcComponent:FacePosition(position: Vector3)
	if not self.Root then
		return
	end

	local flatTarget = Vector3.new(position.X, self.Root.Position.Y, position.Z)
	if (flatTarget - self.Root.Position).Magnitude < 0.1 then
		return
	end

	self.Model:PivotTo(CFrame.lookAt(self.Root.Position, flatTarget))
end

function StaffNpcComponent:MoveToCFrame(targetCFrame: CFrame)
	if not self.Humanoid or not self.Root then
		return
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 5,
	})

	local success = pcall(function()
		path:ComputeAsync(self.Root.Position, targetCFrame.Position)
	end)

	if not success or path.Status ~= Enum.PathStatus.Success then
		self.Humanoid:MoveTo(targetCFrame.Position)
		self.Humanoid.MoveToFinished:Wait()
		return
	end

	for _, waypoint in path:GetWaypoints() do
		if not self.Running then
			return
		end
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			return
		end
		self.Humanoid:MoveTo(waypoint.Position)
		self.Humanoid.MoveToFinished:Wait()
	end
end

function StaffNpcComponent:RunLookAndPatrolLoop()
    while self.Running do
        local nearestCustomer = self:GetNearestCustomer()
        if nearestCustomer then
            local customerCFrame = WorldQueryService.GetCFrame(nearestCustomer)
            if customerCFrame then
                self:FacePosition(customerCFrame.Position)
            end
        elseif self.Role == "Guard" then
            local patrolCFrame = WorldQueryService.GetRandomTaggedCFrame(WorldTags.BrowsePoint, self.BusinessId)
			if patrolCFrame and math.random() < 0.35 then
				self:MoveToCFrame(patrolCFrame)
			end
        end

        task.wait(THINK_INTERVAL_SECONDS)
    end
end

return StaffNpcComponent