local ServerScriptService = game:GetService("ServerScriptService")

local CrowdService = require(ServerScriptService.Server.Services.CrowdService)
local StoreNavigationService = require(ServerScriptService.Server.Services.StoreNavigationService)

export type SimplePathLike = {
	Run: (self: SimplePathLike, Vector3) -> boolean,
	Reached: RBXScriptSignal,
	Error: RBXScriptSignal,
	Blocked: RBXScriptSignal,
}

export type MovementPersonality = {
	walkSpeedMultiplier: number,
	preferredSide: number,
	patience: number,
	hesitationSeconds: number,
}

export type MovementController = {
	model: Model,
	businessId: string,
	customerId: string,
	humanoid: Humanoid,
	root: BasePart,
	path: SimplePathLike,
	baseWalkSpeed: number,
	personality: MovementPersonality,

	running: boolean,
	moveToken: number,
	routeWaypoints: { CFrame },
	routeIndex: number,

	lastPosition: Vector3,
	stuckTimer: number,
	lastCorrectionAt: number,
	lastFullRerouteAt: number,
	lastAvoidanceAt: number,

	debug: any?,

	SetRoute: (self: MovementController, waypoints: { CFrame }) -> (),
	MoveAlongRoute: (self: MovementController, getRunning: () -> boolean) -> boolean,
	MoveToTarget: (
		self: MovementController,
		targetCFrame: CFrame,
		buildRoute: (fromPosition: Vector3) -> { CFrame },
		getRunning: () -> boolean
	) -> boolean,
}

local PATH_TIMEOUT_SECONDS = 14
local PATH_RETRIES = 2
local NODE_ARRIVAL_DISTANCE = 5
local PATH_CORRECTION_COOLDOWN = 0.5
local FULL_REROUTE_COOLDOWN = 2.5
local STUCK_MOVE_THRESHOLD = 0.3
local STUCK_CORRECTION_TIME = 0.85
local STUCK_REROUTE_TIME = 2.75
local LOOP_INTERVAL = 0.1
local INTERSECTION_PAUSE_MIN = 0.15
local INTERSECTION_PAUSE_MAX = 0.45
local SKIP_CLOSE_NODE_DISTANCE = 6
local BAD_NODE_EXTRA_DISTANCE = 2
local DIRECT_TARGET_DISTANCE = 18
local ROUTE_WAYPOINT_REACH_DISTANCE = 2.35
local FINAL_REACH_DISTANCE = 2.35
local ARRIVAL_HYSTERESIS_DISTANCE = 1.1

local ROUTE_GUIDE_ADVANCE_DISTANCE = 5
local ROUTE_CORNER_CUT_DISTANCE = 5.5
local ROUTE_LANE_HALF_WIDTH = 1.25
local DIRECT_STEER_TIMEOUT_MULTIPLIER = 2.5

local function hashString(value: string): number
	local hash = 0
	for index = 1, #value do
		hash = (hash * 31 + string.byte(value, index)) % 100000
	end
	return hash
end

local function buildPersonality(customerId: string): MovementPersonality
	local hash = hashString(customerId)
	return {
		walkSpeedMultiplier = 0.88 + (hash % 25) / 100,
		preferredSide = if hash % 2 == 0 then 1 else -1,
		patience = 0.7 + (hash % 40) / 100,
		hesitationSeconds = 0.1 + (hash % 20) / 100,
	}
end

local function pruneRoute(waypoints: { CFrame }, fromPosition: Vector3, finalPosition: Vector3): { CFrame }
	local pruned = table.clone(waypoints)

	while #pruned > 1 do
		local firstPosition = pruned[1].Position

		local distanceToFirst = (firstPosition - fromPosition).Magnitude
		local currentDistanceToGoal = (finalPosition - fromPosition).Magnitude
		local firstDistanceToGoal = (finalPosition - firstPosition).Magnitude

		local firstIsAlreadyClose = distanceToFirst <= SKIP_CLOSE_NODE_DISTANCE
		local firstMovesAwayFromGoal = firstDistanceToGoal > currentDistanceToGoal + BAD_NODE_EXTRA_DISTANCE

		if firstIsAlreadyClose or firstMovesAwayFromGoal then
			table.remove(pruned, 1)
		else
			break
		end
	end

	return pruned
end

local function canUseDirectTarget(fromPosition: Vector3, targetPosition: Vector3): boolean
	return (fromPosition - targetPosition).Magnitude <= DIRECT_TARGET_DISTANCE
end

local function isCloseEnoughToTarget(root: BasePart, targetPosition: Vector3, radius: number): boolean
	local flatRoot = Vector3.new(root.Position.X, 0, root.Position.Z)
	local flatTarget = Vector3.new(targetPosition.X, 0, targetPosition.Z)

	return (flatRoot - flatTarget).Magnitude <= radius
end

local function getStableLaneOffset(customerId: string, width: number): number
	local hash = hashString(`{customerId}:lane-offset`)
	local alpha = (hash % 1000) / 1000

	return (alpha - 0.5) * width
end

local function getSoftRouteTarget(
	customerId: string,
	currentPosition: Vector3,
	targetPosition: Vector3,
	nextPosition: Vector3?,
	laneWidth: number
): Vector3
	local direction = if nextPosition then nextPosition - currentPosition else targetPosition - currentPosition
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)

	if flatDirection.Magnitude < 0.1 then
		return targetPosition
	end

	local forward = flatDirection.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X)

	local offset = getStableLaneOffset(customerId, laneWidth)

	return targetPosition + right * offset
end

local function getFlatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function getFlatDirection(fromPosition: Vector3, toPosition: Vector3): Vector3?
	local delta = Vector3.new(toPosition.X - fromPosition.X, 0, toPosition.Z - fromPosition.Z)

	if delta.Magnitude < 0.05 then
		return nil
	end

	return delta.Unit
end

local function getRightFromDirection(direction: Vector3): Vector3
	return Vector3.new(direction.Z, 0, -direction.X)
end

local function getCustomerLaneOffset(customerId: string, routeIndex: number): number
	local hash = hashString(`{customerId}:lane:{routeIndex}`)
	local alpha = (hash % 1000) / 1000
	return (alpha * 2 - 1) * ROUTE_LANE_HALF_WIDTH
end

local MovementController = {}
MovementController.__index = MovementController

function MovementController.new(
	model: Model,
	businessId: string,
	customerId: string,
	humanoid: Humanoid,
	root: BasePart,
	path: SimplePathLike,
	baseWalkSpeed: number,
	debug: any?
): MovementController
	local self = setmetatable({
		model = model,
		businessId = businessId,
		customerId = customerId,
		humanoid = humanoid,
		root = root,
		path = path,
		baseWalkSpeed = baseWalkSpeed,
		personality = buildPersonality(customerId),

		running = true,
		moveToken = 0,
		routeWaypoints = {},
		routeIndex = 1,

		lastPosition = root.Position,
		stuckTimer = 0,
		lastCorrectionAt = 0,
		lastFullRerouteAt = 0,
		lastAvoidanceAt = 0,

		debug = debug,
	}, MovementController) :: any

	return self
end

function MovementController:SetRoute(waypoints: { CFrame })
	self.routeWaypoints = waypoints
	self.routeIndex = 1
	self.stuckTimer = 0
	self.lastPosition = self.root.Position

	if self.debug and self.debug.SetRoute then
		self.debug:SetRoute(waypoints)
	end
	if self.debug and self.debug.SetRouteIndex then
		self.debug:SetRouteIndex(self.routeIndex)
	end
end

function MovementController:_applyWalkSpeed()
	local slowdown = CrowdService.GetCrowdSlowdown(self.root.Position, 6, self.model)
	self.humanoid.WalkSpeed = math.max(4, self.baseWalkSpeed * self.personality.walkSpeedMultiplier * slowdown)
end

function MovementController:_updateStuck(deltaSeconds: number): "ok" | "correct" | "reroute"
	local moved = (self.root.Position - self.lastPosition).Magnitude
	if moved < STUCK_MOVE_THRESHOLD then
		self.stuckTimer += deltaSeconds
	else
		self.stuckTimer = 0
		self.lastPosition = self.root.Position
	end

	local now = os.clock()

	if self.stuckTimer >= STUCK_REROUTE_TIME and now - self.lastFullRerouteAt >= FULL_REROUTE_COOLDOWN then
		self.lastFullRerouteAt = now
		self.stuckTimer = 0
		return "reroute"
	end

	if self.stuckTimer >= STUCK_CORRECTION_TIME and now - self.lastCorrectionAt >= PATH_CORRECTION_COOLDOWN then
		self.lastCorrectionAt = now
		self.stuckTimer = 0
		return "correct"
	end

	return "ok"
end

function MovementController:_applyLocalAvoidance(targetPosition: Vector3)
	local avoidanceDirection = CrowdService.GetLocalAvoidanceMoveDirection(self.model, targetPosition)
	if avoidanceDirection then
		if avoidanceDirection.Magnitude <= 0.01 then
			self.humanoid:Move(Vector3.zero)
		else
			self.humanoid:Move(avoidanceDirection)
		end
		return
	end

	local adjustedTarget = CrowdService.GetAdjustedMoveTarget(self.model, targetPosition)
	if (adjustedTarget - targetPosition).Magnitude > 0.05 then
		local flat = adjustedTarget - self.root.Position
		if flat.Magnitude > 0.1 then
			self.humanoid:Move(Vector3.new(flat.X, 0, flat.Z).Unit)
		end
	end
end

function MovementController:_runPathTo(
	targetPosition: Vector3,
	getRunning: () -> boolean,
	moveToken: number,
	arrivalDistance: number?
): boolean
	if self.debug and self.debug.SetCurrentPathTarget then
		self.debug:SetCurrentPathTarget(targetPosition)
	end

	local dist = arrivalDistance or NODE_ARRIVAL_DISTANCE
	local softDist = dist + ARRIVAL_HYSTERESIS_DISTANCE

	local started = self.path:Run(targetPosition)
	if not started then
		if self.debug and self.debug.MarkEvent then
			self.debug:MarkEvent("error", self.root.Position, "path:run-false")
		end
		return false
	end

	local reached = false
	local failed = false
	local failReason: string? = nil

	local reachedConnection = self.path.Reached:Connect(function()
		-- might be a problem
		if isCloseEnoughToTarget(self.root, targetPosition, softDist) then
			reached = true
		else
			self.path:Run(targetPosition)
		end
	end)
	local errorConnection = self.path.Error:Connect(function()
		failed = true
		failReason = "error"
	end)
	local blockedConnection = self.path.Blocked:Connect(function()
		failed = true
		failReason = "blocked"
	end)

	local startedAt = os.clock()
	local lastRepathAt = 0

	while
		getRunning()
		and self.moveToken == moveToken
		and not reached
		and not failed
		and os.clock() - startedAt < PATH_TIMEOUT_SECONDS
	do
		local now = os.clock()
		local delta = LOOP_INTERVAL

		self:_applyWalkSpeed()
		--self:_applyLocalAvoidance(targetPosition)

		local distanceToTarget = getFlatDistance(self.root.Position, targetPosition)
		local nearFinalTarget = distanceToTarget <= math.max(dist + 0.75, 3)

		if not nearFinalTarget then
			local stuckAction = self:_updateStuck(delta)

			if stuckAction == "correct" then
				local sideStep = CrowdService.GetSideStepTarget(self.model, targetPosition)
				if self.debug and self.debug.MarkEvent then
					self.debug:MarkEvent("correct", sideStep, "side-step")
				end
				self.path:Run(sideStep)
			elseif stuckAction == "reroute" then
				if self.debug and self.debug.MarkEvent then
					self.debug:MarkEvent("reroute", self.root.Position, "stuck")
				end
				failed = true
				break
			end

			if now - lastRepathAt >= PATH_CORRECTION_COOLDOWN then
				if CrowdService.IsPathCrowdedAhead(self.model, targetPosition) then
					lastRepathAt = now

					if CrowdService.ShouldYield(self.model, targetPosition) then
						self.humanoid:Move(Vector3.zero)
						task.wait(self.personality.hesitationSeconds)
					else
						self.path:Run(CrowdService.GetSideStepTarget(self.model, targetPosition))
					end
				end
			end
		end

		if isCloseEnoughToTarget(self.root, targetPosition, softDist) then
			reached = true
			break
		end

		task.wait(LOOP_INTERVAL)
	end

	reachedConnection:Disconnect()
	errorConnection:Disconnect()
	blockedConnection:Disconnect()

	self.humanoid.WalkSpeed = self.baseWalkSpeed

	if self.debug and self.debug.SetCurrentPathTarget then
		self.debug:SetCurrentPathTarget(nil)
	end

	if not reached and self.debug and self.debug.MarkEvent then
		if failReason == "blocked" then
			self.debug:MarkEvent("blocked", self.root.Position, "path:blocked")
		elseif failReason == "error" then
			self.debug:MarkEvent("error", self.root.Position, "path:error")
		end
	end

	return reached
end

function MovementController:_steerToGuideTarget(
	moveTarget: Vector3,
	guidePosition: Vector3,
	getRunning: () -> boolean,
	moveToken: number,
	advanceDistance: number
): boolean
	if self.debug and self.debug.SetSteerTargets then
		self.debug:SetSteerTargets(moveTarget, guidePosition)
	end

	local startedAt = os.clock()

	local distance = getFlatDistance(self.root.Position, moveTarget)
	local timeout = math.max(1.5, (distance / math.max(self.baseWalkSpeed, 1)) * DIRECT_STEER_TIMEOUT_MULTIPLIER)

	self.stuckTimer = 0
	self.lastPosition = self.root.Position

	while getRunning() and self.moveToken == moveToken and os.clock() - startedAt < timeout do
		self:_applyWalkSpeed()

		if isCloseEnoughToTarget(self.root, guidePosition, advanceDistance) then
			if self.debug and self.debug.SetSteerTargets then
				self.debug:SetSteerTargets(nil, nil)
			end
			return true
		end

		self.humanoid:MoveTo(moveTarget)

		local stuckAction = self:_updateStuck(LOOP_INTERVAL)
		if stuckAction == "correct" then
			local sideStep = CrowdService.GetSideStepTarget(self.model, moveTarget)
			if self.debug and self.debug.MarkEvent then
				self.debug:MarkEvent("correct", sideStep, "steer-side-step")
			end
			self.humanoid:MoveTo(sideStep)
			task.wait(0.2)
		elseif stuckAction == "reroute" then
			if self.debug and self.debug.MarkEvent then
				self.debug:MarkEvent("reroute", self.root.Position, "steer-stuck")
			end
			if self.debug and self.debug.SetSteerTargets then
				self.debug:SetSteerTargets(nil, nil)
			end
			return false
		end

		task.wait(LOOP_INTERVAL)
	end

	local ok = isCloseEnoughToTarget(self.root, guidePosition, advanceDistance)
	if self.debug and self.debug.SetSteerTargets then
		self.debug:SetSteerTargets(nil, nil)
	end
	return ok
end

function MovementController:GetRouteGuideTarget(routeIndex: number): Vector3
	local currentWaypoint = self.routeWaypoints[routeIndex]
	local nextWaypoint = self.routeWaypoints[routeIndex + 1]

	if not currentWaypoint then
		return self.root.Position
	end

	if not nextWaypoint then
		return currentWaypoint.Position
	end

	local currentPosition = currentWaypoint.Position
	local nextPosition = nextWaypoint.Position

	local direction = getFlatDirection(currentPosition, nextPosition)
	if not direction then
		return currentPosition
	end

	local distanceToNext = getFlatDistance(currentPosition, nextPosition)
	local forwardDistance = math.min(ROUTE_CORNER_CUT_DISTANCE, distanceToNext * 0.5)

	local right = getRightFromDirection(direction)
	local laneOffset = getCustomerLaneOffset(self.customerId, routeIndex)

	return currentPosition + direction * forwardDistance + right * laneOffset
end

function MovementController:MoveAlongRoute(getRunning: () -> boolean): boolean
	if #self.routeWaypoints == 0 then
		return false
	end

	while self.routeIndex <= #self.routeWaypoints do
		if not getRunning() then
			return false
		end

		local waypoint = self.routeWaypoints[self.routeIndex]
		local targetPosition = waypoint.Position

		local isFinalWaypoint = self.routeIndex == #self.routeWaypoints

		local reachDistance = if isFinalWaypoint then FINAL_REACH_DISTANCE else ROUTE_WAYPOINT_REACH_DISTANCE

		if self.debug and self.debug.SetRouteIndex then
			self.debug:SetRouteIndex(self.routeIndex)
		end

		if self.routeIndex > 1 and self.routeIndex < #self.routeWaypoints then
			local hash = hashString(`{self.customerId}:{self.routeIndex}`)
			if hash % 5 == 0 then
				task.wait(
					INTERSECTION_PAUSE_MIN + (hash % 100) / 100 * (INTERSECTION_PAUSE_MAX - INTERSECTION_PAUSE_MIN)
				)
			end
		end

		self.moveToken += 1
		local moveToken = self.moveToken
		self.stuckTimer = 0
		self.lastPosition = self.root.Position

		local legReached = false
		for attempt = 1, PATH_RETRIES do
			if not getRunning() then
				return false
			end

			-- local isFinalWaypoint = self.routeIndex == #self.routeWaypoints
			-- local laneWidth = if isFinalWaypoint then 0 else 5

			-- local moveTarget = if isFinalWaypoint then targetPosition else getSoftRouteTarget(
			-- 	self.customerId,
			-- 	self.root.Position,
			-- 	targetPosition,
			-- 	nextPosition,
			-- 	laneWidth
			-- )

			if isFinalWaypoint then
				legReached = self:_runPathTo(targetPosition, getRunning, moveToken, FINAL_REACH_DISTANCE)
			else
				local moveTarget = self:GetRouteGuideTarget(self.routeIndex)

				legReached = self:_steerToGuideTarget(
					moveTarget,
					targetPosition,
					getRunning,
					moveToken,
					ROUTE_GUIDE_ADVANCE_DISTANCE
				)

				if not legReached then
					legReached = self:_runPathTo(targetPosition, getRunning, moveToken, ROUTE_GUIDE_ADVANCE_DISTANCE)
				end
			end

			if legReached then
				break
			end

			if attempt == PATH_RETRIES then
				local nearest = StoreNavigationService.FindNearestNode(self.businessId, self.root.Position)
				if nearest then
					local alternate =
						StoreNavigationService.GetAlternateNode(self.businessId, nearest.nodeId, self.root.Position)
					if alternate then
						self.routeWaypoints[self.routeIndex] = alternate.cframe
						targetPosition = alternate.cframe.Position
						legReached = self:_runPathTo(targetPosition, getRunning, moveToken, reachDistance)
					end
				end
			end

			task.wait(0.15 * attempt)
		end

		if not legReached then
			local distanceToWaypoint = (self.root.Position - targetPosition).Magnitude
			if distanceToWaypoint > NODE_ARRIVAL_DISTANCE * 2 then
				if self.debug and self.debug.MarkEvent then
					self.debug:MarkEvent("blocked", self.root.Position, `leg-failed:{self.routeIndex}`)
				end
				return false
			end
		end

		self.routeIndex += 1
	end

	return true
end

function MovementController:MoveToTarget(
	targetCFrame: CFrame,
	buildRoute: (fromPosition: Vector3) -> { CFrame },
	getRunning: () -> boolean
): boolean
	if not getRunning() then
		return false
	end

	local route = buildRoute(self.root.Position)

	if not route or #route == 0 then
		route = { targetCFrame }
	end

	route = pruneRoute(route, self.root.Position, targetCFrame.Position)

	if #route == 0 then
		route = { targetCFrame }
	end

	self:SetRoute(route)

	local followed = self:MoveAlongRoute(getRunning)

	if not followed and getRunning() then
		self.moveToken += 1
		return self:_runPathTo(targetCFrame.Position, getRunning, self.moveToken, FINAL_REACH_DISTANCE)
	end

	return followed
end

return MovementController
