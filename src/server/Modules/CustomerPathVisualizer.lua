--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type Visualizer = {
	SetRoute: (self: Visualizer, waypoints: { CFrame }) -> (),
	SetRouteIndex: (self: Visualizer, routeIndex: number) -> (),
	MarkEvent: (self: Visualizer, kind: string, position: Vector3, note: string?) -> (),
	SetSteerTargets: (self: Visualizer, moveTarget: Vector3?, guideTarget: Vector3?) -> (),
	SetCurrentPathTarget: (self: Visualizer, targetPosition: Vector3?) -> (),
	Destroy: (self: Visualizer) -> (),
}

type WaypointVisual = {
	part: BasePart,
	attachment: Attachment,
}

local FOLDER_NAME = "DebugCustomerPaths"
local MAX_EVENT_MARKERS = 40

local COLORS = {
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

local function getOrCreateRootFolder(): Folder
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function makeAnchorPart(name: string, position: Vector3, size: Vector3, color: Color3, transparency: number): BasePart
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

local function makeWaypointVisual(parent: Instance, index: number, cframe: CFrame): WaypointVisual
	local p = makeAnchorPart(
		`WP_{index}`,
		cframe.Position + Vector3.new(0, 0.15, 0),
		Vector3.new(0.25, 0.25, 0.25),
		COLORS.route,
		0.05
	)
	p.Shape = Enum.PartType.Ball
	p.Parent = parent

	local att = Instance.new("Attachment")
	att.Name = "A"
	att.Parent = p

	return { part = p, attachment = att }
end

local function makeBeam(parent: Instance, a0: Attachment, a1: Attachment, color: Color3, width: number, name: string): Beam
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

local function makeBillboard(parent: Instance, text: string, color: Color3): BillboardGui
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

	return bb
end

local Visualizer = {}
Visualizer.__index = Visualizer

function Visualizer.new(customerId: string, rootPart: BasePart): Visualizer
	local root = getOrCreateRootFolder()

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

	local self = setmetatable({
		_customerId = customerId,
		_rootPart = rootPart,
		_folder = folder,
		_routeFolder = routeFolder,
		_eventsFolder = eventsFolder,
		_dynamicFolder = dynamicFolder,

		_waypoints = {} :: { WaypointVisual },
		_beams = {} :: { Beam },
		_routeIndex = 1,

		_moveTarget = nil :: Vector3?,
		_guideTarget = nil :: Vector3?,
		_currentPathTarget = nil :: Vector3?,

		_dynamicA = nil :: WaypointVisual?,
		_dynamicB = nil :: WaypointVisual?,
		_dynamicBeam = nil :: Beam?,

		_dynamicSteerA = nil :: WaypointVisual?,
		_dynamicSteerB = nil :: WaypointVisual?,
		_dynamicSteerMoveBeam = nil :: Beam?,
		_dynamicSteerGuideBeam = nil :: Beam?,

		_events = {} :: { Instance },
		_conn = nil :: RBXScriptConnection?,
	}, Visualizer)

	self:_ensureDynamic()
	self._conn = RunService.Heartbeat:Connect(function()
		self:_tick()
	end)

	return (self :: any) :: Visualizer
end

function Visualizer:_ensureDynamic()
	if self._dynamicA and self._dynamicB and self._dynamicBeam then
		return
	end

	self._dynamicA = makeWaypointVisual(self._dynamicFolder, 0, CFrame.new(self._rootPart.Position))
	self._dynamicA.part.Name = "Root"
	self._dynamicA.part.Size = Vector3.new(0.18, 0.18, 0.18)
	self._dynamicA.part.Color = COLORS.next

	self._dynamicB = makeWaypointVisual(self._dynamicFolder, 0, CFrame.new(self._rootPart.Position))
	self._dynamicB.part.Name = "Target"
	self._dynamicB.part.Size = Vector3.new(0.18, 0.18, 0.18)
	self._dynamicB.part.Color = COLORS.currentTarget

	self._dynamicBeam = makeBeam(self._dynamicFolder, self._dynamicA.attachment, self._dynamicB.attachment, COLORS.currentTarget, 0.16, "RootToTarget")

	self._dynamicSteerA = makeWaypointVisual(self._dynamicFolder, 0, CFrame.new(self._rootPart.Position))
	self._dynamicSteerA.part.Name = "SteerMove"
	self._dynamicSteerA.part.Size = Vector3.new(0.16, 0.16, 0.16)
	self._dynamicSteerA.part.Color = COLORS.steerMoveTarget
	self._dynamicSteerA.part.Transparency = 0.2

	self._dynamicSteerB = makeWaypointVisual(self._dynamicFolder, 0, CFrame.new(self._rootPart.Position))
	self._dynamicSteerB.part.Name = "SteerGuide"
	self._dynamicSteerB.part.Size = Vector3.new(0.16, 0.16, 0.16)
	self._dynamicSteerB.part.Color = COLORS.steerGuideTarget
	self._dynamicSteerB.part.Transparency = 0.2

	self._dynamicSteerMoveBeam =
		makeBeam(self._dynamicFolder, self._dynamicA.attachment, self._dynamicSteerA.attachment, COLORS.steerMoveTarget, 0.12, "RootToMoveTarget")
	self._dynamicSteerGuideBeam =
		makeBeam(self._dynamicFolder, self._dynamicA.attachment, self._dynamicSteerB.attachment, COLORS.steerGuideTarget, 0.12, "RootToGuideTarget")
end

function Visualizer:_clearRoute()
	for _, beam in ipairs(self._beams) do
		beam:Destroy()
	end
	for _, wp in ipairs(self._waypoints) do
		wp.part:Destroy()
	end
	table.clear(self._beams)
	table.clear(self._waypoints)
end

function Visualizer:SetRoute(waypoints: { CFrame })
	self:_clearRoute()

	for i, cf in ipairs(waypoints) do
		self._waypoints[i] = makeWaypointVisual(self._routeFolder, i, cf)
	end

	for i = 1, #self._waypoints - 1 do
		local a = self._waypoints[i]
		local b = self._waypoints[i + 1]
		self._beams[i] = makeBeam(self._routeFolder, a.attachment, b.attachment, COLORS.route, 0.18, `Seg_{i}`)
	end

	self:SetRouteIndex(1)
end

function Visualizer:SetRouteIndex(routeIndex: number)
	self._routeIndex = math.max(1, routeIndex)

	for i, wp in ipairs(self._waypoints) do
		if i < self._routeIndex then
			wp.part.Color = COLORS.routeDone
			wp.part.Transparency = 0.5
		elseif i == self._routeIndex then
			wp.part.Color = COLORS.next
			wp.part.Transparency = 0.05
		else
			wp.part.Color = COLORS.route
			wp.part.Transparency = 0.15
		end
	end

	for i, beam in ipairs(self._beams) do
		if i < self._routeIndex then
			beam.Color = ColorSequence.new(COLORS.routeDone)
			beam.Transparency = NumberSequence.new(0.6)
		elseif i == self._routeIndex then
			beam.Color = ColorSequence.new(COLORS.next)
			beam.Transparency = NumberSequence.new(0.15)
		else
			beam.Color = ColorSequence.new(COLORS.route)
			beam.Transparency = NumberSequence.new(0.25)
		end
	end
end

function Visualizer:SetSteerTargets(moveTarget: Vector3?, guideTarget: Vector3?)
	self._moveTarget = moveTarget
	self._guideTarget = guideTarget
end

function Visualizer:SetCurrentPathTarget(targetPosition: Vector3?)
	self._currentPathTarget = targetPosition
end

function Visualizer:MarkEvent(kind: string, position: Vector3, note: string?)
	local color = (COLORS :: any)[kind] or Color3.fromRGB(255, 255, 255)

	local marker = makeAnchorPart(`Event_{kind}`, position + Vector3.new(0, 0.25, 0), Vector3.new(0.28, 0.28, 0.28), color, 0.05)
	marker.Shape = Enum.PartType.Ball
	marker.Parent = self._eventsFolder

	local labelText = if note and note ~= "" then `{kind}:{note}` else kind
	makeBillboard(marker, labelText, color)

	table.insert(self._events, marker)
	while #self._events > MAX_EVENT_MARKERS do
		local old = table.remove(self._events, 1)
		if old then
			old:Destroy()
		end
	end
end

function Visualizer:_tick()
	if not self._rootPart or not self._rootPart.Parent then
		return
	end

	self:_ensureDynamic()

	local rootPos = self._rootPart.Position
	local dynamicA = self._dynamicA
	local dynamicB = self._dynamicB
	local dynamicBeam = self._dynamicBeam
	local dynamicSteerA = self._dynamicSteerA
	local dynamicSteerB = self._dynamicSteerB
	local dynamicSteerMoveBeam = self._dynamicSteerMoveBeam
	local dynamicSteerGuideBeam = self._dynamicSteerGuideBeam

	if not dynamicA or not dynamicB or not dynamicBeam then
		return
	end
	if not dynamicSteerA or not dynamicSteerB or not dynamicSteerMoveBeam or not dynamicSteerGuideBeam then
		return
	end

	dynamicA.part.CFrame = CFrame.new(rootPos + Vector3.new(0, 0.15, 0))

	local target = self._currentPathTarget
	if target then
		dynamicB.part.Transparency = 0.05
		dynamicBeam.Transparency = NumberSequence.new(0.05)
		dynamicB.part.CFrame = CFrame.new(target + Vector3.new(0, 0.15, 0))
	else
		dynamicB.part.Transparency = 1
		dynamicBeam.Transparency = NumberSequence.new(1)
	end

	if self._moveTarget then
		dynamicSteerA.part.Transparency = 0.25
		dynamicSteerMoveBeam.Transparency = NumberSequence.new(0.2)
		dynamicSteerA.part.CFrame = CFrame.new(self._moveTarget + Vector3.new(0, 0.15, 0))
	else
		dynamicSteerA.part.Transparency = 1
		dynamicSteerMoveBeam.Transparency = NumberSequence.new(1)
	end

	if self._guideTarget then
		dynamicSteerB.part.Transparency = 0.25
		dynamicSteerGuideBeam.Transparency = NumberSequence.new(0.2)
		dynamicSteerB.part.CFrame = CFrame.new(self._guideTarget + Vector3.new(0, 0.15, 0))
	else
		dynamicSteerB.part.Transparency = 1
		dynamicSteerGuideBeam.Transparency = NumberSequence.new(1)
	end
end

function Visualizer:Destroy()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end

	if self._folder then
		self._folder:Destroy()
	end
end

return Visualizer

