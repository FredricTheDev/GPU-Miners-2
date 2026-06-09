local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldQueryService = require(script.Parent.WorldQueryService)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

export type NavNode = {
	instance: Instance,
	nodeId: string,
	nodeType: string,
	businessId: string,
	cframe: CFrame,
	connectedNodeIds: { string },
	capacity: number,
	shelfId: string?,
}

export type StoreGraph = {
	businessId: string,
	nodes: { [string]: NavNode },
	walkZones: { BasePart },
	edges: { [string]: { [string]: number } }
}

local StoreNavigationService = {}

StoreNavigationService.Name = "StoreNavigationService"
StoreNavigationService.Priority = 0

local graphCache: { [string]: StoreGraph } = {}
local graphBuiltAt: { [string]: number } = {}

local GRAPH_CACHE_SECONDS = 30

local NAV_NODE_TAGS = {
	WorldTags.StoreNavNode,
	WorldTags.EntranceNode,
	WorldTags.ExitNode,
	WorldTags.CheckoutNode,
	WorldTags.ShelfNavNode,
}

local MAX_NODE_SNAP_DISTANCE = 18
local STORE_BOUNDARY_PADDING = 4
local CORNER_RADIUS = 2.75
local MIN_CORNER_SEGMENT_LENGTH = 4
local DIRECT_ROUTE_MAX_DISTANCE = 24
local DIRECT_ROUTE_SAMPLE_SPACING = 4

local AUTO_NODE_LINK_DISTANCE = 20
local DIRECT_TARGET_CLEAR_DISTANCE = 10

local NPC_ROUTE_CLEARANCE_RADIUS = 3.25
local NPC_SHORTCUT_CLEARANCE_RADIUS = 4
local NPC_CORNER_CLEARANCE_RADIUS = 4
local SEGMENT_RAY_HEIGHTS = { 1.5, 3.25 }
local SEGMENT_SIDE_OFFSETS = { -1, -0.5, 0, 0.5, 1 }

local DIRECT_EXIT_ROUTE_MAX_DISTANCE = 120
local EXIT_DIRECT_CLEARANCE_RADIUS = 2.75

local function parseConnectedNodes(value: any): { string }
	if typeof(value) ~= "string" or value == "" then
		return {}
	end

	local ids: { string } = {}

	for segment in string.gmatch(value, "[^,%s]+") do
		table.insert(ids, segment)
	end

	return ids
end

local function inferNodeType(instance: Instance, attributeType: any): string
	if typeof(attributeType) == "string" and attributeType ~= "" then
		return attributeType
	end

	if CollectionService:HasTag(instance, WorldTags.EntranceNode) then
		return "Entrance"
	elseif CollectionService:HasTag(instance, WorldTags.ExitNode) then
		return "Exit"
	elseif CollectionService:HasTag(instance, WorldTags.CheckoutNode) then
		return "Checkout"
	elseif CollectionService:HasTag(instance, WorldTags.ShelfNavNode) then
		return "Shelf"
	end

	return "Aisle"
end

local function buildNodeFromInstance(instance: Instance, businessId: string): NavNode?
	local nodeId = instance:GetAttribute("NodeId")

	if typeof(nodeId) ~= "string" or nodeId == "" then
		nodeId = instance.Name
	end

	local cframe = WorldQueryService.GetCFrame(instance)

	if not cframe then
		return nil
	end

	local capacity = instance:GetAttribute("Capacity")
	local shelfId = instance:GetAttribute("ShelfId")

	return {
		instance = instance,
		nodeId = nodeId,
		nodeType = inferNodeType(instance, instance:GetAttribute("NodeType")),
		businessId = businessId,
		cframe = cframe,
		connectedNodeIds = parseConnectedNodes(instance:GetAttribute("ConnectedNodes")),
		capacity = if typeof(capacity) == "number" then capacity else 3,
		shelfId = if typeof(shelfId) == "string" then shelfId else nil,
	}
end

local function getFlatDirection(fromPosition: Vector3, toPosition: Vector3): Vector3?
	local delta = Vector3.new(toPosition.X - fromPosition.X, 0, toPosition.Z - fromPosition.Z)

	if delta.Magnitude < 0.05 then
		return nil
	end

	return delta.Unit
end

local function getFlatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function isSegmentInsideStore(businessId: string, fromPosition: Vector3, toPosition: Vector3): boolean
	local distance = getFlatDistance(fromPosition, toPosition)
	local steps = math.max(1, math.ceil(distance / DIRECT_ROUTE_SAMPLE_SPACING))

	for step = 0, steps do
		local alpha = step / steps
		local position = fromPosition:Lerp(toPosition, alpha)

		if not StoreNavigationService.IsPositionInStore(businessId, position) then
			return false
		end
	end

	return true
end

local function getRaycastIgnoreList(graph: StoreGraph): { Instance }
	local ignoreList: { Instance } = {}

	for _, node in graph.nodes do
		table.insert(ignoreList, node.instance)
	end

	for _, walkZone in graph.walkZones do
		table.insert(ignoreList, walkZone)
	end

	local activeCustomers = workspace:FindFirstChild("ActiveCustomers")
	if activeCustomers then
		table.insert(ignoreList, activeCustomers)
	end

	local debugFolder = workspace:FindFirstChild("DebugCustomerPaths")
	if debugFolder then
		table.insert(ignoreList, debugFolder)
	end

	return ignoreList
end

local function isSegmentClearOfObstacles(
	graph: StoreGraph,
	fromPosition: Vector3,
	toPosition: Vector3,
	clearanceRadius: number?
): boolean
	local flatDirection = Vector3.new(
		toPosition.X - fromPosition.X,
		0,
		toPosition.Z - fromPosition.Z
	)

	if flatDirection.Magnitude < 0.05 then
		return true
	end

	local forward = flatDirection.Unit
	local right = Vector3.new(forward.Z, 0, -forward.X)
	local radius = clearanceRadius or NPC_ROUTE_CLEARANCE_RADIUS

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = getRaycastIgnoreList(graph)

	local baseY = math.max(fromPosition.Y, toPosition.Y)

	for _, sideAlpha in SEGMENT_SIDE_OFFSETS do
		local sideOffset = right * radius * sideAlpha

		for _, height in SEGMENT_RAY_HEIGHTS do
			local origin = Vector3.new(fromPosition.X, baseY + height, fromPosition.Z) + sideOffset
			local result = workspace:Raycast(origin, flatDirection, raycastParams)

			if result then
				return false
			end
		end
	end

	return true
end

local function addEdge(graph: StoreGraph, fromNodeId: string, toNodeId: string, cost: number)
	graph.edges[fromNodeId] = graph.edges[fromNodeId] or {}
	graph.edges[toNodeId] = graph.edges[toNodeId] or {}

	graph.edges[fromNodeId][toNodeId] = cost
	graph.edges[toNodeId][fromNodeId] = cost
end

local function getNodeAutoLinkDistance(node: NavNode): number
	local value = node.instance:GetAttribute("AutoLinkDistance")

	if typeof(value) == "number" then
		return value
	end

	return AUTO_NODE_LINK_DISTANCE
end

local function buildAutoEdges(graph: StoreGraph)
	local nodeList: { NavNode } = {}

	for _, node in graph.nodes do
		table.insert(nodeList, node)
	end

	for _, node in nodeList do
		for _, otherNode in nodeList do
			if node == otherNode then
				continue
			end

			local distance = getFlatDistance(node.cframe.Position, otherNode.cframe.Position)
			local maxDistance = math.max(getNodeAutoLinkDistance(node), getNodeAutoLinkDistance(otherNode))

			if distance > maxDistance then
				continue
			end

			if not isSegmentInsideStore(graph.businessId, node.cframe.Position, otherNode.cframe.Position) then
				continue
			end

			if not isSegmentClearOfObstacles(graph, node.cframe.Position, otherNode.cframe.Position, NPC_ROUTE_CLEARANCE_RADIUS) then
				continue
			end

			addEdge(graph, node.nodeId, otherNode.nodeId, distance)
		end
	end
end

local function canUseDirectRoute(
	graph: StoreGraph,
	fromPosition: Vector3,
	toPosition: Vector3,
	maxDistance: number,
	clearanceRadius: number
): boolean
	local distance = getFlatDistance(fromPosition, toPosition)

	if distance > maxDistance then
		return false
	end

	if not isSegmentInsideStore(graph.businessId, fromPosition, toPosition) then
		return false
	end

	if not isSegmentClearOfObstacles(graph, fromPosition, toPosition, clearanceRadius) then
		return false
	end

	return true
end

local function findNearestVisibleNode(graph: StoreGraph, position: Vector3): NavNode?
	local bestNode: NavNode? = nil
	local bestDistance = math.huge

	for _, node in graph.nodes do
		local distance = getFlatDistance(position, node.cframe.Position)

		if distance >= bestDistance then
			continue
		end

		if not isSegmentInsideStore(graph.businessId, position, node.cframe.Position) then
			continue
		end

		if not isSegmentClearOfObstacles(graph, position, node.cframe.Position) then
			continue
		end

		bestNode = node
		bestDistance = distance
	end

	return bestNode
end

local function simplifyRoute(businessId: string, fromPosition: Vector3, waypoints: { CFrame }): { CFrame }
	if #waypoints <= 1 then
		return waypoints
	end

	local simplified: { CFrame } = {}
	local currentPosition = fromPosition
	local index = 1

	while index <= #waypoints do
		local bestIndex = index

		for testIndex = #waypoints, index, -1 do
			local testPosition = waypoints[testIndex].Position
			local distance = getFlatDistance(currentPosition, testPosition)
			local graph = StoreNavigationService.BuildGraph(businessId)

			if
				distance <= DIRECT_ROUTE_MAX_DISTANCE
				and isSegmentInsideStore(businessId, currentPosition, testPosition)
				and isSegmentClearOfObstacles(graph, currentPosition, testPosition, NPC_SHORTCUT_CLEARANCE_RADIUS)
			then
				bestIndex = testIndex
				break
			end
		end

		table.insert(simplified, waypoints[bestIndex])

		currentPosition = waypoints[bestIndex].Position
		index = bestIndex + 1
	end

	return simplified
end

local function cframeLookingAt(position: Vector3, lookTarget: Vector3): CFrame
	local flatTarget = Vector3.new(lookTarget.X, position.Y, lookTarget.Z)

	if (flatTarget - position).Magnitude < 0.05 then
		return CFrame.new(position)
	end

	return CFrame.lookAt(position, flatTarget)
end

local function roundRouteCorners(businessId: string, waypoints: { CFrame }): { CFrame }
	if #waypoints <= 2 then
		return waypoints
	end

	local rounded: { CFrame } = {}

	table.insert(rounded, waypoints[1])

	local graph = StoreNavigationService.BuildGraph(businessId)

	for index = 2, #waypoints - 1 do
		local previousPosition = waypoints[index - 1].Position
		local currentPosition = waypoints[index].Position
		local nextPosition = waypoints[index + 1].Position

		local directionToPrevious = getFlatDirection(currentPosition, previousPosition)
		local directionToNext = getFlatDirection(currentPosition, nextPosition)

		if not directionToPrevious or not directionToNext then
			table.insert(rounded, waypoints[index])
			continue
		end

		local previousDistance = getFlatDistance(previousPosition, currentPosition)
		local nextDistance = getFlatDistance(currentPosition, nextPosition)

		if previousDistance < MIN_CORNER_SEGMENT_LENGTH or nextDistance < MIN_CORNER_SEGMENT_LENGTH then
			table.insert(rounded, waypoints[index])
			continue
		end

		local radius = math.min(CORNER_RADIUS, previousDistance * 0.4, nextDistance * 0.4)

		local entryPosition = currentPosition + directionToPrevious * radius
		local exitPosition = currentPosition + directionToNext * radius

		local cornerIsSafe =
			isSegmentClearOfObstacles(graph, previousPosition, entryPosition, NPC_CORNER_CLEARANCE_RADIUS)
			and isSegmentClearOfObstacles(graph, entryPosition, exitPosition, NPC_CORNER_CLEARANCE_RADIUS)
			and isSegmentClearOfObstacles(graph, exitPosition, nextPosition, NPC_CORNER_CLEARANCE_RADIUS)

		if cornerIsSafe then
			table.insert(rounded, cframeLookingAt(entryPosition, currentPosition))
			table.insert(rounded, cframeLookingAt(exitPosition, nextPosition))
		else
			table.insert(rounded, waypoints[index])
		end
	end

	table.insert(rounded, waypoints[#waypoints])

	return rounded
end

function StoreNavigationService.InvalidateGraph(businessId: string)
	graphCache[businessId] = nil
	graphBuiltAt[businessId] = nil
end

function StoreNavigationService.BuildGraph(businessId: string): StoreGraph
	local now = os.clock()
	local cached = graphCache[businessId]
	local builtAt = graphBuiltAt[businessId]

	if cached and builtAt and now - builtAt < GRAPH_CACHE_SECONDS then
		return cached
	end

	local nodes: { [string]: NavNode } = {}
	local seenInstances: { [Instance]: boolean } = {}

	for _, tag in NAV_NODE_TAGS do
		for _, instance in CollectionService:GetTagged(tag) do
			if seenInstances[instance] then
				continue
			end

			local instanceBusinessId = instance:GetAttribute("BusinessId")

			if instanceBusinessId ~= nil and instanceBusinessId ~= businessId then
				continue
			end

			if instanceBusinessId == nil and not instance:IsDescendantOf(workspace) then
				continue
			end

			local node = buildNodeFromInstance(instance, businessId)

			if node then
				nodes[node.nodeId] = node
				seenInstances[instance] = true
			end
		end
	end

	local walkZones: { BasePart } = {}

	for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(WorldTags.StoreWalkZone, businessId) do
		if instance:IsA("BasePart") then
			table.insert(walkZones, instance)
		end
	end

	local graph: StoreGraph = {
		businessId = businessId,
		nodes = nodes,
		walkZones = walkZones,
		edges = {}
	}

	graphCache[businessId] = graph
	graphBuiltAt[businessId] = now

	buildAutoEdges(graph)

	return graph
end

function StoreNavigationService.GetNode(graph: StoreGraph, nodeId: string): NavNode?
	return graph.nodes[nodeId]
end

function StoreNavigationService.FindNearestNode(businessId: string, position: Vector3): NavNode?
	local graph = StoreNavigationService.BuildGraph(businessId)
	local nearest: NavNode? = nil
	local nearestDistance = math.huge

	for _, node in graph.nodes do
		local distance = (node.cframe.Position - position).Magnitude

		if distance < nearestDistance then
			nearestDistance = distance
			nearest = node
		end
	end

	if nearest and nearestDistance <= MAX_NODE_SNAP_DISTANCE then
		return nearest
	end

	return nearest
end

function StoreNavigationService.FindNodeByType(businessId: string, nodeType: string): NavNode?
	local graph = StoreNavigationService.BuildGraph(businessId)

	for _, node in graph.nodes do
		if node.nodeType == nodeType then
			return node
		end
	end

	return nil
end

function StoreNavigationService.FindNodeForShelf(businessId: string, shelfId: string): NavNode?
	local graph = StoreNavigationService.BuildGraph(businessId)

	for _, node in graph.nodes do
		if node.shelfId == shelfId then
			return node
		end
	end

	return nil
end

function StoreNavigationService.IsPositionInStore(businessId: string, position: Vector3): boolean
	local graph = StoreNavigationService.BuildGraph(businessId)

	if #graph.walkZones > 0 then
		for _, zone in graph.walkZones do
			local localPos = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size * 0.5 + Vector3.new(STORE_BOUNDARY_PADDING, 4, STORE_BOUNDARY_PADDING)

			if math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z then
				return true
			end
		end

		return false
	end

	for _, node in graph.nodes do
		if (node.cframe.Position - position).Magnitude <= MAX_NODE_SNAP_DISTANCE + 6 then
			return true
		end
	end

	return next(graph.nodes) == nil
end

function StoreNavigationService.ValidateRouteInStore(businessId: string, waypoints: { Vector3 }): boolean
	for index = 1, #waypoints do
		if not StoreNavigationService.IsPositionInStore(businessId, waypoints[index]) then
			return false
		end

		if index < #waypoints then
			local midpoint = (waypoints[index] + waypoints[index + 1]) * 0.5

			if not StoreNavigationService.IsPositionInStore(businessId, midpoint) then
				return false
			end
		end
	end

	return true
end

local function heuristic(from: Vector3, to: Vector3): number
	return (from - to).Magnitude
end

local function reconstructPath(
	cameFrom: { [string]: string },
	currentId: string,
	nodes: { [string]: NavNode }
): { NavNode }
	local path: { NavNode } = {}
	local cursor: string? = currentId

	while cursor do
		local node = nodes[cursor]

		if not node then
			break
		end

		table.insert(path, 1, node)
		cursor = cameFrom[cursor]
	end

	return path
end

function StoreNavigationService.FindRoute(businessId: string, fromNodeId: string, toNodeId: string): { NavNode }
	local graph = StoreNavigationService.BuildGraph(businessId)

	if fromNodeId == toNodeId then
		local node = graph.nodes[fromNodeId]
		return if node then { node } else {}
	end

	local startNode = graph.nodes[fromNodeId]
	local goalNode = graph.nodes[toNodeId]

	if not startNode or not goalNode then
		return {}
	end

	local openSet: { string } = { fromNodeId }
	local cameFrom: { [string]: string } = {}
	local gScore: { [string]: number } = {
		[fromNodeId] = 0,
	}
	local fScore: { [string]: number } = {
		[fromNodeId] = heuristic(startNode.cframe.Position, goalNode.cframe.Position),
	}

	while #openSet > 0 do
		table.sort(openSet, function(leftId: string, rightId: string): boolean
			return (fScore[leftId] or math.huge) < (fScore[rightId] or math.huge)
		end)

		local currentId = table.remove(openSet, 1) :: string

		if currentId == toNodeId then
			return reconstructPath(cameFrom, currentId, graph.nodes)
		end

		local currentNode = graph.nodes[currentId]

		if not currentNode then
			continue
		end

		for neighborId, edgeCost in graph.edges[currentId] or {} do
			local neighbor = graph.nodes[neighborId]

			if not neighbor then
				continue
			end

			local tentativeG = (gScore[currentId] or math.huge) + edgeCost

			if tentativeG < (gScore[neighborId] or math.huge) then
				cameFrom[neighborId] = currentId
				gScore[neighborId] = tentativeG
				fScore[neighborId] = tentativeG + heuristic(neighbor.cframe.Position, goalNode.cframe.Position)

				local inOpen = false

				for _, openId in openSet do
					if openId == neighborId then
						inOpen = true
						break
					end
				end

				if not inOpen then
					table.insert(openSet, neighborId)
				end
			end
		end
	end

	return {}
end

function StoreNavigationService.FindRouteBetweenPositions(
	businessId: string,
	fromPosition: Vector3,
	toPosition: Vector3,
	goalNodeId: string?,
	routeMode: ("Shelf" | "Checkout" | "Exit" | "General")?
): { CFrame }
	local graph = StoreNavigationService.BuildGraph(businessId)

	if next(graph.nodes) == nil then
		return { CFrame.new(toPosition) }
	end

	if routeMode == "Exit" then
		if canUseDirectRoute(graph, fromPosition, toPosition, DIRECT_EXIT_ROUTE_MAX_DISTANCE, EXIT_DIRECT_CLEARANCE_RADIUS) then
			return { CFrame.new(toPosition) }
		end
	end

	local startNode = findNearestVisibleNode(graph, fromPosition)

	if not startNode then
		startNode = StoreNavigationService.FindNearestNode(businessId, fromPosition)
	end

	if not startNode then
		return { CFrame.new(toPosition) }
	end

	local goalNode: NavNode? = nil
	local hasExplicitGoalNode = false

	if goalNodeId then
		local explicitGoalNode = graph.nodes[goalNodeId]

		if explicitGoalNode and isSegmentClearOfObstacles(graph, explicitGoalNode.cframe.Position, toPosition) then
			goalNode = explicitGoalNode
			hasExplicitGoalNode = true
		end
	end

	if not goalNode then
		goalNode = findNearestVisibleNode(graph, toPosition)
	end

	if not goalNode then
		goalNode = StoreNavigationService.FindNearestNode(businessId, toPosition)
	end

	if not goalNode then
		return { CFrame.new(toPosition) }
	end

	local nodePath = StoreNavigationService.FindRoute(businessId, startNode.nodeId, goalNode.nodeId)

	local waypoints: { CFrame } = {}
	for index, node in nodePath do
		local isFirst = index == 1
		local isLast = index == #nodePath

		if isFirst then
			local distanceFromCustomer = (node.cframe.Position - fromPosition).Magnitude

			if distanceFromCustomer < 6 then
				continue
			end
		end

		if isLast and not hasExplicitGoalNode then
			local distanceToFinalTarget = (node.cframe.Position - toPosition).Magnitude

			if distanceToFinalTarget < 7 then
				continue
			end
		end

		table.insert(waypoints, node.cframe)
	end

	local finalCFrame = CFrame.new(toPosition)

	if #waypoints == 0 or (waypoints[#waypoints].Position - toPosition).Magnitude > 1.5 then
		table.insert(waypoints, finalCFrame)
	else
		waypoints[#waypoints] = finalCFrame
	end

	local positions: { Vector3 } = {}

	for _, cframe in waypoints do
		table.insert(positions, cframe.Position)
	end

	if not StoreNavigationService.ValidateRouteInStore(businessId, positions) then
		local trimmed: { CFrame } = {}

		for index, cframe in waypoints do
			local isFinalTarget = index == #waypoints

			if isFinalTarget or StoreNavigationService.IsPositionInStore(businessId, cframe.Position) then
				table.insert(trimmed, cframe)
			end
		end

		if #trimmed > 0 then
			return trimmed
		end
	end

	waypoints = simplifyRoute(businessId, fromPosition, waypoints)

	return roundRouteCorners(businessId, waypoints)
end

function StoreNavigationService.FindRouteToShelf(
	businessId: string,
	fromPosition: Vector3,
	shelfId: string,
	browseCFrame: CFrame
): { CFrame }
	local shelfNode = StoreNavigationService.FindNodeForShelf(businessId, shelfId)

	return StoreNavigationService.FindRouteBetweenPositions(
		businessId,
		fromPosition,
		browseCFrame.Position,
		if shelfNode then shelfNode.nodeId else nil,
		"Shelf"
	)
end

function StoreNavigationService.FindRouteToCheckout(
	businessId: string,
	fromPosition: Vector3,
	checkoutCFrame: CFrame
): { CFrame }
	local checkoutNode = StoreNavigationService.FindNodeByType(businessId, "Checkout")

	return StoreNavigationService.FindRouteBetweenPositions(
		businessId,
		fromPosition,
		checkoutCFrame.Position,
		if checkoutNode then checkoutNode.nodeId else nil,
		"Checkout"
	)
end

function StoreNavigationService.FindRouteToExit(
	businessId: string,
	fromPosition: Vector3,
	exitCFrame: CFrame
): { CFrame }
	return StoreNavigationService.FindRouteBetweenPositions(
		businessId,
		fromPosition,
		exitCFrame.Position,
		nil,
		"Exit"
	)
end

function StoreNavigationService.GetAlternateNode(
	businessId: string,
	blockedNodeId: string,
	currentPosition: Vector3
): NavNode?
	local graph = StoreNavigationService.BuildGraph(businessId)
	local blocked = graph.nodes[blockedNodeId]

	if not blocked then
		return StoreNavigationService.FindNearestNode(businessId, currentPosition)
	end

	local best: NavNode? = nil
	local bestDistance = math.huge

	for _, node in graph.nodes do
		if node.nodeId == blockedNodeId then
			continue
		end

		for _, connectedId in blocked.connectedNodeIds do
			if connectedId == node.nodeId then
				local distance = (node.cframe.Position - currentPosition).Magnitude

				if distance < bestDistance then
					bestDistance = distance
					best = node
				end
			end
		end
	end

	return best or StoreNavigationService.FindNearestNode(businessId, currentPosition)
end

return StoreNavigationService
