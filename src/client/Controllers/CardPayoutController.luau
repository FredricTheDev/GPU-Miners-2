--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplicaClient = require(ReplicatedStorage.Packages.Replica)

local CardPayoutController = {}

CardPayoutController.Name = "CardPayoutController"
CardPayoutController.Priority = 0
CardPayoutController.Dependencies = {}
CardPayoutController.Disabled = false

local localPlayer = Players.LocalPlayer
local claimRemote: RemoteFunction? = nil
local screenGui: ScreenGui? = nil
local claimButton: TextButton? = nil
local claimableAmount = 0
local updateClaimable: (any) -> ()

local function getClaimRemote(): RemoteFunction
	if claimRemote then
		return claimRemote
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local checkoutFolder = remotes:WaitForChild("Checkout")
	claimRemote = checkoutFolder:WaitForChild("ClaimCardFunds") :: RemoteFunction
	return claimRemote :: RemoteFunction
end

local function formatMoney(amount: number): string
	local rounded = math.floor(amount + 0.5)
	local text = tostring(rounded)
	local result = text
	while true do
		local replaced
		result, replaced = string.gsub(result, "^(-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return "$" .. result
end

local function ensureGui()
	if screenGui and claimButton then
		return
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui")

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CardPayout"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	claimButton = Instance.new("TextButton")
	claimButton.Name = "ClaimCardFunds"
	claimButton.AnchorPoint = Vector2.new(1, 1)
	claimButton.Position = UDim2.fromScale(0.985, 0.94)
	claimButton.Size = UDim2.fromOffset(240, 44)
	claimButton.BackgroundColor3 = Color3.fromRGB(24, 132, 88)
	claimButton.BorderSizePixel = 0
	claimButton.Font = Enum.Font.GothamBold
	claimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	claimButton.TextScaled = true
	claimButton.Visible = false
	claimButton.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = claimButton

	local textConstraint = Instance.new("UITextSizeConstraint")
	textConstraint.MinTextSize = 12
	textConstraint.MaxTextSize = 18
	textConstraint.Parent = claimButton

	claimButton.Activated:Connect(function()
		if claimableAmount <= 0 then
			return
		end

		local success, claimed = pcall(function()
			return getClaimRemote():InvokeServer()
		end)
		if success and typeof(claimed) == "number" and claimed > 0 then
			updateClaimable(math.max(0, claimableAmount - claimed))
		end
	end)
end

updateClaimable = function(amount: any)
	if typeof(amount) ~= "number" then
		amount = 0
	end

	claimableAmount = math.max(0, amount)
	ensureGui()

	if claimButton then
		claimButton.Text = `Claim card funds: {formatMoney(claimableAmount)}`
		claimButton.Visible = claimableAmount > 0
	end
end

function CardPayoutController:OnInit() end

function CardPayoutController:OnStart()
	task.spawn(function()
		getClaimRemote()
	end)

	ReplicaClient.OnNew("PlayerData", function(replica: any)
		if replica.Tags.OwnerId ~= localPlayer.UserId then
			return
		end

		updateClaimable(replica.Data.ClaimableCardPayout)
		replica:OnSet({ "ClaimableCardPayout" }, function(newValue)
			updateClaimable(newValue)
		end)
	end)
end

return CardPayoutController
