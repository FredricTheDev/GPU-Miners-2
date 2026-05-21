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

local DEFAULT_STORE_CENTER = CFrame.new(0, 4, 0)

local WorldQueryService = {}

WorldQueryService.Name = "WorldQueryService"
WorldQueryService.Priority = 0

function WorldQueryService:OnInit() end

function WorldQueryService:OnStart() end

function WorldQueryService.GetTaggedInstancesForBusiness(tag: string, businessId: string): { Instance }
	local results = {}
	for _, instance in CollectionService:GetTagged(tag) do
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

function WorldQueryService.GetSpawnCFrame(businessId: string): CFrame
    return WorldQueryService.GetFirstTaggedCFrame(WorldTags.CustomerSpawn, businessId) or DEFAULT_STORE_CENTER
end

function WorldQueryService.GetExitCFrame(businessId: string): CFrame
	return WorldQueryService.GetFirstTaggedCFrame(WorldTags.CustomerExit, businessId) or DEFAULT_STORE_CENTER + Vector3.new(0, 0, 30)
end

function WorldQueryService.GetCheckoutCFrame(businessId: string): CFrame
	return WorldQueryService.GetFirstTaggedCFrame(WorldTags.CheckoutPoint, businessId) or DEFAULT_STORE_CENTER + Vector3.new(10, 0, 0)
end

function WorldQueryService.GetShelfCFrame(businessId: string, shelfId: string): CFrame?
	for _, instance in WorldQueryService.GetTaggedInstancesForBusiness(WorldTags.ShelfPoint, businessId) do
		if instance:GetAttribute("ShelfId") == shelfId then
			return getCFrame(instance)
		end
	end
	return WorldQueryService.GetFirstTaggedCFrame(WorldTags.BrowsePoint, businessId)
end

function WorldQueryService.GetOrCreateCustomerFolder(): Folder
	local existing = Workspace:FindFirstChild("ActiveCustomers")
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "ActiveCustomers"
	folder.Parent = Workspace
	return folder
end

function WorldQueryService.HasLineOfSight(fromPosition: Vector3, toInstance: Instance, ignoreList: { Instance }): boolean
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

return WorldQueryService
