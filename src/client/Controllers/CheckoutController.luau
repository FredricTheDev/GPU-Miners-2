--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Billboards = ReplicatedStorage:WaitForChild("Billboards")

local CheckoutMessage = Billboards:WaitForChild("CheckoutMessage")
local CheckoutPrompt = Billboards:WaitForChild("CheckoutPrompt")

local ActiveCustomers = workspace:WaitForChild("ActiveCustomers")

local BillboardUtil = require(ReplicatedStorage.Shared.Util.Billboard)

local FADE_START_DISTANCE = 10
local FADE_END_DISTANCE = 50

local CheckoutController = {}

CheckoutController.Name = "CheckoutController"
CheckoutController.Priority = 0
CheckoutController.Dependencies = {}
CheckoutController.Disabled = false

local activeMessageStacks: { [Instance]: BillboardGui } = {}

local localPlayer = Players.LocalPlayer

local clickRemote: RemoteEvent
local visualsRemote: RemoteEvent

local activeOptions: { [string]: BillboardGui } = {}
local activeThinkingMessages: { [string]: BillboardGui } = {}
local activeThinkingAdornees: { [string]: Instance } = {}

local function getCustomerModel(customerId: string): Model?
	for _, customer in ActiveCustomers:GetChildren() do
		if customer:GetAttribute("CustomerId") == customerId then
			return customer
		end
	end
	return nil
end

local function getHeadOffset(character: Model?, adornee: Instance): number
	return BillboardUtil.GetHeadBillboardYOffset(character or adornee, adornee)
end

local function getOrCreateMessageStack(adornee: Instance, offset: Vector3): BillboardGui
	local existing = activeMessageStacks[adornee]
	if existing and existing.Parent then
		return existing
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "LocalCheckoutMessageStack"
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 70
	billboard.Size = UDim2.fromScale(4, 4)
	billboard.StudsOffsetWorldSpace = offset
	billboard.Active = false
	billboard.ResetOnSpawn = false
	billboard.Adornee = adornee
	billboard.Parent = localPlayer:WaitForChild("PlayerGui")

	local list = Instance.new("UIListLayout")
	list.Name = "MessagesLayout"
	list.FillDirection = Enum.FillDirection.Vertical
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = billboard

	activeMessageStacks[adornee] = billboard
	return billboard
end

local function setOnlyNewestMessageHasCavet(stack: BillboardGui)
	local newest: GuiObject? = nil

	for _, child in stack:GetChildren() do
		if child:IsA("GuiObject") then
			if not newest or child.LayoutOrder > newest.LayoutOrder then
				newest = child
			end
		end
	end

	for _, child in stack:GetChildren() do
		if child:IsA("GuiObject") then
			local canvasGroup = child:FindFirstChild("CanvasGroup")
			local cavet = canvasGroup and canvasGroup:FindFirstChild("Cavet", true)

			if cavet and cavet:IsA("GuiObject") then
				cavet.Visible = child == newest
			end
		end
	end
end

local function tween(instance: Instance, info: TweenInfo, props: { [string]: any })
	local createdTween = TweenService:Create(instance, info, props)
	createdTween:Play()
	return createdTween
end

local function animateBillboardOut(billboard: BillboardGui)
	local frame = billboard:FindFirstChild("Card")
	local scale = frame and frame:FindFirstChildOfClass("UIScale")

	if frame and scale then
		tween(scale, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Scale = 0.88,
		})

		tween(frame, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		})

		task.delay(0.15, function()
			if billboard.Parent then
				billboard:Destroy()
			end
		end)
	else
		billboard:Destroy()
	end
end

local function hideOption(customerId: string)
	local existing = activeOptions[customerId]
	if existing then
		activeOptions[customerId] = nil
		animateBillboardOut(existing)
	end
end

local function showOption(payload: any)
	if typeof(payload.customerId) ~= "string" then
		return
	end
	if typeof(payload.action) ~= "string" then
		return
	end
	if typeof(payload.text) ~= "string" then
		return
	end
	if typeof(payload.adornee) ~= "Instance" then
		return
	end

	hideOption(payload.customerId)

	local customerId = payload.customerId
	local action = payload.action

	local billboard = CheckoutPrompt:Clone()
	billboard.Name = "LocalCheckoutOption"
	billboard.Adornee = payload.adornee
	billboard.Enabled = true
	billboard.Parent = localPlayer:WaitForChild("PlayerGui")

	local customerModel = getCustomerModel(customerId)
	local yOffset = getHeadOffset(customerModel, payload.adornee)

	billboard.StudsOffsetWorldSpace = Vector3.new(0, yOffset + 0.3, 0)

	local content = billboard:WaitForChild("Content")
	local prompt = content:WaitForChild("Prompt") :: TextLabel
	local button = content:WaitForChild("Button") :: TextButton

	prompt.Text = payload.text

	local scale = content:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = content
	end

	local connection = RunService.PreSimulation:Connect(function()
		if not customerModel then
			return
		end

		local root = customerModel:WaitForChild("HumanoidRootPart")
		local localRoot = localPlayer.Character:WaitForChild("HumanoidRootPart")
		local distance = (root.Position - localRoot.Position).Magnitude

		local alpha = math.clamp((distance - FADE_START_DISTANCE) / (FADE_END_DISTANCE - FADE_START_DISTANCE), 0, 1)
		local transparency = 0.7 + alpha * 0.7

		content:WaitForChild("UIShadow").Transparency = transparency
	end)

	scale.Scale = 0.85
	tween(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	})

	button.MouseEnter:Connect(function()
		tween(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 1.06,
		})
	end)

	button.MouseLeave:Connect(function()
		tween(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 1,
		})
	end)

	button.MouseButton1Down:Connect(function()
		tween(scale, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 0.95,
		})
	end)

	button.MouseButton1Click:Connect(function()
		clickRemote:FireServer(customerId, action)
	end)

	billboard.Destroying:Once(function()
		connection:Disconnect()
	end)

	activeOptions[customerId] = billboard
end

local messageOrder = 0

local function cleanupMessageFromStack(messageBillboard: BillboardGui, stack: BillboardGui, adornee: Instance)
	if messageBillboard.Parent then
		messageBillboard:Destroy()
	end

	if stack.Parent then
		setOnlyNewestMessageHasCavet(stack)

		local hasMessages = false
		for _, child in stack:GetChildren() do
			if child:IsA("GuiObject") then
				hasMessages = true
				break
			end
		end

		if not hasMessages then
			activeMessageStacks[adornee] = nil
			stack:Destroy()
		end
	end
end

local function fadeMessageOut(messageBillboard: BillboardGui, stack: BillboardGui, adornee: Instance)
	if not messageBillboard.Parent then
		return
	end

	local scale = messageBillboard:FindFirstChildOfClass("UIScale")

	tween(messageBillboard, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		GroupTransparency = 1,
	})

	if scale then
		tween(scale, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Scale = 0.9,
		})
	end

	task.delay(0.15, function()
		cleanupMessageFromStack(messageBillboard, stack, adornee)
	end)
end

local function createMessageBillboard(
	adornee: Instance,
	text: string,
	character: Model?
): (BillboardGui, BillboardGui, TextLabel)
	local offset = getHeadOffset(character, adornee)
	local stack = getOrCreateMessageStack(adornee, Vector3.new(0, offset + 1.5, 0))

	messageOrder += 1

	local messageBillboard = CheckoutMessage:Clone()
	messageBillboard.Name = "Message"
	messageBillboard.LayoutOrder = messageOrder
	messageBillboard.Parent = stack

	local content = messageBillboard:WaitForChild("Content")
	local message = content:WaitForChild("Message") :: TextLabel

	message.Text = text
	messageBillboard.GroupTransparency = 1

	local scale = messageBillboard:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = messageBillboard
	end

	scale.Scale = 0.88

	tween(messageBillboard, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		GroupTransparency = 0,
	})

	tween(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	})

	setOnlyNewestMessageHasCavet(stack)

	return messageBillboard, stack, message
end

local function hideThinking(customerId: string)
	local existing = activeThinkingMessages[customerId]
	local adornee = activeThinkingAdornees[customerId]

	if not existing or not adornee then
		activeThinkingMessages[customerId] = nil
		activeThinkingAdornees[customerId] = nil
		return
	end

	activeThinkingMessages[customerId] = nil
	activeThinkingAdornees[customerId] = nil

	local stack = existing.Parent
	if stack and stack:IsA("BillboardGui") then
		fadeMessageOut(existing, stack, adornee)
	else
		existing:Destroy()
	end
end

local function showThinking(payload: any)
	if typeof(payload.customerId) ~= "string" then
		return
	end
	if typeof(payload.adornee) ~= "Instance" then
		return
	end

	local customerId = payload.customerId
	hideThinking(customerId)

	local messageBillboard, _, message = createMessageBillboard(payload.adornee, ".", getCustomerModel(customerId))
	activeThinkingMessages[customerId] = messageBillboard
	activeThinkingAdornees[customerId] = payload.adornee

	messageBillboard.Destroying:Once(function()
		if activeThinkingMessages[customerId] == messageBillboard then
			activeThinkingMessages[customerId] = nil
			activeThinkingAdornees[customerId] = nil
		end
	end)

	task.spawn(function()
		local frames = { ".", "..", "..." }
		local frameIndex = 1

		while activeThinkingMessages[customerId] == messageBillboard and messageBillboard.Parent do
			message.Text = frames[frameIndex]
			frameIndex = if frameIndex == #frames then 1 else frameIndex + 1
			task.wait(0.28)
		end
	end)
end

local function showSpeech(payload: any)
	if typeof(payload.text) ~= "string" then
		return
	end
	if typeof(payload.seconds) ~= "number" then
		return
	end
	if typeof(payload.adornee) ~= "Instance" then
		return
	end

	if typeof(payload.customerId) == "string" then
		local existing = activeThinkingMessages[payload.customerId]
		local adornee = activeThinkingAdornees[payload.customerId]
		local stack = existing and existing.Parent

		if existing and adornee and stack and stack:IsA("BillboardGui") then
			activeThinkingMessages[payload.customerId] = nil
			activeThinkingAdornees[payload.customerId] = nil

			local content = existing:FindFirstChild("Content")
			local message = content and content:FindFirstChild("Message")

			if message and message:IsA("TextLabel") then
				message.Text = payload.text
				task.delay(payload.seconds, function()
					fadeMessageOut(existing, stack, adornee)
				end)
				return
			end
		end
	end

	local customerModel = if typeof(payload.customerId) == "string" then getCustomerModel(payload.customerId) else nil
	local messageBillboard, stack = createMessageBillboard(payload.adornee, payload.text, customerModel)

	task.delay(payload.seconds, function()
		fadeMessageOut(messageBillboard, stack, payload.adornee)
	end)
end

function CheckoutController:OnInit() end

function CheckoutController:OnStart()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local checkoutFolder = remotes:WaitForChild("Checkout")

	clickRemote = checkoutFolder:WaitForChild("ClickCheckoutBillboard") :: RemoteEvent
	visualsRemote = checkoutFolder:WaitForChild("CheckoutVisuals") :: RemoteEvent

	visualsRemote.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		if payload.type == "ShowOption" then
			showOption(payload)
		elseif payload.type == "HideOption" then
			if typeof(payload.customerId) == "string" then
				hideOption(payload.customerId)
			end
		elseif payload.type == "ShowThinking" then
			showThinking(payload)
		elseif payload.type == "HideThinking" then
			if typeof(payload.customerId) == "string" then
				hideThinking(payload.customerId)
			end
		elseif payload.type == "ShowSpeech" then
			showSpeech(payload)
		end
	end)
end

return CheckoutController
