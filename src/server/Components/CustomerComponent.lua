--!strict

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Component = require(ReplicatedStorage.Packages.Component)
local SimplePath = require(ReplicatedStorage.Packages.SimplePath)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

local CustomerMovementController = require(ServerScriptService.Server.Modules.CustomerMovementController)
local CustomerService = require(ServerScriptService.Server.Services.CustomerService)
local CrowdService = require(ServerScriptService.Server.Services.CrowdService)
local StoreNavigationService = require(ServerScriptService.Server.Services.StoreNavigationService)
local WorldQueryService = require(ServerScriptService.Server.Services.WorldQueryService)

local Animations = ReplicatedStorage:WaitForChild("Animations")

local CustomerComponent = Component.new({
	Tag = WorldTags.Customer,
	Ancestors = { Workspace },
})

local NPC_COLLISION_GROUP = "StoreNpc"

local collisionGroupReady = false
local destroyQueue: { Instance } = {}

RunService.Heartbeat:Connect(function()
	-- spread removing customer over multiple frames to prevent hitching
	local destroyBudget = 30

	for _ = 1, destroyBudget do
		local instance = table.remove(destroyQueue, 1)
		if not instance then
			break
		end

		instance:Destroy()
	end
end)

local function queueDestroy(instance: Instance)
	instance.Parent = nil
	if instance:IsA("Model") then
		local descendants = instance:GetDescendants()
		for _, descendant in ipairs(descendants) do
			table.insert(destroyQueue, descendant)
		end
		table.insert(destroyQueue, instance)
	else
		table.insert(destroyQueue, instance)
	end
end

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

local function listenForApplyingWalkAnimation(humanoid: Humanoid)
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local root = (humanoid.Parent :: Model):WaitForChild("HumanoidRootPart") :: BasePart

	local track = animator:LoadAnimation(Animations:WaitForChild("CustomerWalk"))
	track.Looped = true

	local isPlaying = false

	local function setWalking(walking: boolean)
		if walking == isPlaying then
			return
		end

		isPlaying = walking

		if walking then
			track:Play()
		else
			track:Stop()
		end
	end

	local connection = RunService.Heartbeat:Connect(function()
		local horizontalVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)

		setWalking(horizontalVelocity.Magnitude > 0.15)
	end)

	return connection, track
end

local function configureHumanoidForStoreMovement(humanoid: Humanoid)
	humanoid.AutoJumpEnabled = false
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.WalkSpeed = 5
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
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

local function hashString(value: string): number
	local hash = 0

	for index = 1, #value do
		hash = (hash * 31 + string.byte(value, index)) % 100000
	end

	return hash
end

type PathVisualizer = {
	SetRoute: (self: PathVisualizer, waypoints: { CFrame }) -> (),
	SetRouteIndex: (self: PathVisualizer, routeIndex: number) -> (),
	MarkEvent: (self: PathVisualizer, kind: string, position: Vector3, note: string?) -> (),
	SetSteerTargets: (self: PathVisualizer, moveTarget: Vector3?, guideTarget: Vector3?) -> (),
	SetCurrentPathTarget: (self: PathVisualizer, targetPosition: Vector3?) -> (),
	Destroy: (self: PathVisualizer) -> (),
}

type WaypointVisual = {
	part: Part,
	attachment: Attachment,
}

local DEBUG_FOLDER_NAME = "DebugCustomerPaths"
local DEBUG_MAX_EVENT_MARKERS = 40

local DEBUG_COLORS = {
	route = Color3.fromRGB(70, 170, 255),
	routeDone = Color3.fromRGB(70, 70, 70),
	next = Color3.fromRGB(255, 220, 90),
	currentTarget = Color3.fromRGB(120, 255, 120),
	steerMoveTarget = Color3.fromRGB(255, 120, 255),
	steerGuideTarget = Color3.fromRGB(255, 170, 70),
	blocked = Color3.fromRGB(255, 60, 60),
	error = Color3.fromRGB(255, 0, 150),
	correct = Color3.fromRGB(100, 255, 255),
	reroute = Color3.fromRGB(255, 255, 255),
}

local function debugGetOrCreateRootFolder(): Folder
	local existing = Workspace:FindFirstChild(DEBUG_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = DEBUG_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function debugMakeAnchorPart(
	name: string,
	position: Vector3,
	size: Vector3,
	color: Color3,
	transparency: number
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.CastShadow = false
	return part
end

local function debugMakeWaypointVisual(
	parent: Instance,
	name: string,
	cframe: CFrame,
	color: Color3,
	size: number
): WaypointVisual
	local p =
		debugMakeAnchorPart(name, cframe.Position + Vector3.new(0, 0.15, 0), Vector3.new(size, size, size), color, 0.1)
	p.Shape = Enum.PartType.Ball
	p.Parent = parent

	local att = Instance.new("Attachment")
	att.Name = "A"
	att.Parent = p

	return { part = p, attachment = att }
end

local function debugMakeBeam(
	parent: Instance,
	a0: Attachment,
	a1: Attachment,
	color: Color3,
	width: number,
	name: string
): Beam
	local beam = Instance.new("Beam")
	beam.Name = name
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = width
	beam.Width1 = width
	beam.Color = ColorSequence.new(color)
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Parent = parent
	return beam
end

local function debugMakeBillboard(parent: Instance, text: string, color: Color3)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Size = UDim2.fromOffset(180, 28)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 1.2, 0)
	bb.AlwaysOnTop = true
	bb.Parent = parent

	local tl = Instance.new("TextLabel")
	tl.BackgroundTransparency = 1
	tl.Size = UDim2.fromScale(1, 1)
	tl.Text = text
	tl.TextColor3 = color
	tl.TextStrokeTransparency = 0.2
	tl.Font = Enum.Font.GothamBold
	tl.TextScaled = true
	tl.Parent = bb
end

local function createPathVisualizer(customerId: string, rootPart: BasePart): PathVisualizer
	local root = debugGetOrCreateRootFolder()

	local folder = Instance.new("Folder")
	folder.Name = `Customer_{customerId}`
	folder.Parent = root

	local routeFolder = Instance.new("Folder")
	routeFolder.Name = "Route"
	routeFolder.Parent = folder

	local eventsFolder = Instance.new("Folder")
	eventsFolder.Name = "Events"
	eventsFolder.Parent = folder

	local dynamicFolder = Instance.new("Folder")
	dynamicFolder.Name = "Dynamic"
	dynamicFolder.Parent = folder

	local vis = {} :: any
	vis._folder = folder
	vis._routeFolder = routeFolder
	vis._eventsFolder = eventsFolder
	vis._dynamicFolder = dynamicFolder
	vis._rootPart = rootPart
	vis._routeIndex = 1
	vis._waypoints = {} :: { WaypointVisual }
	vis._beams = {} :: { Beam }
	vis._events = {} :: { Instance }
	vis._moveTarget = nil :: Vector3?
	vis._guideTarget = nil :: Vector3?
	vis._currentPathTarget = nil :: Vector3?

	local dynRoot =
		debugMakeWaypointVisual(dynamicFolder, "Root", CFrame.new(rootPart.Position), DEBUG_COLORS.next, 0.18)
	local dynTarget = debugMakeWaypointVisual(
		dynamicFolder,
		"Target",
		CFrame.new(rootPart.Position),
		DEBUG_COLORS.currentTarget,
		0.18
	)
	local dynBeam = debugMakeBeam(
		dynamicFolder,
		dynRoot.attachment,
		dynTarget.attachment,
		DEBUG_COLORS.currentTarget,
		0.16,
		"RootToTarget"
	)

	local dynMove = debugMakeWaypointVisual(
		dynamicFolder,
		"SteerMove",
		CFrame.new(rootPart.Position),
		DEBUG_COLORS.steerMoveTarget,
		0.16
	)
	dynMove.part.Transparency = 0.2
	local dynGuide = debugMakeWaypointVisual(
		dynamicFolder,
		"SteerGuide",
		CFrame.new(rootPart.Position),
		DEBUG_COLORS.steerGuideTarget,
		0.16
	)
	dynGuide.part.Transparency = 0.2

	local dynMoveBeam = debugMakeBeam(
		dynamicFolder,
		dynRoot.attachment,
		dynMove.attachment,
		DEBUG_COLORS.steerMoveTarget,
		0.12,
		"RootToMoveTarget"
	)
	local dynGuideBeam = debugMakeBeam(
		dynamicFolder,
		dynRoot.attachment,
		dynGuide.attachment,
		DEBUG_COLORS.steerGuideTarget,
		0.12,
		"RootToGuideTarget"
	)

	local heartbeatConn = RunService.Heartbeat:Connect(function()
		if not rootPart.Parent then
			return
		end

		local rootPos = rootPart.Position
		dynRoot.part.CFrame = CFrame.new(rootPos + Vector3.new(0, 0.15, 0))

		local targetPos = vis._currentPathTarget
		if targetPos then
			dynTarget.part.Transparency = 0.05
			dynBeam.Transparency = NumberSequence.new(0.05)
			dynTarget.part.CFrame = CFrame.new(targetPos + Vector3.new(0, 0.15, 0))
		else
			dynTarget.part.Transparency = 1
			dynBeam.Transparency = NumberSequence.new(1)
		end

		if vis._moveTarget then
			dynMove.part.Transparency = 0.25
			dynMoveBeam.Transparency = NumberSequence.new(0.2)
			dynMove.part.CFrame = CFrame.new(vis._moveTarget + Vector3.new(0, 0.15, 0))
		else
			dynMove.part.Transparency = 1
			dynMoveBeam.Transparency = NumberSequence.new(1)
		end

		if vis._guideTarget then
			dynGuide.part.Transparency = 0.25
			dynGuideBeam.Transparency = NumberSequence.new(0.2)
			dynGuide.part.CFrame = CFrame.new(vis._guideTarget + Vector3.new(0, 0.15, 0))
		else
			dynGuide.part.Transparency = 1
			dynGuideBeam.Transparency = NumberSequence.new(1)
		end
	end)

	function vis:SetRoute(waypoints: { CFrame })
		for _, beam in ipairs(vis._beams) do
			beam:Destroy()
		end
		for _, wp in ipairs(vis._waypoints) do
			wp.part:Destroy()
		end
		table.clear(vis._beams)
		table.clear(vis._waypoints)

		for i, cf in ipairs(waypoints) do
			vis._waypoints[i] = debugMakeWaypointVisual(routeFolder, `WP_{i}`, cf, DEBUG_COLORS.route, 0.25)
		end

		for i = 1, #vis._waypoints - 1 do
			vis._beams[i] = debugMakeBeam(
				routeFolder,
				vis._waypoints[i].attachment,
				vis._waypoints[i + 1].attachment,
				DEBUG_COLORS.route,
				0.18,
				`Seg_{i}`
			)
		end

		vis:SetRouteIndex(1)
	end

	function vis:SetRouteIndex(routeIndex: number)
		vis._routeIndex = math.max(1, routeIndex)

		for i, wp in ipairs(vis._waypoints) do
			if i < vis._routeIndex then
				wp.part.Color = DEBUG_COLORS.routeDone
				wp.part.Transparency = 0.55
			elseif i == vis._routeIndex then
				wp.part.Color = DEBUG_COLORS.next
				wp.part.Transparency = 0.05
			else
				wp.part.Color = DEBUG_COLORS.route
				wp.part.Transparency = 0.18
			end
		end

		for i, beam in ipairs(vis._beams) do
			if i < vis._routeIndex then
				beam.Color = ColorSequence.new(DEBUG_COLORS.routeDone)
				beam.Transparency = NumberSequence.new(0.6)
			elseif i == vis._routeIndex then
				beam.Color = ColorSequence.new(DEBUG_COLORS.next)
				beam.Transparency = NumberSequence.new(0.15)
			else
				beam.Color = ColorSequence.new(DEBUG_COLORS.route)
				beam.Transparency = NumberSequence.new(0.25)
			end
		end
	end

	function vis:SetSteerTargets(moveTarget: Vector3?, guideTarget: Vector3?)
		vis._moveTarget = moveTarget
		vis._guideTarget = guideTarget
	end

	function vis:SetCurrentPathTarget(targetPosition: Vector3?)
		vis._currentPathTarget = targetPosition
	end

	function vis:MarkEvent(kind: string, position: Vector3, note: string?)
		local color = (DEBUG_COLORS :: any)[kind] or Color3.fromRGB(255, 255, 255)
		local marker = debugMakeAnchorPart(
			`Event_{kind}`,
			position + Vector3.new(0, 0.25, 0),
			Vector3.new(0.28, 0.28, 0.28),
			color,
			0.05
		)
		marker.Shape = Enum.PartType.Ball
		marker.Parent = eventsFolder

		local labelText = if note and note ~= "" then `{kind}:{note}` else kind
		debugMakeBillboard(marker, labelText, color)

		table.insert(vis._events, marker)
		while #vis._events > DEBUG_MAX_EVENT_MARKERS do
			local old = table.remove(vis._events, 1)
			if old then
				old:Destroy()
			end
		end
	end

	function vis:Destroy()
		heartbeatConn:Disconnect()
		folder:Destroy()
	end

	return (vis :: any) :: PathVisualizer
end

function CustomerComponent:Construct()
	self.Model = self.Instance :: Model
	self.BusinessId = self.Instance:GetAttribute("BusinessId")
	self.CustomerId = self.Instance:GetAttribute("CustomerId")
	self.Running = false
	self.PathVisualizer = nil

	self.WalkConnection = nil
	self.WalkTrack = nil
	self.CleanedUp = false

	local humanoid = self.Model:FindFirstChild("Humanoid")
	local root = self.Model:FindFirstChild("HumanoidRootPart")

	self.Humanoid = if humanoid and humanoid:IsA("Humanoid") then humanoid else nil
	self.Root = if root and root:IsA("BasePart") then root else nil
end

function CustomerComponent:Cleanup()
	if self.CleanedUp then
		return
	end

	self.CleanedUp = true
	self.Running = false

	if self.Movement then
		self.Movement.moveToken += 1
	end

	if self.PathVisualizer then
		self.PathVisualizer:Destroy()
		self.PathVisualizer = nil
	end

	if self.WalkConnection then
		self.WalkConnection:Disconnect()
		self.WalkConnection = nil
	end

	if self.WalkTrack then
		self.WalkTrack:Stop(0)
		self.WalkTrack:Destroy()
		self.WalkTrack = nil
	end

	if typeof(self.CustomerId) == "string" then
		CrowdService.ReleaseCustomerReservations(self.CustomerId)
	end

	if self.Humanoid then
		self.Humanoid:Move(Vector3.zero)
	end
end

function CustomerComponent:Start()
	if typeof(self.BusinessId) ~= "string" or typeof(self.CustomerId) ~= "string" then
		self.Model:Destroy()
		return
	end

	if not self.Humanoid or not self.Root then
		self.Model:Destroy()
		return
	end

	self.Model.PrimaryPart = self.Root
	self.WalkConnection, self.WalkTrack = listenForApplyingWalkAnimation(self.Humanoid)
	configureHumanoidForStoreMovement(self.Humanoid)
	configureModelCollision(self.Model)

	local debugPath = self.Model:GetAttribute("DebugPath")
	--if debugPath == true then
	self.PathVisualizer = createPathVisualizer(self.CustomerId, self.Root)
	--end

	local path = SimplePath.new(self.Model, {
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
		AgentCanClimb = false,
		WaypointScaling = 2.5,
		Costs = {},
	}, {
		TIME_VARIANCE = 0.1,
		COMPARISON_CHECKS = 2,
		JUMP_WHEN_STUCK = false,
	})

	self.Movement = CustomerMovementController.new(
		self.Model,
		self.BusinessId,
		self.CustomerId,
		self.Humanoid,
		self.Root,
		path,
		self.Humanoid.WalkSpeed,
		self.PathVisualizer
	)

	self.Running = true
	task.spawn(function()
		self:RunStateMachine()
	end)
end

function CustomerComponent:Stop()
	self:Cleanup()
end

function CustomerComponent:SetState(stateName: string)
	self.Model:SetAttribute("CustomerState", stateName)
end

function CustomerComponent:FaceCFrame(targetCFrame: CFrame)
	if not self.Root then
		return
	end

	local targetPosition = targetCFrame.Position
	local flatTarget = Vector3.new(targetPosition.X, self.Root.Position.Y, targetPosition.Z)
	if (flatTarget - self.Root.Position).Magnitude < 0.1 then
		return
	end

	self.Model:PivotTo(CFrame.lookAt(self.Root.Position, flatTarget))
end

function CustomerComponent:GetRunning(): boolean
	return self.Running
end

function CustomerComponent:SnapToBrowseCFrame(browseCFrame: CFrame)
	if not self.Root or not self.Humanoid then
		return
	end

	local rootPosition = self.Root.Position
	local targetPosition = browseCFrame.Position

	local flatRoot = Vector3.new(rootPosition.X, 0, rootPosition.Z)
	local flatTarget = Vector3.new(targetPosition.X, 0, targetPosition.Z)
	local distance = (flatRoot - flatTarget).Magnitude

	if distance > 3 then
		return
	end

	self.Humanoid:Move(Vector3.zero)

	local finalPosition = Vector3.new(targetPosition.X, rootPosition.Y, targetPosition.Z)
	local lookVector = browseCFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)

	if flatLook.Magnitude < 0.05 then
		return
	end

	self.Model:PivotTo(CFrame.lookAt(finalPosition, finalPosition + flatLook.Unit))
end

function CustomerComponent:MoveToCFrame(targetCFrame: CFrame, buildRoute: ((Vector3) -> { CFrame })?): boolean
	if not self.Movement or not self.Root then
		return false
	end

	local routeBuilder = buildRoute
		or function(fromPosition: Vector3)
			return StoreNavigationService.FindRouteBetweenPositions(
				self.BusinessId,
				fromPosition,
				targetCFrame.Position,
				nil
			)
		end

	CrowdService.ReserveMovementPosition(self.CustomerId, targetCFrame.Position, 8)

	return self.Movement:MoveToTarget(targetCFrame, routeBuilder, function()
		return self:GetRunning()
	end)
end

function CustomerComponent:FaceBrowseCFrame(browseCFrame: CFrame)
	if not self.Root then
		return
	end

	local lookVector = browseCFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)

	if flatLook.Magnitude < 0.05 then
		return
	end

	local rootPosition = self.Root.Position
	local targetPosition = rootPosition + flatLook.Unit

	self.Model:PivotTo(CFrame.lookAt(rootPosition, Vector3.new(targetPosition.X, rootPosition.Y, targetPosition.Z)))
end

function CustomerComponent:BrowseShelf(shelfId: string): "Cart" | "Ignore" | "Steal" | "Leave"
	local slotIndex = CrowdService.ReserveShelfSlot(self.BusinessId, shelfId, self.CustomerId, 24)

	if not slotIndex then
		return "Ignore"
	end

	local browseCFrame = WorldQueryService.GetShelfBrowseCFrame(self.BusinessId, shelfId, slotIndex)

	if not browseCFrame then
		CrowdService.ReleaseCustomerReservations(self.CustomerId)
		return "Ignore"
	end

	self.Model:SetAttribute("TargetShelfId", shelfId)
	self.Model:SetAttribute("BrowseSlotIndex", slotIndex)

	self:SetState("WalkingToShelf")

	local routeBuilder = function(fromPosition: Vector3)
		return StoreNavigationService.FindRouteToShelf(self.BusinessId, fromPosition, shelfId, browseCFrame)
	end

	if not self:MoveToCFrame(browseCFrame, routeBuilder) then
		CrowdService.ReleaseCustomerReservations(self.CustomerId)
		return "Ignore"
	end

	self:SnapToBrowseCFrame(browseCFrame)
	self:SetState("Browsing")
	--self:FaceBrowseCFrame(browseCFrame)

	CrowdService.RefreshReservation(self.CustomerId, 12)

	local browseTime = self:GetCustomerDelay(2.5, 5.5, `browse:{shelfId}`)
	CrowdService.RefreshReservation(self.CustomerId, browseTime + 4)

	if not self:WaitInPlace("Browsing", 2.5, 5.5, `browse:{shelfId}`) then
		CrowdService.ReleaseCustomerReservations(self.CustomerId)
		return "Leave"
	end

	local result = CustomerService.ConsiderBrowsedShelf(self.BusinessId, self.CustomerId, shelfId, self.Model)

	CrowdService.ReleaseCustomerReservations(self.CustomerId)

	return result :: "Cart" | "Ignore" | "Steal" | "Leave"
end

function CustomerComponent:GetCustomerDelay(minSeconds: number, maxSeconds: number, salt: string): number
	local alpha = (hashString(`{self.CustomerId}:{salt}`) % 1000) / 1000
	return minSeconds + (maxSeconds - minSeconds) * alpha
end

function CustomerComponent:WaitInPlace(stateName: string, minSeconds: number, maxSeonds: number, salt: string): boolean
	if not self.Running then
		return false
	end

	self:SetState(stateName)

	if self.Humanoid then
		self.Humanoid:Move(Vector3.zero)
	end

	local duration = self:GetCustomerDelay(minSeconds, maxSeonds, salt)
	local endTime = os.clock() + duration

	while self.Running and os.clock() < endTime do
		task.wait(0.15)
	end

	return self.Running
end

function CustomerComponent:MoveToCheckout(): boolean
	self:SetState("WalkingToCheckout")

	local preferredSlot = CustomerService.GetCheckoutQueueSlot(self.BusinessId, self.CustomerId)
	local queueSlot = CrowdService.ReserveCheckoutSlot(self.BusinessId, self.CustomerId, preferredSlot, 60)
		or preferredSlot

	local checkoutCFrame = WorldQueryService.GetCheckoutQueueCFrame(self.BusinessId, queueSlot)

	local routeBuilder = function(fromPosition: Vector3)
		return StoreNavigationService.FindRouteToCheckout(self.BusinessId, fromPosition, checkoutCFrame)
	end

	return self:MoveToCFrame(checkoutCFrame, routeBuilder)
end

function CustomerComponent:MoveToExit(): boolean
	self:SetState("WalkingToExit")
	local exitCFrame = WorldQueryService.GetExitCFrame(self.BusinessId)

	local routeBuilder = function(fromPosition: Vector3)
		return StoreNavigationService.FindRouteToExit(self.BusinessId, fromPosition, exitCFrame)
	end

	return self:MoveToCFrame(exitCFrame, routeBuilder)
end

function CustomerComponent:RunBrowsingLoop(): "Checkout" | "Steal" | "Leave"
	local route = CustomerService.BuildPhysicalBrowseRoute(self.BusinessId, self.CustomerId)
	if #route == 0 then
		return "Leave"
	end

	for _, shelfId in ipairs(route) do
		if not self.Running then
			return "Leave"
		end

		local result = self:BrowseShelf(shelfId)
		if result == "Steal" or result == "Leave" then
			return result
		end

		if CustomerService.HasCartItems(self.BusinessId, self.CustomerId) and math.random() < 0.28 then
			return "Checkout"
		end
	end

	if CustomerService.HasCartItems(self.BusinessId, self.CustomerId) then
		return "Checkout"
	end

	return "Leave"
end

function CustomerComponent:RunStateMachine()
	self:SetState("Entering")

	local nextAction = self:RunBrowsingLoop()
	if not self.Running then
		return
	end

	if nextAction == "Checkout" then
		if CustomerService.EnterPhysicalCheckoutQueue(self.BusinessId, self.CustomerId) and self:MoveToCheckout() then
			if self:WaitInPlace("WaitingAtCheckout", 2.5, 4.5, "checkout") then
				self:SetState("Paying")
				task.wait(0.8)

				if self.Running then
					CustomerService.TryCompletePhysicalPurchase(self.BusinessId, self.CustomerId)
				end
			else
				CustomerService.LeavePhysicalCheckoutQueue(self.BusinessId, self.CustomerId)
			end
		end
	elseif nextAction == "Steal" then
		CustomerService.TryStartPhysicalTheft(self.BusinessId, self.CustomerId, self.Model)
	end

	local exited = false

	if self.Running then
		exited = self:MoveToExit()
	end

	if not exited then
		warn(`Customer {self.CustomerId} failed to exit cleanly`)
		task.wait(2)
	end

	CustomerService.DespawnPhysicalCustomer(self.BusinessId, self.CustomerId)
	queueDestroy(self.Model)
end

return CustomerComponent
