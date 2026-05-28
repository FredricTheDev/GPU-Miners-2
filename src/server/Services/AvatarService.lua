--!strict
local Players = game:GetService("Players")

type FriendCache = {
	loaded: boolean,
	nextIndex: number,
	userIds: { number },
}

local friendCacheByUserId: { [number]: FriendCache } = {}

local FALLBACK_AVATAR_USER_IDS = {
	1,
	156,
	261,
	272,
	304,
	448,
	649,
	1199,
	2139,
	8166491,
	2619619496,
}

local function getFriendCache(ownerUserId: number): FriendCache
	local cache = friendCacheByUserId[ownerUserId]
	if cache then
		return cache
	end

	local friendCache = {
		loaded = false,
		nextIndex = 1,
		userIds = {},
	}
	friendCacheByUserId[ownerUserId] = friendCache
	return friendCache
end

local AvatarService = {}

AvatarService.Name = "AvatarService"
AvatarService.Priority = 0

function AvatarService:OnInit() end

function AvatarService:OnStart() end

function AvatarService.WarmFriendCacheAsync(ownerUserId: number)
	local cache = getFriendCache(ownerUserId)
	if cache.loaded then
		return
	end

	local success, pagesOrError = pcall(function()
		return Players:GetFriendsAsync(ownerUserId)
	end)

	if not success then
		warn(`Failed to load friends for user {ownerUserId}: ${pagesOrError}`)
		cache.loaded = true
		return
	end

	local pages = pagesOrError
	while true do
		for _, friendInfo in pages:GetCurrentPage() do
			local userId = friendInfo.Id
			if typeof(userId) == "number" then
				table.insert(cache.userIds, userId)
			end
		end

		if pages.IsFinished then
			break
		end

		local advanceSuccess, advanceError = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)

		if not advanceSuccess then
			warn(`Failed to advance friend pages for user {ownerUserId}: {advanceError}`)
			break
		end
	end

	cache.loaded = true
end

function AvatarService.GetAvatarUserIdForOwner(ownerUserId: number): number
	local cache = getFriendCache(ownerUserId)
	if not cache.loaded then
		task.spawn(AvatarService.WarmFriendCacheAsync, ownerUserId)
	end

	if #cache.userIds > 0 then
		local userId = cache.userIds[cache.nextIndex]
		cache.nextIndex += 1
		if cache.nextIndex > #cache.userIds then
			cache.nextIndex = 1
		end
		return userId
	end

	return FALLBACK_AVATAR_USER_IDS[math.random(1, #FALLBACK_AVATAR_USER_IDS)]
end

function AvatarService.CreateCustomerModelAsync(avatarUserId: number, modelName: string): Model?
	local success, modelOrError = pcall(function()
		local description = Players:GetHumanoidDescriptionFromUserIdAsync(1)
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R6)
	end)

	if success then
		local model = modelOrError :: Model
		model.Name = modelName
		if not model.PrimaryPart then
			local root = model:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				model.PrimaryPart = root
			end
		end
		return model
	end

	warn(`Failed to create customer avatar {avatarUserId}: {modelOrError}`)
	return nil
end

return AvatarService
