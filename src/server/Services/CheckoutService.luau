--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)

type CheckoutStep = "WaitingForCashier" | "GreetingQuestion" | "Scanning" | "PaymentQuestion" | "Paying" | "Complete"

type PaymentMethod = "Cash" | "Card"

type CheckoutSession = {
	businessId: string,
	customerId: string,
	customerModel: Model,
	step: CheckoutStep,
	assignedPlayerUserId: number?,
	prompt: ProximityPrompt?,
	promptConnection: RBXScriptConnection?,
	currentQuestionText: string?,
	completed: boolean,
}

type CheckoutServiceType = RuntimeTypes.ModuleRuntimeType & {
	_registry: any,
	_businessService: any?,
	_customerService: any?,

	Configure: (self: CheckoutServiceType, registry: any) -> (),
	OnInit: (self: CheckoutServiceType) -> (),
	OnStart: (self: CheckoutServiceType) -> (),

	OpenCheckoutInteraction: (businessId: string, customerId: string, customerModel: Model) -> boolean,
	CancelCheckoutInteraction: (businessId: string, customerId: string) -> (),
	IsCheckoutComplete: (businessId: string, customerId: string) -> boolean,
	CompleteCheckoutByStaff: (businessId: string, customerId: string, staffId: string?) -> boolean,
}

local CheckoutService = {} :: CheckoutServiceType

CheckoutService.Name = "CheckoutService"
CheckoutService.Priority = 0
CheckoutService.Dependencies = { "BusinessService", "CustomerService" }
CheckoutService.Disabled = false

local IN_GAME_DAY_SECONDS = 300
local SCAN_SECONDS = 1.75
local PAY_SECONDS = 1.25
local COMPLETED_MEMORY_SECONDS = 12
local MAX_CHECKOUT_CLICK_DISTANCE = 40
local CUSTOMER_REPLY_DELAY = 1
local MESSAGE_CLEAR_BUFFER = 0.2

local activeByCustomerId: { [string]: CheckoutSession } = {}
local completedUntilByCustomerId: { [string]: number } = {}

local clickBillboardRemote: RemoteEvent? = nil
local checkoutVisualsRemote: RemoteEvent? = nil
local claimCardFundsRemote: RemoteFunction? = nil

local greetingPrompts = {
	"Did you find everything today?",
	"Will that be all today?",
	"Can I ring this up for you?",
}

local greetingResponses = {
	"Found exactly what I needed.",
	"Yeah, this should do the job.",
	"Looks good. Thanks.",
}

local function getSessionKey(businessId: string, customerId: string): string
	return `{businessId}:{customerId}`
end

local function getModelAdornee(model: Model): BasePart?
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	return model.PrimaryPart
end

local function getPlayerAdornee(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return getModelAdornee(character)
end

local function isSessionActive(session: CheckoutSession): boolean
	local current = activeByCustomerId[getSessionKey(session.businessId, session.customerId)]

	return current == session and not session.completed
end

local function waitForSession(session: CheckoutSession, seconds: number): boolean
	local endTime = os.clock() + seconds

	while os.clock() < endTime do
		if not isSessionActive(session) then
			return false
		end

		task.wait(math.min(0.1, endTime - os.clock()))
	end

	return isSessionActive(session)
end

local function hideOption(player: Player, customerId: string)
	if not checkoutVisualsRemote then
		return
	end

	checkoutVisualsRemote:FireClient(player, {
		type = "HideOption",
		customerId = customerId,
	})
end

local function showOption(session: CheckoutSession, player: Player, action: string, text: string)
	local adornee = getModelAdornee(session.customerModel)
	if not adornee or not checkoutVisualsRemote then
		return
	end

	checkoutVisualsRemote:FireClient(player, {
		type = "ShowOption",
		customerId = session.customerId,
		action = action,
		text = text,
		adornee = adornee,
		offset = Vector3.new(0, 4.6, 0),
	})
end

local function showSpeechToAll(adornee: BasePart, text: string, seconds: number, customerId: string?)
	if not checkoutVisualsRemote then
		return
	end

	checkoutVisualsRemote:FireAllClients({
		type = "ShowSpeech",
		text = text,
		seconds = seconds,
		adornee = adornee,
		customerId = customerId,
	})
end

local function showCustomerSpeech(session: CheckoutSession, text: string, seconds: number)
	local adornee = getModelAdornee(session.customerModel)
	if not adornee then
		return
	end

	showSpeechToAll(adornee, text, seconds, session.customerId)
end

local function showCustomerThinking(session: CheckoutSession)
	local adornee = getModelAdornee(session.customerModel)
	if not adornee or not checkoutVisualsRemote then
		return
	end

	checkoutVisualsRemote:FireAllClients({
		type = "ShowThinking",
		customerId = session.customerId,
		adornee = adornee,
	})
end

local function hideCustomerThinking(session: CheckoutSession)
	if not checkoutVisualsRemote then
		return
	end

	checkoutVisualsRemote:FireAllClients({
		type = "HideThinking",
		customerId = session.customerId,
	})
end

local function showPlayerSpeech(player: Player, text: string)
	local adornee = getPlayerAdornee(player)
	if not adornee then
		return
	end

	showSpeechToAll(adornee, text, 2.5, nil)
end

local function cleanupSession(session: CheckoutSession)
	hideCustomerThinking(session)

	if session.promptConnection then
		session.promptConnection:Disconnect()
		session.promptConnection = nil
	end

	if session.prompt then
		session.prompt:Destroy()
		session.prompt = nil
	end

	if session.assignedPlayerUserId then
		local player = Players:GetPlayerByUserId(session.assignedPlayerUserId)
		if player then
			hideOption(player, session.customerId)
		end
	end

	activeByCustomerId[getSessionKey(session.businessId, session.customerId)] = nil
end

local function isFrontCheckoutCustomer(businessId: string, customerId: string): boolean
	return CheckoutService._customerService.GetCheckoutQueueSlot(businessId, customerId) == 1
end

local function canPlayerServeBusiness(player: Player, businessId: string): boolean
	local business = CheckoutService._businessService.GetBusinessForPlayer(player)
	if not business then
		return false
	end
	return business.id == businessId
end

local function isPlayerNearCustomer(player: Player, customerModel: Model, maxDistance: number): boolean
	local playerPart = getPlayerAdornee(player)
	local customerPart = getModelAdornee(customerModel)

	if not playerPart or not customerPart then
		return false
	end

	return (playerPart.Position - customerPart.Position).Magnitude <= maxDistance
end

local function pickPaymentMethod(customerId: string): PaymentMethod
	local hash = 0

	for index = 1, #customerId do
		hash = (hash * 31 + string.byte(customerId, index)) % 1000
	end

	return if hash % 100 < 55 then "Cash" else "Card"
end

local function completePurchase(session: CheckoutSession, paymentMethod: PaymentMethod): boolean
	if session.completed then
		return true
	end

	session.step = "Paying"

	local purchased = CheckoutService._customerService.TryCompletePhysicalPurchase(
		session.businessId,
		session.customerId,
		paymentMethod
	)

	session.completed = purchased
	session.step = "Complete"

	completedUntilByCustomerId[getSessionKey(session.businessId, session.customerId)] = os.clock()
		+ COMPLETED_MEMORY_SECONDS

	cleanupSession(session)

	return purchased
end

local function startPlayerCheckout(session: CheckoutSession, player: Player)
	if session.step ~= "WaitingForCashier" or session.completed then
		return
	end

	if not canPlayerServeBusiness(player, session.businessId) then
		return
	end

	if not isFrontCheckoutCustomer(session.businessId, session.customerId) then
		return
	end

	if not isPlayerNearCustomer(player, session.customerModel, MAX_CHECKOUT_CLICK_DISTANCE) then
		return
	end

	session.assignedPlayerUserId = player.UserId
	session.step = "GreetingQuestion"

	if session.prompt then
		session.prompt.Enabled = false
	end

	local promptText = greetingPrompts[math.random(1, #greetingPrompts)]
	session.currentQuestionText = promptText

	showOption(session, player, "Greeting", promptText)
end

local function handleGreetingClick(session: CheckoutSession, player: Player)
	if session.step ~= "GreetingQuestion" then
		return
	end

	session.step = "Scanning"

	hideOption(player, session.customerId)

	showPlayerSpeech(player, session.currentQuestionText or "Did you find everything today?")

	task.spawn(function()
		showCustomerThinking(session)

		if not waitForSession(session, CUSTOMER_REPLY_DELAY) then
			return
		end

		local responseSeconds = 2.5
		showCustomerSpeech(session, greetingResponses[math.random(1, #greetingResponses)], responseSeconds)

		if not waitForSession(session, math.max(SCAN_SECONDS, responseSeconds + MESSAGE_CLEAR_BUFFER)) then
			return
		end

		local current = activeByCustomerId[getSessionKey(session.businessId, session.customerId)]

		if current ~= session then
			return
		end

		if session.completed or session.step ~= "Scanning" then
			return
		end

		session.step = "PaymentQuestion"
		showOption(session, player, "Payment", "Cash or card?")
	end)
end

local function handlePaymentClick(session: CheckoutSession, player: Player)
	if session.step ~= "PaymentQuestion" then
		return
	end

	session.step = "Paying"

	hideOption(player, session.customerId)

	showPlayerSpeech(player, "Cash or card?")

	local paymentMethod = pickPaymentMethod(session.customerId)

	task.spawn(function()
		showCustomerThinking(session)

		if not waitForSession(session, CUSTOMER_REPLY_DELAY) then
			return
		end

		local responseSeconds = 2

		if paymentMethod == "Cash" then
			showCustomerSpeech(session, "Cash, please.", responseSeconds)
		else
			showCustomerSpeech(session, "I'll use card.", responseSeconds)
		end

		if not waitForSession(session, math.max(PAY_SECONDS, responseSeconds + MESSAGE_CLEAR_BUFFER)) then
			return
		end

		completePurchase(session, paymentMethod)
	end)
end

local function handleBillboardClick(player: Player, customerId: any, action: any)
	if typeof(customerId) ~= "string" or typeof(action) ~= "string" then
		return
	end

	for _, session in activeByCustomerId do
		if session.customerId ~= customerId then
			continue
		end

		if session.assignedPlayerUserId ~= player.UserId then
			return
		end

		if not canPlayerServeBusiness(player, session.businessId) then
			return
		end

		if not isFrontCheckoutCustomer(session.businessId, session.customerId) then
			return
		end

		if not isPlayerNearCustomer(player, session.customerModel, MAX_CHECKOUT_CLICK_DISTANCE) then
			return
		end

		if action == "Greeting" then
			handleGreetingClick(session, player)
		elseif action == "Payment" then
			handlePaymentClick(session, player)
		end

		return
	end
end

local function ensureRemotes()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local checkoutFolder = remotes:FindFirstChild("Checkout")
	if not checkoutFolder then
		checkoutFolder = Instance.new("Folder")
		checkoutFolder.Name = "Checkout"
		checkoutFolder.Parent = remotes
	end

	local clickRemote = checkoutFolder:FindFirstChild("ClickCheckoutBillboard")
	if not clickRemote or not clickRemote:IsA("RemoteEvent") then
		if clickRemote then
			clickRemote:Destroy()
		end

		clickRemote = Instance.new("RemoteEvent")
		clickRemote.Name = "ClickCheckoutBillboard"
		clickRemote.Parent = checkoutFolder
	end

	local visualsRemote = checkoutFolder:FindFirstChild("CheckoutVisuals")
	if not visualsRemote or not visualsRemote:IsA("RemoteEvent") then
		if visualsRemote then
			visualsRemote:Destroy()
		end

		visualsRemote = Instance.new("RemoteEvent")
		visualsRemote.Name = "CheckoutVisuals"
		visualsRemote.Parent = checkoutFolder
	end

	local claimRemote = checkoutFolder:FindFirstChild("ClaimCardFunds")
	if not claimRemote or not claimRemote:IsA("RemoteFunction") then
		if claimRemote then
			claimRemote:Destroy()
		end

		claimRemote = Instance.new("RemoteFunction")
		claimRemote.Name = "ClaimCardFunds"
		claimRemote.Parent = checkoutFolder
	end

	clickBillboardRemote = clickRemote
	checkoutVisualsRemote = visualsRemote
	claimCardFundsRemote = claimRemote
end

function CheckoutService:Configure(registry)
	self._registry = registry
	self._businessService = registry.BusinessService
	self._customerService = registry.CustomerService
end

function CheckoutService:OnInit()
	ensureRemotes()
end

function CheckoutService:OnStart()
	ensureRemotes()

	if clickBillboardRemote then
		clickBillboardRemote.OnServerEvent:Connect(handleBillboardClick)
	end

	if claimCardFundsRemote then
		claimCardFundsRemote.OnServerInvoke = function(player: Player)
			return self._businessService.ClaimCardPayout(player)
		end
	end

	task.spawn(function()
		while true do
			task.wait(IN_GAME_DAY_SECONDS)

			for _, business in self._businessService.GetActiveBusinesses() do
				self._businessService.AdvanceCardPayoutDay(business)
			end
		end
	end)
end

function CheckoutService.OpenCheckoutInteraction(businessId: string, customerId: string, customerModel: Model): boolean
	if not isFrontCheckoutCustomer(businessId, customerId) then
		return false
	end

	if CheckoutService._customerService.GetCustomer(businessId, customerId) == nil then
		return false
	end

	local key = getSessionKey(businessId, customerId)
	local existing = activeByCustomerId[key]

	if existing then
		existing.customerModel = customerModel
		return true
	end

	local adornee = getModelAdornee(customerModel)
	if not adornee then
		return false
	end

	local root = customerModel:FindFirstChild("HumanoidRootPart")

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CheckoutServePrompt"
	prompt.ObjectText = "Interact"
	prompt.HoldDuration = 0.15
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = root or adornee

	local session: CheckoutSession = {
		businessId = businessId,
		customerId = customerId,
		customerModel = customerModel,
		step = "WaitingForCashier",
		assignedPlayerUserId = nil,
		prompt = prompt,
		promptConnection = nil,
		currentQuestionText = nil,
		completed = false,
	}

	session.promptConnection = prompt.Triggered:Connect(function(player: Player)
		startPlayerCheckout(session, player)
	end)

	activeByCustomerId[key] = session

	return true
end

function CheckoutService.CancelCheckoutInteraction(businessId: string, customerId: string)
	local key = getSessionKey(businessId, customerId)
	local session = activeByCustomerId[key]

	if session then
		cleanupSession(session)
	end
end

function CheckoutService.IsCheckoutComplete(businessId: string, customerId: string): boolean
	local key = getSessionKey(businessId, customerId)
	local session = activeByCustomerId[key]

	if session then
		return session.completed
	end

	local completedUntil = completedUntilByCustomerId[key]

	if completedUntil and completedUntil >= os.clock() then
		return true
	end

	completedUntilByCustomerId[key] = nil

	return false
end

function CheckoutService.CompleteCheckoutByStaff(businessId: string, customerId: string, staffId: string?): boolean
	if not isFrontCheckoutCustomer(businessId, customerId) then
		return false
	end

	local key = getSessionKey(businessId, customerId)
	local session = activeByCustomerId[key]

	if session and session.assignedPlayerUserId ~= nil then
		return false
	end

	local customer = CheckoutService._customerService.GetCustomer(businessId, customerId)
	if customer == nil then
		return false
	end

	local paymentMethod = pickPaymentMethod(customerId)

	if session then
		if paymentMethod == "Cash" then
			showCustomerSpeech(session, "Cash, please.", 1.5)
		else
			showCustomerSpeech(session, "I'll use card.", 1.5)
		end

		return completePurchase(session, paymentMethod)
	end

	local purchased =
		CheckoutService._customerService.TryCompletePhysicalPurchase(businessId, customerId, paymentMethod)

	if purchased then
		completedUntilByCustomerId[key] = os.clock() + COMPLETED_MEMORY_SECONDS
	end

	return purchased
end

Players.PlayerRemoving:Connect(function(player: Player)
	for _, session in activeByCustomerId do
		if session.assignedPlayerUserId == player.UserId then
			hideOption(player, session.customerId)
			hideCustomerThinking(session)

			session.assignedPlayerUserId = nil
			session.step = "WaitingForCashier"

			if session.prompt then
				session.prompt.Enabled = true
			end
		end
	end
end)

return CheckoutService
