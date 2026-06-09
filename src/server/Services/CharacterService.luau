local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Billboards = ReplicatedStorage:WaitForChild("Billboards")
local PlayerInfo = Billboards:WaitForChild("PlayerInfo")

local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)
local Charm = require(ReplicatedStorage.Shared.Modules.Charm)
local BillboardUtil = require(ReplicatedStorage.Shared.Util.Billboard)

local ACCOUNT_WAIT_TIMEOUT = 10

local function waitForAccount(playerName: string)
	local startedAt = os.clock()

	while os.clock() - startedAt < ACCOUNT_WAIT_TIMEOUT do
		local account = AccountStore.getAccount(playerName)

		if account then
			return account
		end

		task.wait()
	end

	return nil
end

local CharacterService = {}

CharacterService.Name = "CharacterService"
CharacterService.Disabled = false

local function onCharacterAdded(player: Player, character: Model)
    local account = waitForAccount(player.Name)

	if not account then
		warn(`Account did not load for {player.Name}`)
		return
	end

	local head = character:WaitForChild("Head") :: BasePart

	if head:FindFirstChild(PlayerInfo.Name) then
		return
	end

	local yOffset = BillboardUtil.GetHeadBillboardYOffset(character)

	local playerInfoClone = PlayerInfo:Clone() :: BillboardGui
	playerInfoClone.Parent = head
	playerInfoClone.StudsOffsetWorldSpace = Vector3.new(0, yOffset + 0.5, 0)
    playerInfoClone:WaitForChild("Name").Text = player.Name

	local overallRank = Charm.computed(function()
        return AccountStore.getAccount(player.Name)
    end)

	local stopEffect = Charm.effect(function()
		local rank = overallRank()
        playerInfoClone:WaitForChild("Rank").Text = rank
	end)

	character.Destroying:Once(function()
		stopEffect()
	end)
end

function CharacterService:OnStart()
	for _, player in Players:GetPlayers() do
		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end

		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end

		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	end)
end

return CharacterService