--!strict

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Component = require(ReplicatedStorage.Packages.Component)
local SimplePath = require(ReplicatedStorage.Packages.SimplePath)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

local MovementHelper = require(ServerScriptService.Server.Modules.MovementHelper)
local CustomerService = require(ServerScriptService.Server.Services.CustomerService)
local CheckoutService = require(ServerScriptService.Server.Services.CheckoutService)
local CrowdService = require(ServerScriptService.Server.Services.CrowdService)
local StoreNavigationService = require(ServerScriptService.Server.Services.StoreNavigationService)
local WorldQueryService = require(ServerScriptService.Server.Services.WorldQueryService)

local Animations = ReplicatedStorage:WaitForChild("Animations")
local Billboards = ReplicatedStorage:WaitForChild("Billboards")

local EmotionBillboard = Billboards:WaitForChild("Emotion")

local CustomerComponent = Component.new({
	Tag = WorldTags.Customer,
	Ancestors = { Workspace },
})

local NPC_COLLISION_GROUP = "StoreNpc"

local collisionGroupReady = false
local destroyQueue: { Instance } = {}

local ARRIVAL_TURN_SPEED = 9
local ARRIVAL_TURN_TIMEOUT = 0.45
local ARRIVAL_TURN_STEP = 1 / 60

local SHELF_DEPART_DISTANCE = 4.5
local GPU_HOLD_SECONDS = 1
local GPU_HAND_OFFSET = CFrame.new(0, -0.25, -0.45) * CFrame.Angles(0, math.rad(90), 0)

local GPU_GRAB_ANIMATION_NAME = "CustomerGrabGpu"
local GPU_PICKUP_MARKER = "Pickup"
local GPU_HIDE_MARKER = "Hide"

local GPU_PICKUP_FALLBACK_SECONDS = 0.45
local GPU_HIDE_FALLBACK_SECONDS = 1.15
local GPU_MIN_VISIBLE_SECONDS = 1.5

local GPU_RIGHT_GRIP_ATTACHMENT_NAME = "CustomerRightGripAttachment"

type CustomerShelfEmotion =
	"Bought"
	| "BoughtWanted"
	| "BoughtBargain"
	| "WantedGpu"
	| "GoodPrice"
	| "OutOfStock"
	| "TooExpensive"
	| "NotInterested"
	| "Leaving"
	| "Stealing"
	| "QueueAngry"

local EMOTION_SHOW_SECONDS = 2.4
local EMOTION_OUTRO_SECONDS = 0.18
local EMOTION_INTRO_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local EMOTION_OUTRO_TWEEN = TweenInfo.new(EMOTION_OUTRO_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local EMOTION_CHANCES: { [CustomerShelfEmotion]: number } = {
	Bought = 0.75,
	BoughtWanted = 1,
	BoughtBargain = 0.95,
	WantedGpu = 0.85,
	GoodPrice = 0.7,
	OutOfStock = 0.85,
	TooExpensive = 0.65,
	NotInterested = 0.35,
	Leaving = 0.8,
	Stealing = 0.65,
	QueueAngry = 1,
}

local EMOTION_COLORS: { [CustomerShelfEmotion]: Color3 } = {
	Bought = Color3.fromRGB(245, 245, 255),
	BoughtWanted = Color3.fromRGB(120, 255, 170),
	BoughtBargain = Color3.fromRGB(120, 220, 255),
	WantedGpu = Color3.fromRGB(150, 255, 170),
	GoodPrice = Color3.fromRGB(120, 220, 255),
	OutOfStock = Color3.fromRGB(255, 120, 120),
	TooExpensive = Color3.fromRGB(255, 190, 105),
	NotInterested = Color3.fromRGB(210, 215, 225),
	Leaving = Color3.fromRGB(255, 150, 110),
	Stealing = Color3.fromRGB(255, 105, 150),
	QueueAngry = Color3.fromRGB(255, 115, 95),
}

local EMOTION_PHRASES: { [CustomerShelfEmotion]: { string } } = {
	Bought = {
		"I'll take this one.",
		"Looks good enough.",
		"This should work.",
	},
	BoughtWanted = {
		"That's the one I wanted.",
		"Perfect, it's in stock.",
		"Exactly what I came for.",
	},
	BoughtBargain = {
		"Great price.",
		"That's a solid deal.",
		"Can't pass that up.",
	},
	WantedGpu = {
		"They have it.",
		"That's on my list.",
		"I was looking for this.",
	},
	GoodPrice = {
		"Nice price.",
		"That deal is tempting.",
		"Cheaper than expected.",
	},
	OutOfStock = {
		"Already sold out?",
		"Nothing left here.",
		"I missed it.",
	},
	TooExpensive = {
		"Too pricey.",
		"That's over budget.",
		"I can't justify that.",
	},
	NotInterested = {
		"Not what I need.",
		"I'll keep looking.",
		"Maybe another shelf.",
	},
	Leaving = {
		"I'm done here.",
		"Nothing worth buying.",
		"I'll try somewhere else.",
	},
	Stealing = {
		"No one is watching.",
		"Maybe I can sneak this.",
		"Too tempting.",
	},
	QueueAngry = {
		"This line isn't moving.",
		"I don't have all day.",
		"I'm done waiting.",
		"Forget it, I'm leaving.",
	},
}

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

local function scaleUDim2(size: UDim2, scale: number): UDim2
	return UDim2.new(size.X.Scale * scale, size.X.Offset * scale, size.Y.Scale * scale, size.Y.Offset * scale)
end

local function getEmotionPhrase(emotion: CustomerShelfEmotion): string
	local phrases = EMOTION_PHRASES[emotion]
	return phrases[math.random(1, #phrases)]
end

local function getEmotionParent(customerModel: Model, root: BasePart?): BasePart?
	local head = customerModel:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		return head
	end

	return root
end

local function getEmotionPrompt(billboard: BillboardGui): TextLabel?
	local prompt = billboard:FindFirstChild("Prompt", true)
	if prompt and prompt:IsA("TextLabel") then
		return prompt
	end

	for _, descendant in billboard:GetDescendants() do
		if descendant:IsA("TextLabel") then
			return descendant
		end
	end

	return nil
end

local function playGuiFadeIn(billboard: BillboardGui)
	for _, descendant in billboard:GetDescendants() do
		if descendant:IsA("Frame") then
			local targetTransparency = descendant.BackgroundTransparency
			descendant.BackgroundTransparency = 1
			TweenService:Create(descendant, EMOTION_INTRO_TWEEN, { BackgroundTransparency = targetTransparency }):Play()
		elseif descendant:IsA("TextLabel") then
			local targetTextTransparency = descendant.TextTransparency
			local targetStrokeTransparency = descendant.TextStrokeTransparency
			descendant.TextTransparency = 1
			descendant.TextStrokeTransparency = 1
			TweenService:Create(descendant, EMOTION_INTRO_TWEEN, {
				TextTransparency = targetTextTransparency,
				TextStrokeTransparency = targetStrokeTransparency,
			}):Play()
		elseif descendant:IsA("ImageLabel") then
			local targetImageTransparency = descendant.ImageTransparency
			descendant.ImageTransparency = 1
			TweenService:Create(descendant, EMOTION_INTRO_TWEEN, { ImageTransparency = targetImageTransparency }):Play()
		end
	end
end

local function playGuiFadeOut(billboard: BillboardGui)
	for _, descendant in billboard:GetDescendants() do
		if descendant:IsA("Frame") then
			TweenService:Create(descendant, EMOTION_OUTRO_TWEEN, { BackgroundTransparency = 1 }):Play()
		elseif descendant:IsA("TextLabel") then
			TweenService:Create(descendant, EMOTION_OUTRO_TWEEN, {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			}):Play()
		elseif descendant:IsA("ImageLabel") then
			TweenService:Create(descendant, EMOTION_OUTRO_TWEEN, { ImageTransparency = 1 }):Play()
		end
	end
end

local function normalizeGpuId(value: string): string
	local normalized = string.lower(value)
	normalized = string.gsub(normalized, "[^%w]+", "_")
	normalized = string.gsub(normalized, "^_+", "")
	normalized = string.gsub(normalized, "_+$", "")
	return normalized
end

local function getGpuModelCFrame(model: Model): CFrame?
	if model.PrimaryPart then
		return model.PrimaryPart.CFrame
	end

	local firstPart = model:FindFirstChildWhichIsA("BasePart", true)
	if firstPart then
		return firstPart.CFrame
	end

	return nil
end

local function getGpuModelProductId(model: Model): string?
	local productId = model:GetAttribute("GpuProductId")
	if typeof(productId) == "string" then
		return normalizeGpuId(productId)
	end

	local gpuId = model:GetAttribute("GpuId")
	if typeof(gpuId) == "string" then
		local normalizedGpuId = normalizeGpuId(gpuId)
		if normalizedGpuId == normalizeGpuId(model.Name) then
			return normalizedGpuId
		end
	end

	return normalizeGpuId(model.Name)
end

local function getGpuHoldPart(customerModel: Model): BasePart?
	local rightHand = customerModel:FindFirstChild("RightHand", true)
	if rightHand and rightHand:IsA("BasePart") then
		return rightHand
	end

	local rightArm = customerModel:FindFirstChild("Right Arm", true)
	if rightArm and rightArm:IsA("BasePart") then
		return rightArm
	end

	local root = customerModel:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

local function prepareGpuModelForHolding(model: Model): BasePart?
	local holdPart = model.PrimaryPart

	if not holdPart then
		local handle = model:FindFirstChild("Handle", true)
		if handle and handle:IsA("BasePart") then
			holdPart = handle
		end
	end

	if not holdPart then
		holdPart = model:FindFirstChildWhichIsA("BasePart", true)
	end

	if not holdPart then
		return nil
	end

	model.PrimaryPart = holdPart

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
			descendant.Transparency = 0

			if descendant ~= holdPart then
				local existingWeld = descendant:FindFirstChild("GpuModelHoldWeld")
				if not existingWeld then
					local weld = Instance.new("WeldConstraint")
					weld.Name = "GpuModelHoldWeld"
					weld.Part0 = holdPart
					weld.Part1 = descendant
					weld.Parent = descendant
				end
			end
		end
	end

	return holdPart
end

local function getCharacterPart(customerModel: Model, names: { string }): BasePart?
	for _, name in ipairs(names) do
		local found = customerModel:FindFirstChild(name, true)
		if found and found:IsA("BasePart") then
			return found
		end
	end

	return nil
end

local function getAnimator(humanoid: Humanoid): Animator?
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	local found = humanoid:FindFirstChild("Animator")
	if found and found:IsA("Animator") then
		return found
	end

	return nil
end

local function playActionAnimation(humanoid: Humanoid, animationName: string): AnimationTrack?
	local animator = getAnimator(humanoid)
	if not animator then
		return nil
	end

	local animation = Animations:FindFirstChild(animationName)
	if not animation or not animation:IsA("Animation") then
		warn(`Missing customer animation: {animationName}`)
		return nil
	end

	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(0.12)

	return track
end

local function waitForAnimationMarker(track: AnimationTrack?, markerName: string, fallbackSeconds: number): boolean
	if not track then
		task.wait(fallbackSeconds)
		return false
	end

	local markerReached = false
	local trackStopped = false

	local markerConnection = track:GetMarkerReachedSignal(markerName):Connect(function()
		markerReached = true
	end)

	local stoppedConnection = track.Stopped:Connect(function()
		trackStopped = true
	end)

	local deadline = os.clock() + fallbackSeconds

	while not markerReached and not trackStopped and os.clock() < deadline do
		RunService.Heartbeat:Wait()
	end

	markerConnection:Disconnect()
	stoppedConnection:Disconnect()

	return markerReached
end

local function findAttachment(root: Instance, attachmentName: string): Attachment?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == attachmentName then
			return descendant
		end
	end

	return nil
end

local function pivotModelAttachmentToWorld(model: Model, attachment: Attachment, targetWorldCFrame: CFrame)
	local currentPivot = model:GetPivot()
	local attachmentOffsetFromPivot = currentPivot:ToObjectSpace(attachment.WorldCFrame)

	model:PivotTo(targetWorldCFrame * attachmentOffsetFromPivot:Inverse())
end

local function getGpuRightHand(customerModel: Model): BasePart?
	local rightHand = customerModel:FindFirstChild("RightHand", true)
	if rightHand and rightHand:IsA("BasePart") then
		return rightHand
	end

	local rightArm = customerModel:FindFirstChild("Right Arm", true)
	if rightArm and rightArm:IsA("BasePart") then
		return rightArm
	end

	warn(`Customer {customerModel.Name} has no RightHand or Right Arm for GPU hold`)
	return nil
end

local function attachGpuToRightHand(gpuModel: Model, gpuHoldPart: BasePart, rightHand: BasePart)
	local handGrip = findAttachment(rightHand, "RightGripAttachment")
	local gpuGrip = findAttachment(gpuModel, GPU_RIGHT_GRIP_ATTACHMENT_NAME)

	if handGrip and gpuGrip then
		pivotModelAttachmentToWorld(gpuModel, gpuGrip, handGrip.WorldCFrame)
	else
		gpuModel:PivotTo(rightHand.CFrame * GPU_HAND_OFFSET)
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CustomerGpuHoldWeld"
	weld.Part0 = rightHand
	weld.Part1 = gpuHoldPart
	weld.Parent = gpuHoldPart
end

local function chooseNearestShelfGpuModel(
	businessId: string,
	shelfId: string,
	desiredGpuId: string?,
	customerPosition: Vector3
): Model?
	local gpuFolder = WorldQueryService.GetShelfGpuFolder(businessId, shelfId)
	if not gpuFolder then
		return nil
	end

	local normalizedDesiredGpuId = if desiredGpuId then normalizeGpuId(desiredGpuId) else nil
	local bestModel: Model? = nil
	local bestDistance = math.huge

	local function considerModel(model: Model, requireProductMatch: boolean)
		local modelCFrame = getGpuModelCFrame(model)
		if not modelCFrame then
			return
		end

		if requireProductMatch and normalizedDesiredGpuId then
			local productId = getGpuModelProductId(model)
			if productId ~= normalizedDesiredGpuId then
				return
			end
		end

		local distance = (modelCFrame.Position - customerPosition).Magnitude
		if distance < bestDistance then
			bestModel = model
			bestDistance = distance
		end
	end

	if normalizedDesiredGpuId then
		for _, child in gpuFolder:GetChildren() do
			if child:IsA("Model") then
				considerModel(child, true)
			end
		end
	end

	if not bestModel then
		for _, child in gpuFolder:GetChildren() do
			if child:IsA("Model") then
				considerModel(child, false)
			end
		end
	end

	return bestModel
end

local function ensureCollisionGroup()
	if collisionGroupReady then
		return
	end

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

local function getFlatUnit(vector: Vector3): Vector3?
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 0.05 then
		return nil
	end
	return flat.Unit
end

local function getFlatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function cframeLookingAt(position: Vector3, direction: Vector3): CFrame
	local flatDirection = getFlatUnit(direction)
	if not flatDirection then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, position + flatDirection)
end

type PathVisualizer = {
	SetRoute: (self: PathVisualizer, waypoints: { CFrame }) -> (),
	SetRouteIndex: (self: PathVisualizer, routeIndex: number) -> (),
	MarkEvent: (self: PathVisualizer, kind: string, position: Vector3, note: string?) -> (),
	SetSteerTargets: (self: PathVisualizer, moveTarget: Vector3?, guideTarget: Vector3?) -> (),
	SetCurrentPathTarget: (self: PathVisualizer, targetPosition: Vector3?) -> (),
	SetStatus: (self: PathVisualizer, status: string) -> (),
	Destroy: (self: PathVisualizer) -> (),
}

type WaypointVisual = {
	part: Part,
	attachment: Attachment,
}

local DEBUG_FOLDER_NAME = "DebugCustomerPaths"
local DEBUG_MAX_EVENT_MARKERS = 40
local CHECKOUT_SLOT_REACH_DISTANCE = 0.5
local CHECKOUT_SLOT_ARRIVAL_DISTANCE = 1.6
local CHECKOUT_IDLE_BASE_SECONDS = 10
local CHECKOUT_IDLE_ROLL_INTERVAL = 2.5

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

	-- local statusGui = Instance.new("BillboardGui")
	-- statusGui.Name = "Thinking"
	-- statusGui.Size = UDim2.fromScale(4, 2)
	-- statusGui.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
	-- statusGui.AlwaysOnTop = true
	-- statusGui.Parent = rootPart

	-- local statusFrame = Instance.new("Frame")
	-- statusFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
	-- statusFrame.BackgroundTransparency = 0.25
	-- statusFrame.BorderSizePixel = 0
	-- statusFrame.Size = UDim2.fromScale(1, 1)
	-- statusFrame.Parent = statusGui

	-- local statusCorner = Instance.new("UICorner")
	-- statusCorner.CornerRadius = UDim.new(0.15, 0)
	-- statusCorner.Parent = statusFrame

	-- local statusTitle = Instance.new("TextLabel")
	-- statusTitle.BackgroundTransparency = 1
	-- statusTitle.Position = UDim2.fromScale(0.05, 0.04)
	-- statusTitle.Size = UDim2.fromScale(0.6, 0.2)
	-- statusTitle.Font = Enum.Font.GothamBold
	-- statusTitle.TextScaled = true
	-- statusTitle.TextXAlignment = Enum.TextXAlignment.Left
	-- statusTitle.TextColor3 = Color3.fromRGB(230, 235, 255)
	-- statusTitle.TextStrokeTransparency = 0.7
	-- statusTitle.Text = `Customer {customerId}`
	-- statusTitle.Parent = statusFrame

	-- local statusText = Instance.new("TextLabel")
	-- statusText.BackgroundTransparency = 1
	-- statusText.Position = UDim2.fromScale(0.05, 0.3)
	-- statusText.Size = UDim2.fromScale(0.8, 0.15)
	-- statusText.Font = Enum.Font.Gotham
	-- statusText.TextScaled = true
	-- statusText.TextXAlignment = Enum.TextXAlignment.Left
	-- statusText.TextYAlignment = Enum.TextYAlignment.Top
	-- statusText.TextColor3 = Color3.fromRGB(210, 215, 230)
	-- statusText.TextStrokeTransparency = 0.85
	-- statusText.TextWrapped = true
	-- statusText.RichText = false
	-- statusText.Text = "planning..."
	-- statusText.Parent = statusFrame

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

	function vis:SetStatus(status: string)
		--statusText.Text = status
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
		--statusGui:Destroy()
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
	self.CheckoutQueueSlot = nil
	self._emotionToken = 0
	self._emotionBillboard = nil

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
	self._emotionToken += 1

	if self._emotionBillboard then
		self._emotionBillboard:Destroy()
		self._emotionBillboard = nil
	end

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
	if typeof(self.BusinessId) == "string" and typeof(self.CustomerId) == "string" then
		CheckoutService.CancelCheckoutInteraction(self.BusinessId, self.CustomerId)
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

	self.Humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	self.Model.PrimaryPart = self.Root
	self.WalkConnection, self.WalkTrack = listenForApplyingWalkAnimation(self.Humanoid)
	configureHumanoidForStoreMovement(self.Humanoid)
	configureModelCollision(self.Model)

	local debugPath = self.Model:GetAttribute("DebugPath")
	--if debugPath == true then
	self.PathVisualizer = createPathVisualizer(self.CustomerId, self.Root)
	--end

	local path = SimplePath.new(self.Model, {
		AgentRadius = 3.5,
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

	self.Movement = MovementHelper.new(
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

function CustomerComponent:SnapFaceToCFrame(targetCFrame: CFrame)
	if not self.Root or not self.Humanoid then
		return
	end

	local targetLook = targetCFrame.LookVector
	local flatLook = Vector3.new(targetLook.X, 0, targetLook.Z)

	if flatLook.Magnitude < 0.05 then
		return
	end

	self.Humanoid:Move(Vector3.zero)
	self.Humanoid.AutoRotate = false
	self.Root.AssemblyLinearVelocity = Vector3.zero
	self.Root.AssemblyAngularVelocity = Vector3.zero

	local rootPosition = self.Root.Position
	local flatTarget = rootPosition + flatLook.Unit
	self.Model:PivotTo(CFrame.lookAt(rootPosition, Vector3.new(flatTarget.X, rootPosition.Y, flatTarget.Z), Vector3.yAxis))
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

function CustomerComponent:GetDepartCFrameFromCurrentFacing(): CFrame?
	if not self.Root then
		return nil
	end

	local currentPosition = self.Root.Position
	local backward = -self.Root.CFrame.LookVector
	local flatBackward = Vector3.new(backward.X, 0, backward.Z)

	if flatBackward.Magnitude < 0.05 then
		return nil
	end

	local departPosition = currentPosition + flatBackward.Unit * SHELF_DEPART_DISTANCE
	return CFrame.new(departPosition)
end

function CustomerComponent:MoveToCFrame(
	targetCFrame: CFrame,
	buildRoute: ((Vector3) -> { CFrame })?,
	canContinue: (() -> boolean)?,
	finalReachDistance: number?,
	moveMode: "Shelf" | "Checkout" | "Exit"?
): boolean
	if not self.Movement or not self.Root then
		return false
	end

	self:AllowMovementRotation()

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
		return self:GetRunning() and (if canContinue then canContinue() else true)
	end, finalReachDistance, moveMode)
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

function CustomerComponent:ShowEmotion(emotion: CustomerShelfEmotion)
	if not self.Running then
		return
	end

	local chance = EMOTION_CHANCES[emotion] or 0.5
	if math.random() > chance then
		return
	end

	local parent = getEmotionParent(self.Model, self.Root)
	if not parent then
		return
	end

	local billboard = EmotionBillboard:Clone()
	if not billboard:IsA("BillboardGui") then
		billboard:Destroy()
		return
	end

	self._emotionToken += 1
	local emotionToken = self._emotionToken

	if self._emotionBillboard then
		self._emotionBillboard:Destroy()
		self._emotionBillboard = nil
	end

	local prompt = getEmotionPrompt(billboard)
	if prompt then
		prompt.Text = getEmotionPhrase(emotion)
		--prompt.TextColor3 = EMOTION_COLORS[emotion] or Color3.fromRGB(245, 245, 255)
	end

	local targetSize = billboard.Size
	if
		targetSize.X.Scale == 0
		and targetSize.X.Offset == 0
		and targetSize.Y.Scale == 0
		and targetSize.Y.Offset == 0
	then
		targetSize = UDim2.fromOffset(220, 72)
	end

	local targetOffset = billboard.StudsOffsetWorldSpace
	if targetOffset.Magnitude < 0.05 then
		targetOffset = Vector3.new(0, 1.8, 0)
	end

	billboard.Enabled = true
	billboard.AlwaysOnTop = true
	billboard.Size = scaleUDim2(targetSize, 0.75)
	billboard.StudsOffsetWorldSpace = targetOffset - Vector3.new(0, 0.25, 0)
	billboard.Parent = parent
	self._emotionBillboard = billboard

	playGuiFadeIn(billboard)
	TweenService:Create(billboard, EMOTION_INTRO_TWEEN, {
		Size = targetSize,
		StudsOffsetWorldSpace = targetOffset,
	}):Play()

	task.delay(EMOTION_SHOW_SECONDS, function()
		if emotionToken ~= self._emotionToken or self._emotionBillboard ~= billboard then
			return
		end

		playGuiFadeOut(billboard)
		TweenService:Create(billboard, EMOTION_OUTRO_TWEEN, {
			Size = scaleUDim2(targetSize, 0.85),
			StudsOffsetWorldSpace = targetOffset,
		}):Play()

		task.delay(EMOTION_OUTRO_SECONDS, function()
			if emotionToken ~= self._emotionToken or self._emotionBillboard ~= billboard then
				return
			end

			self._emotionBillboard = nil
			billboard:Destroy()
		end)
	end)
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

	-- local currentState = self.Model:GetAttribute("CustomerState")

	-- if currentState == "Browsing" then
	-- 	local departCFrame = self:GetDepartCFrameFromCurrentFacing()

	-- 	if departCFrame then
	-- 		local departRouteBuilder = function(fromPosition: Vector3)
	-- 			return StoreNavigationService.FindRouteBetweenPositions(
	-- 				self.BusinessId,
	-- 				fromPosition,
	-- 				departCFrame.Position,
	-- 				nil
	-- 			)
	-- 		end

	-- 		self:MoveToCFrame(departCFrame, departRouteBuilder, nil, 1.8, "Shelf")
	-- 	end
	-- end

	self:SetState("WalkingToShelf")

	local routeBuilder = function(fromPosition: Vector3)
		return StoreNavigationService.FindRouteToShelf(self.BusinessId, fromPosition, shelfId, browseCFrame)
	end

	if not self:MoveToCFrame(browseCFrame, routeBuilder, nil, nil, "Shelf") then
		CrowdService.ReleaseCustomerReservations(self.CustomerId)
		return "Ignore"
	end

	self:SmoothFaceCFrame(browseCFrame, 0.35)
	self:SetState("Browsing")
	--self:FaceBrowseCFrame(browseCFrame)

	CrowdService.RefreshReservation(self.CustomerId, 12)

	local browseTime = self:GetCustomerDelay(2.5, 5.5, `browse:{shelfId}`)
	CrowdService.RefreshReservation(self.CustomerId, browseTime + 4)

	if not self:WaitInPlace("Browsing", 2.5, 5.5, `browse:{shelfId}`) then
		CrowdService.ReleaseCustomerReservations(self.CustomerId)
		return "Leave"
	end

	local result, emotion = CustomerService.ConsiderBrowsedShelf(self.BusinessId, self.CustomerId, shelfId, self.Model)
	if emotion then
		self:ShowEmotion(emotion)
	end

	if result == "Cart" then
		self:GrabShelfGpu(shelfId)
	end

	CrowdService.ReleaseCustomerReservations(self.CustomerId)

	return result :: "Cart" | "Ignore" | "Steal" | "Leave"
end

function CustomerComponent:GetCustomerDelay(minSeconds: number, maxSeconds: number, salt: string): number
	local alpha = (hashString(`{self.CustomerId}:{salt}`) % 1000) / 1000
	return minSeconds + (maxSeconds - minSeconds) * alpha
end

function CustomerComponent:GetCheckoutIdleLeaveSeconds(): number
	local customer = CustomerService.GetCustomer(self.BusinessId, self.CustomerId)
	local patience = if customer then customer.profile.patience else 75
	local normalizedPatience = math.clamp((patience - 35) / 80, 0, 1)
	local jitter = self:GetCustomerDelay(0, 5, "checkout-idle-threshold")

	return CHECKOUT_IDLE_BASE_SECONDS + normalizedPatience * 18 + jitter
end

function CustomerComponent:GetCheckoutIdleLeaveChance(rollCount: number): number
	local customer = CustomerService.GetCustomer(self.BusinessId, self.CustomerId)
	local patience = if customer then customer.profile.patience else 75
	local normalizedPatience = math.clamp((patience - 35) / 80, 0, 1)
	local rush = 1 - normalizedPatience

	return math.clamp(0.18 + rush * 0.55 + math.max(0, rollCount - 1) * 0.08, 0.12, 0.9)
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

function CustomerComponent:GrabShelfGpu(shelfId: string): boolean
	if not self.Running or not self.Root then
		return false
	end

	local customer = CustomerService.GetCustomer(self.BusinessId, self.CustomerId)
	local desiredGpuId = if customer then customer.desiredGpuId else nil

	local gpuModel = chooseNearestShelfGpuModel(self.BusinessId, shelfId, desiredGpuId, self.Root.Position)
	if not gpuModel then
		return false
	end

	local reservedBy = gpuModel:GetAttribute("ReservedByCustomerId")
	if typeof(reservedBy) == "string" and reservedBy ~= self.CustomerId then
		return false
	end

	gpuModel:SetAttribute("ReservedByCustomerId", self.CustomerId)

	local rightHand = getCharacterPart(self.Model, { "RightHand", "Right Arm" })
	if not rightHand then
		gpuModel:SetAttribute("ReservedByCustomerId", nil)
		gpuModel:Destroy()
		return false
	end

	self:SetState("TakingItem")

	self.Humanoid:Move(Vector3.zero)
	self.Humanoid.AutoRotate = false
	self.Root.AssemblyLinearVelocity = Vector3.zero
	self.Root.AssemblyAngularVelocity = Vector3.zero

	local grabTrack = playActionAnimation(self.Humanoid, GPU_GRAB_ANIMATION_NAME)

	waitForAnimationMarker(grabTrack, GPU_PICKUP_MARKER, GPU_PICKUP_FALLBACK_SECONDS)

	if not self.Running or not gpuModel.Parent then
		if grabTrack then
			grabTrack:Stop(0.1)
			grabTrack:Destroy()
		end

		return false
	end

	local gpuHoldPart = prepareGpuModelForHolding(gpuModel)
	if not gpuHoldPart then
		if grabTrack then
			grabTrack:Stop(0.1)
			grabTrack:Destroy()
		end

		gpuModel:Destroy()
		return false
	end

	gpuModel.Parent = self.Model

	local holdCFrame = self.Root.CFrame * CFrame.new(0, 0.3, -1.25) * CFrame.Angles(0, math.rad(90), 0)

	gpuModel:PivotTo(holdCFrame)

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CustomerGpuHoldWeld"
	weld.Part0 = rightHand
	weld.Part1 = gpuHoldPart
	weld.Parent = gpuHoldPart

	self.Model:SetAttribute("HeldGpuId", desiredGpuId or "")

	local attachedAt = os.clock()

	waitForAnimationMarker(grabTrack, GPU_HIDE_MARKER, GPU_HIDE_FALLBACK_SECONDS)

	local visibleFor = os.clock() - attachedAt
	local remainingVisibleTime = GPU_MIN_VISIBLE_SECONDS - visibleFor

	while self.Running and remainingVisibleTime > 0 do
		task.wait(math.min(0.05, remainingVisibleTime))
		remainingVisibleTime = GPU_MIN_VISIBLE_SECONDS - (os.clock() - attachedAt)
	end

	if gpuModel.Parent then
		gpuModel:Destroy()
	end

	self.Model:SetAttribute("HeldGpuId", nil)

	if grabTrack then
		grabTrack:Stop(0.12)
		grabTrack:Destroy()
	end

	self:AllowMovementRotation()

	return true
end

function CustomerComponent:MoveToCheckout(): boolean
	self:SetState("WalkingToCheckout")

	while self.Running do
		local queueSlot = CustomerService.GetCheckoutQueueSlot(self.BusinessId, self.CustomerId)
		local reservedSlot = CrowdService.ReserveCheckoutSlot(self.BusinessId, self.CustomerId, queueSlot, 60)

		if not reservedSlot then
			self:SetState("WaitingForCheckoutSpace")

			if self.Humanoid then
				self.Humanoid:Move(Vector3.zero)
			end

			task.wait(0.35)
			continue
		end

		self.CheckoutQueueSlot = reservedSlot

		local checkoutCFrame = WorldQueryService.GetCheckoutQueueCFrame(self.BusinessId, queueSlot)

		local routeBuilder = function(fromPosition: Vector3)
			return StoreNavigationService.FindRouteToCheckout(self.BusinessId, fromPosition, checkoutCFrame)
		end

		local reachedSlot = self:MoveToCFrame(checkoutCFrame, routeBuilder, function()
			return CustomerService.GetCheckoutQueueSlot(self.BusinessId, self.CustomerId) == queueSlot
		end, CHECKOUT_SLOT_REACH_DISTANCE, "Checkout")

		if reachedSlot then
			self:SnapFaceToCFrame(checkoutCFrame)
			return true
		end

		if CustomerService.GetCheckoutQueueSlot(self.BusinessId, self.CustomerId) == queueSlot then
			return false
		end
	end

	return false
end

function CustomerComponent:MoveToCheckoutEntrance(): boolean
	self:SetState("WalkingToCheckout")
	self.CheckoutQueueSlot = nil

	local joinSlot = CustomerService.GetCheckoutQueueJoinSlot(self.BusinessId)
	local checkoutCFrame = WorldQueryService.GetCheckoutQueueCFrame(self.BusinessId, joinSlot)

	local routeBuilder = function(fromPosition: Vector3)
		return StoreNavigationService.FindRouteToCheckout(self.BusinessId, fromPosition, checkoutCFrame)
	end

	local reached = self:MoveToCFrame(checkoutCFrame, routeBuilder)

	if reached then
		self:SnapFaceToCFrame(checkoutCFrame)
	end

	return reached
end

function CustomerComponent:IsAtCheckoutQueueSlot(queueSlot: number): boolean
	if not self.Root then
		return false
	end

	local checkoutCFrame = WorldQueryService.GetCheckoutQueueCFrame(self.BusinessId, queueSlot)
	return getFlatDistance(self.Root.Position, checkoutCFrame.Position) <= CHECKOUT_SLOT_ARRIVAL_DISTANCE
end

function CustomerComponent:RunCheckoutFlowWithRetries(): boolean
	local maxAttempts = 4

	for attempt = 1, maxAttempts do
		if not self.Running then
			return false
		end

		local reachedEntrance = self:MoveToCheckoutEntrance()

		if reachedEntrance and CustomerService.EnterPhysicalCheckoutQueue(self.BusinessId, self.CustomerId) then
			if self:MoveToCheckout() then
				if self:WaitForCheckoutTurn() then
					CrowdService.ReleaseCustomerReservations(self.CustomerId)
					return true
				end
			end
		end

		CustomerService.LeavePhysicalCheckoutQueue(self.BusinessId, self.CustomerId)
		CrowdService.ReleaseCustomerReservations(self.CustomerId)

		self:SetState("WaitingForCheckoutPath")

		if self.Humanoid then
			self.Humanoid:Move(Vector3.zero)
		end

		task.wait(0.5 + attempt * 0.25)
	end

	return false
end

function CustomerComponent:WaitForCheckoutTurn(): boolean
	local checkoutOpen = false
	local idleSince = os.clock()
	local lastQueueSlot: number? = nil
	local nextIdleRollAt = math.huge
	local idleRollCount = 0

	while self.Running do
		local queueSlot = CustomerService.GetCheckoutQueueSlot(self.BusinessId, self.CustomerId)
		local atAssignedSlot = self.CheckoutQueueSlot == queueSlot and self:IsAtCheckoutQueueSlot(queueSlot)

		if lastQueueSlot == nil or queueSlot < lastQueueSlot then
			idleSince = os.clock()
			nextIdleRollAt = idleSince + self:GetCheckoutIdleLeaveSeconds()
			idleRollCount = 0
		elseif nextIdleRollAt == math.huge then
			nextIdleRollAt = idleSince + self:GetCheckoutIdleLeaveSeconds()
		end
		lastQueueSlot = queueSlot

		if not atAssignedSlot then
			if checkoutOpen then
				CheckoutService.CancelCheckoutInteraction(self.BusinessId, self.CustomerId)
				checkoutOpen = false
			end
			if not self:MoveToCheckout() then
				return false
			end
			queueSlot = CustomerService.GetCheckoutQueueSlot(self.BusinessId, self.CustomerId)
			atAssignedSlot = self.CheckoutQueueSlot == queueSlot and self:IsAtCheckoutQueueSlot(queueSlot)
		end

		self:SetState("WaitingAtCheckout")
		CrowdService.RefreshReservation(self.CustomerId, 10)
		self:SnapFaceToCFrame(WorldQueryService.GetCheckoutQueueCFrame(self.BusinessId, queueSlot))

		if self.Humanoid then
			self.Humanoid:Move(Vector3.zero)
		end

		if queueSlot == 1 and atAssignedSlot then
			if not checkoutOpen then
				checkoutOpen = CheckoutService.OpenCheckoutInteraction(self.BusinessId, self.CustomerId, self.Model)
			end

			if CheckoutService.IsCheckoutComplete(self.BusinessId, self.CustomerId) then
				return true
			end
		else
			if checkoutOpen then
				CheckoutService.CancelCheckoutInteraction(self.BusinessId, self.CustomerId)
				checkoutOpen = false
			end
		end

		if CheckoutService.IsCheckoutBeingServed(self.BusinessId) then
			idleSince = os.clock()
			nextIdleRollAt = idleSince + self:GetCheckoutIdleLeaveSeconds()
			idleRollCount = 0
		elseif os.clock() >= nextIdleRollAt then
			idleRollCount += 1

			if math.random() <= self:GetCheckoutIdleLeaveChance(idleRollCount) then
				if checkoutOpen then
					CheckoutService.CancelCheckoutInteraction(self.BusinessId, self.CustomerId)
					checkoutOpen = false
				end

				CustomerService.AbandonPhysicalCheckoutQueue(self.BusinessId, self.CustomerId)
				CrowdService.ReleaseCustomerReservations(self.CustomerId)
				self.CheckoutQueueSlot = nil
				self:SetState("Leaving")
				self:ShowEmotion("QueueAngry")
				return false
			end

			nextIdleRollAt = os.clock() + CHECKOUT_IDLE_ROLL_INTERVAL
		end

		task.wait(0.2)
	end

	if checkoutOpen then
		CheckoutService.CancelCheckoutInteraction(self.BusinessId, self.CustomerId)
	end

	return false
end

function CustomerComponent:MoveToExit(): boolean
	self:SetState("WalkingToExit")
	local exitCFrame = WorldQueryService.GetExitCFrame(self.BusinessId)

	local routeBuilder = function(fromPosition: Vector3)
		return StoreNavigationService.FindRouteToExit(self.BusinessId, fromPosition, exitCFrame)
	end

	return self:MoveToCFrame(exitCFrame, routeBuilder, nil, nil, "Exit")
end

local ARRIVAL_TURN_SPEED = math.rad(220)
local ARRIVAL_TURN_EPSILON = math.rad(1.5)

function CustomerComponent:SmoothFaceCFrame(targetCFrame: CFrame, timeout: number?)
	if not self.Root or not self.Humanoid then
		return
	end

	self._faceTurnToken = (self._faceTurnToken or 0) + 1
	local turnToken = self._faceTurnToken

	task.delay(0.5, function()
		if turnToken ~= self._faceTurnToken then
			return
		end

		if not self.Root or not self.Humanoid or not self.Model then
			return
		end

		self.Humanoid:Move(Vector3.zero)
		self.Humanoid.AutoRotate = false

		self.Root.AssemblyLinearVelocity = Vector3.zero
		self.Root.AssemblyAngularVelocity = Vector3.zero

		local targetLook = targetCFrame.LookVector
		local targetFlatLook = Vector3.new(targetLook.X, 0, targetLook.Z)

		if targetFlatLook.Magnitude < 0.05 then
			return
		end

		targetFlatLook = targetFlatLook.Unit

		local endTime = os.clock() + (timeout or ARRIVAL_TURN_TIMEOUT)

		while self.Running and os.clock() < endTime do
			if turnToken ~= self._faceTurnToken then
				return
			end

			local currentPivot = self.Model:GetPivot()
			local pivotPosition = currentPivot.Position

			local currentLook = currentPivot.LookVector
			local currentFlatLook = Vector3.new(currentLook.X, 0, currentLook.Z)

			if currentFlatLook.Magnitude < 0.05 then
				break
			end

			currentFlatLook = currentFlatLook.Unit

			local dot = math.clamp(currentFlatLook:Dot(targetFlatLook), -1, 1)
			local cross = currentFlatLook:Cross(targetFlatLook)

			local angleToTarget = math.atan2(cross.Y, dot)

			if math.abs(angleToTarget) <= ARRIVAL_TURN_EPSILON then
				break
			end

			local maxStepAngle = ARRIVAL_TURN_SPEED * ARRIVAL_TURN_STEP
			local stepAngle = math.clamp(angleToTarget, -maxStepAngle, maxStepAngle)

			local rotationStep = CFrame.fromAxisAngle(Vector3.yAxis, stepAngle)
			local newLook = rotationStep:VectorToWorldSpace(currentFlatLook)

			self.Model:PivotTo(CFrame.lookAt(pivotPosition, pivotPosition + newLook, Vector3.yAxis))

			task.wait(ARRIVAL_TURN_STEP)
		end

		if turnToken ~= self._faceTurnToken then
			return
		end

		local currentPivot = self.Model:GetPivot()
		local currentLook = currentPivot.LookVector
		local currentFlatLook = Vector3.new(currentLook.X, 0, currentLook.Z)

		if currentFlatLook.Magnitude < 0.05 then
			return
		end

		currentFlatLook = currentFlatLook.Unit

		local finalDot = math.clamp(currentFlatLook:Dot(targetFlatLook), -1, 1)
		local finalAngle = math.acos(finalDot)

		if finalAngle <= math.rad(5) then
			local pivotPosition = currentPivot.Position

			self.Model:PivotTo(CFrame.lookAt(pivotPosition, pivotPosition + targetFlatLook, Vector3.yAxis))
		end
	end)
end

function CustomerComponent:AllowMovementRotation()
	if self.Humanoid then
		self.Humanoid.AutoRotate = true
	end
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
		if CustomerService.EnterPhysicalCheckoutQueue(self.BusinessId, self.CustomerId) then
			if self:MoveToCheckout() then
				if self:WaitForCheckoutTurn() then
					CrowdService.ReleaseCustomerReservations(self.CustomerId)
				else
					CustomerService.LeavePhysicalCheckoutQueue(self.BusinessId, self.CustomerId)
					CrowdService.ReleaseCustomerReservations(self.CustomerId)
				end
			else
				CustomerService.LeavePhysicalCheckoutQueue(self.BusinessId, self.CustomerId)
				CrowdService.ReleaseCustomerReservations(self.CustomerId)
			end
		else
			CustomerService.LeavePhysicalCheckoutQueue(self.BusinessId, self.CustomerId)
			CrowdService.ReleaseCustomerReservations(self.CustomerId)
		end
	elseif nextAction == "Steal" then
		CustomerService.TryStartPhysicalTheft(self.BusinessId, self.CustomerId, self.Model)
	end

	local exited = false

	if self.Running then
		for attempt = 1, 6 do
			exited = self:MoveToExit()

			if exited then
				break
			end

			self:SetState("WaitingForExitPath")

			if self.Humanoid then
				self.Humanoid:Move(Vector3.zero)
			end

			task.wait(0.5 + attempt * 0.25)
		end
	end

	if not exited then
		warn(`Customer {self.CustomerId} failed to exit cleanly`)
		task.wait(2)
	end

	CustomerService.DespawnPhysicalCustomer(self.BusinessId, self.CustomerId)
	queueDestroy(self.Model)
end

return CustomerComponent
