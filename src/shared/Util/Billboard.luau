local Billboard = {}

local DEFAULT_PADDING = 0.6
local DEFAULT_MIN_OFFSET = 0.85
local DEFAULT_FALLBACK_OFFSET = 2.5
local DEFAULT_MAX_OFFSET = 7

local HEAD_ACCESSORY_TYPES = {
	[Enum.AccessoryType.Hat] = true,
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Face] = true,
	[Enum.AccessoryType.Eyebrow] = true,
	[Enum.AccessoryType.Eyelash] = true,
}

local function getPartHighestWorldY(part: BasePart): number
	local halfSize = part.Size * 0.5
	local maxY = -math.huge

	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local localCorner = Vector3.new(
					halfSize.X * x,
					halfSize.Y * y,
					halfSize.Z * z
				)

				local worldCorner = part.CFrame:PointToWorldSpace(localCorner)
				maxY = math.max(maxY, worldCorner.Y)
			end
		end
	end

	return maxY
end

local function accessoryAttachesToHead(accessory: Accessory, head: BasePart): boolean
	local handle = accessory:FindFirstChild("Handle")

	if not handle then
		return false
	end

	for _, descendant in ipairs(handle:GetDescendants()) do
		if descendant:IsA("Attachment") then
			local matchingHeadAttachment = head:FindFirstChild(descendant.Name, true)

			if matchingHeadAttachment and matchingHeadAttachment:IsA("Attachment") then
				return true
			end
		end
	end

	return false
end

local function shouldUseAccessory(accessory: Accessory, head: BasePart): boolean
	if HEAD_ACCESSORY_TYPES[accessory.AccessoryType] then
		return true
	end

	return accessoryAttachesToHead(accessory, head)
end

local function getCharacterModel(instance: Instance?): Model?
	if not instance then
		return nil
	end

	if instance:IsA("Model") then
		return instance
	end

	return instance:FindFirstAncestorOfClass("Model")
end

local function getOffsetOrigin(instance: Instance?, fallback: BasePart): BasePart
	if instance and instance:IsA("BasePart") then
		return instance
	end

	return fallback
end

function Billboard.GetHeadBillboardYOffset(
	characterOrAdornee: Instance?,
	adornee: Instance?,
	padding: number?,
	minOffset: number?,
	maxOffset: number?
): number
	local character = getCharacterModel(characterOrAdornee)

	if not character then
		return minOffset or DEFAULT_FALLBACK_OFFSET
	end

	local head = character:FindFirstChild("Head")

	if not head or not head:IsA("BasePart") then
		return minOffset or DEFAULT_FALLBACK_OFFSET
	end

	local highestY = getPartHighestWorldY(head)

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Accessory") and shouldUseAccessory(child, head) then
			for _, descendant in ipairs(child:GetDescendants()) do
				if descendant:IsA("BasePart") then
					highestY = math.max(highestY, getPartHighestWorldY(descendant))
				end
			end
		end
	end

	local origin = getOffsetOrigin(adornee or characterOrAdornee, head)
	local offsetY = highestY - origin.Position.Y + (padding or DEFAULT_PADDING)

	return math.clamp(
		offsetY,
		minOffset or DEFAULT_MIN_OFFSET,
		maxOffset or DEFAULT_MAX_OFFSET
	)
end

return Billboard
