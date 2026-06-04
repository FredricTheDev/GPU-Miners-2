--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

local function instanceMatchesBusiness(instance: Instance, businessId: string): boolean
	local instanceBusinessId = instance:GetAttribute("BusinessId")
	return instanceBusinessId == nil or instanceBusinessId == businessId
end

local function getCFrame(instance: Instance): CFrame?
	if instance:IsA("BasePart") then
		return instance.CFrame
	elseif instance:IsA("Model") then
		return instance:GetPivot()
	elseif instance:IsA("Attachment") then
		return instance.WorldCFrame
	end
	return nil
end

local function hashString(value: string): number
	local hash = 0
	for index = 1, #value do
		hash = (hash * 31 + string.byte(value, index)) % 100000
	end
	return hash
end

local function getNumberAttribute(instance: Instance?, attributeName: string, fallback: number): number
	if not instance then
		return fallback
	end

	local value = instance:GetAttribute(attributeName)
	return if typeof(value) == "number" then value else fallback
end

local function getQueueDirection(instance: Instance?, baseCFrame: CFrame): Vector3
	if instance then
		local vectorAttribute = instance:GetAttribute("QueueDirection")
		if typeof(vectorAttribute) == "Vector3" and vectorAttribute.Magnitude > 0.05 then
			return vectorAttribute.Unit
		end

		local axisAttribute = instance:GetAttribute("QueueAxis")
		if axisAttribute == "Forward" then
			return baseCFrame.LookVector
		elseif axisAttribute == "Right" then
			return baseCFrame.RightVector
		elseif axisAttribute == "Left" then
			return -baseCFrame.RightVector
		end
	end

	return -baseCFrame.LookVector
end

local function getFlatUnit(vector: Vector3): Vector3?
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 0.05 then
		return nil
	end
	return flat.Unit
end

local function getScatteredCFrame(baseCFrame: CFrame, key: string, radius: number): CFrame
	local hash = hashString(key)
	local angle = math.rad(hash % 360)
	local ring = math.floor(hash / 360) % 3
	local distance = radius + ring * 0.85
	local offset = baseCFrame.RightVector * math.cos(angle) * distance
		+ baseCFrame.LookVector * math.sin(angle) * distance
	return baseCFrame + offset
end

local DEFAULT_STORE_CENTER = CFrame.new(0, 4, 0)

local WorldQueryService = {}

WorldQueryService.Name = "WorldQueryService"
WorldQueryService.Priority = 0

function WorldQueryService:OnInit() end

function WorldQueryService:OnStart() end

function WorldQueryService.GetTaggedInstancesForBusiness(tag: string, businessId: string): { Instance }
	local results = {}
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		if not instance:IsDescendantOf(workspace) then
			continue
		end
		if instanceMatchesBusiness(instance, businessId) then
			table.insert(results, instance)
		end
	end
	return results
end

function WorldQueryService.GetFirstTaggedCFrame(tag: string, businessId: string): CFrame?
	for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(tag, businessId) do
		local cframe = getCFrame(instance)
		if cframe then
			return cframe
		end
	end
	return nil
end

function WorldQueryService.GetSpawnCFrame(businessId: string, customerId: string?): CFrame
	return WorldQueryService.GetFirstTaggedCFrame(WorldTags.CustomerSpawn, businessId) or DEFAULT_STORE_CENTER

	-- local baseCFrame = WorldQueryService.GetFirstTaggedCFrame(WorldTags.CustomerSpawn, businessId) or DEFAULT_STORE_CENTER
	-- if not customerId then
	-- 	return baseCFrame
	-- end

	-- return getScatteredCFrame(baseCFrame, `{businessId}:{customerId}:spawn`, 2.5)
end

function WorldQueryService.GetExitCFrame(businessId: string): CFrame
	return WorldQueryService.GetFirstTaggedCFrame(WorldTags.CustomerExit, businessId)
		or DEFAULT_STORE_CENTER + Vector3.new(0, 0, 30)
end

function WorldQueryService.GetCheckoutQueueCFrame(businessId: string, queueSlot: number): CFrame
	local checkoutInstance: Instance? = nil
	for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(WorldTags.CheckoutPoint, businessId) do
		if getCFrame(instance) then
			checkoutInstance = instance
			break
		end
	end

	local baseCFrame = if checkoutInstance then getCFrame(checkoutInstance) :: CFrame else DEFAULT_STORE_CENTER
	local spacing = getNumberAttribute(checkoutInstance, "QueueSpacing", 3)
	local startOffset = getNumberAttribute(checkoutInstance, "QueueStartOffset", 2.5)
	local queueDirection = getFlatUnit(getQueueDirection(checkoutInstance, baseCFrame))
		or getFlatUnit(-baseCFrame.LookVector)
		or Vector3.zAxis
	local distance = startOffset + math.max(0, queueSlot - 1) * spacing
	local position = baseCFrame.Position + queueDirection * distance
	return CFrame.lookAt(position, position - queueDirection)
end

function WorldQueryService.GetShelfCFrame(businessId: string, shelfId: string): CFrame?
	for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(WorldTags.ShelfPoint, businessId) do
		if instance:GetAttribute("ShelfId") == shelfId then
			return getCFrame(instance)
		end
	end
	return WorldQueryService.GetFirstTaggedCFrame(WorldTags.BrowsePoint, businessId)
end

function WorldQueryService.GetShelfGpuFolder(businessId: string, shelfId: string): Folder?
	for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(WorldTags.ShelfPoint, businessId) do
		if instance:GetAttribute("ShelfId") ~= shelfId then
			continue
		end

		local current: Instance? = instance
		while current and current ~= Workspace do
			local directGpuFolder = current:FindFirstChild("GPUs")
			if directGpuFolder and directGpuFolder:IsA("Folder") then
				return directGpuFolder
			end

			if current:GetAttribute("ShelfId") == shelfId then
				local nestedGpuFolder = current:FindFirstChild("GPUs", true)
				if nestedGpuFolder and nestedGpuFolder:IsA("Folder") then
					return nestedGpuFolder
				end
			end

			current = current.Parent
		end
	end

	return nil
end

function WorldQueryService.GetShelfBrowseCFrame(businessId: string, shelfId: string, slotIndex: number): CFrame?
	for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(WorldTags.ShelfPoint, businessId) do
		if instance:GetAttribute("ShelfId") == shelfId then
			local shelfCFrame = getCFrame(instance)

			if shelfCFrame then
				local browseDistance = getNumberAttribute(instance, "BrowseDistance", 2.1)
				local sideSpacing = getNumberAttribute(instance, "BrowseSideSpacing", 1.45)
				local depthSpacing = getNumberAttribute(instance, "BrowseDepthSpacing", 0.25)

				local centerSlot = math.ceil(7 / 2)
				local sideSlot = slotIndex - centerSlot
				local depthSlot = math.abs(sideSlot) % 2

				local position = shelfCFrame.Position
					+ shelfCFrame.LookVector * (browseDistance + depthSlot * depthSpacing)
					+ shelfCFrame.RightVector * sideSlot * sideSpacing

				return CFrame.lookAt(position, shelfCFrame.Position)
			end
		end
	end

	local fallbackCFrame = WorldQueryService.GetFirstTaggedCFrame(WorldTags.BrowsePoint, businessId)
	if fallbackCFrame then
		return fallbackCFrame
	end

	return nil
end

function WorldQueryService.HasLineOfSight(
	fromPosition: Vector3,
	toInstance: Instance,
	ignoreList: { Instance }
): boolean
	local targetCFrame = getCFrame(toInstance)
	if not targetCFrame then
		return false
	end

	local direction = targetCFrame.Position - fromPosition
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = ignoreList

	local result = Workspace:Raycast(fromPosition, direction, raycastParams)
	return result == nil or result.Instance:IsDescendantOf(toInstance)
end

function WorldQueryService.GetCFrame(instance: Instance): CFrame?
	return getCFrame(instance)
end

function WorldQueryService.GetNavigationNodeInstances(businessId: string): { Instance }
	local results: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	for _, tag in
		{
			WorldTags.StoreNavNode,
			WorldTags.EntranceNode,
			WorldTags.ExitNode,
			WorldTags.CheckoutNode,
			WorldTags.ShelfNavNode,
		}
	do
		for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(tag, businessId) do
			if not seen[instance] then
				seen[instance] = true
				table.insert(results, instance)
			end
		end
	end

	return results
end

return WorldQueryService
