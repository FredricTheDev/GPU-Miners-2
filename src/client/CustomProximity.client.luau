local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Billboards = ReplicatedStorage:WaitForChild("Billboards")
local CustomProximity = Billboards:WaitForChild("CustomProximity")

local SHOW_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOLD_SCALE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_SCALE_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OVERLAY_RESET_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function getOrCreateScale(guiObject: GuiObject)
	local scale = guiObject:FindFirstChildOfClass("UIScale")

	if scale then
		return scale
	end

	scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = guiObject

	return scale
end

local function playTween(instance: Instance, tweenInfo: TweenInfo, properties: { [string]: any })
	local tween = TweenService:Create(instance, tweenInfo, properties)
	tween:Play()

	return tween
end

local function setupOverlay(content: GuiObject)
	local overlay = content:WaitForChild("Overlay") :: CanvasGroup
	local fillFrame = overlay:WaitForChild("Frame") :: Frame

	overlay.ClipsDescendants = true
	overlay.GroupTransparency = 1

	fillFrame.AnchorPoint = Vector2.new(0, 1)
	fillFrame.Position = UDim2.fromScale(0, 1)
	fillFrame.Size = UDim2.fromScale(1, 0)

	return overlay, fillFrame
end

ProximityPromptService.PromptShown:Connect(function(promptInstance: ProximityPrompt)
	if promptInstance.Style == Enum.ProximityPromptStyle.Default then
		return
	end

	local proximity = CustomProximity:Clone()
	local content = proximity:WaitForChild("Content") :: GuiObject

	content.ObjectText.Text = `[ {promptInstance.ObjectText} ]`
	content.ActionText.Text = promptInstance.KeyboardKeyCode.Name

	local overlay, fillFrame = setupOverlay(content)
	local contentScale = getOrCreateScale(content)

	local activeTweens: { Tween } = {}
	local connections: { RBXScriptConnection } = {}
	local isAlive = true

	local function cancelTweens()
		for _, tween in activeTweens do
			tween:Cancel()
		end

		table.clear(activeTweens)
	end

	local function tween(instance: Instance, tweenInfo: TweenInfo, properties: { [string]: any })
		local createdTween = playTween(instance, tweenInfo, properties)
		table.insert(activeTweens, createdTween)

		return createdTween
	end

	local function resetHoldVisuals()
		cancelTweens()

		tween(fillFrame, OVERLAY_RESET_TWEEN, {
			Size = UDim2.fromScale(1, 0),
		})

		tween(overlay, OVERLAY_RESET_TWEEN, {
			GroupTransparency = 1,
		})

		tween(contentScale, RELEASE_SCALE_TWEEN, {
			Scale = 1,
		})
	end

	local function startHoldVisuals()
		cancelTweens()

		fillFrame.Size = UDim2.fromScale(1, 0)

		tween(overlay, HOLD_SCALE_TWEEN, {
			GroupTransparency = 0.15,
		})

		tween(contentScale, HOLD_SCALE_TWEEN, {
			Scale = 1.06,
		})

		if promptInstance.HoldDuration <= 0 then
			fillFrame.Size = UDim2.fromScale(1, 1)
			return
		end

		tween(fillFrame, TweenInfo.new(
			promptInstance.HoldDuration,
			Enum.EasingStyle.Linear,
			Enum.EasingDirection.Out
		), {
			Size = UDim2.fromScale(1, 1),
		})
	end

	local function playTriggeredVisuals()
		cancelTweens()

		fillFrame.Size = UDim2.fromScale(1, 1)
		overlay.GroupTransparency = 0.05

		tween(contentScale, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1.12,
		})

		task.delay(0.08, function()
			if not isAlive then
				return
			end

			tween(contentScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			})

			tween(overlay, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				GroupTransparency = 1,
			})

			tween(fillFrame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromScale(1, 0),
			})
		end)
	end

	contentScale.Scale = 0.88
	overlay.GroupTransparency = 1
	fillFrame.Size = UDim2.fromScale(1, 0)

	proximity.Parent = promptInstance.Parent

	tween(contentScale, SHOW_TWEEN, {
		Scale = 1,
	})

	table.insert(connections, promptInstance.PromptButtonHoldBegan:Connect(function()
		startHoldVisuals()
	end))

	table.insert(connections, promptInstance.PromptButtonHoldEnded:Connect(function()
		resetHoldVisuals()
	end))

	table.insert(connections, promptInstance.Triggered:Connect(function()
		playTriggeredVisuals()
	end))

	promptInstance.PromptHidden:Once(function()
		isAlive = false

		for _, connection in connections do
			connection:Disconnect()
		end

		cancelTweens()

		local hideTween = TweenService:Create(contentScale, HIDE_TWEEN, {
			Scale = 0.9,
		})

		hideTween:Play()

		hideTween.Completed:Once(function()
			if proximity then
				proximity:Destroy()
			end
		end)
	end)
end)