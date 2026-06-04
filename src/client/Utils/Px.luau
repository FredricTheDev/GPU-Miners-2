local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)

local e = React.createElement

local BASE_RESOLUTION = Vector2.new(1280, 720)
local DOMINANT_AXIS = 0.5
local SCALE_POINTS = { 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3 }

export type PxHelpers = {
	scaleFactor: number,

	setScale: (scale: number) -> (),

	px: (value: number) -> number,
	raw: (scaled: number) -> number,
	scale: (value: number) -> number,

	offset: (x: number, y: number) -> UDim2,
	udim2: (xScale: number, xOffset: number, yScale: number, yOffset: number) -> UDim2,
	udim: (scale: number, offset: number) -> UDim,
}

local PxContext = React.createContext(nil :: PxHelpers?)

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function modifyScale(scale: number): number
	scale = scale ^ 0.5

	for _, point in SCALE_POINTS do
		if scale < point then
			return point
		end
	end

	return SCALE_POINTS[#SCALE_POINTS]
end

local function calculateScale(viewportSize: Vector2): number
	if viewportSize.X <= 0 or viewportSize.Y <= 0 then
		return 1
	end

	local constrainedAspectRatio = math.min(viewportSize.X / viewportSize.Y, 16 / 9)
	local constrainedViewportSize = Vector2.new(
		viewportSize.Y * constrainedAspectRatio,
		viewportSize.Y
	)

	local scaleX = math.log(constrainedViewportSize.X / BASE_RESOLUTION.X, 2)
	local scaleY = math.log(constrainedViewportSize.Y / BASE_RESOLUTION.Y, 2)

	return modifyScale(2 ^ lerp(scaleX, scaleY, DOMINANT_AXIS))
end

local function Provider(props)
	local scaleFactor, setScaleFactor = React.useState(1)

	React.useEffect(function()
		local viewportConnection: RBXScriptConnection? = nil
		local cameraConnection: RBXScriptConnection? = nil

		local function disconnectViewport()
			if viewportConnection then
				viewportConnection:Disconnect()
				viewportConnection = nil
			end
		end

		local function bindCamera(camera: Camera?)
			disconnectViewport()

			if not camera then
				return
			end

			local function updateScale()
				setScaleFactor(calculateScale(camera.ViewportSize))
			end

			updateScale()

			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
		end

		bindCamera(Workspace.CurrentCamera)

		cameraConnection = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			bindCamera(Workspace.CurrentCamera)
		end)

		return function()
			disconnectViewport()

			if cameraConnection then
				cameraConnection:Disconnect()
				cameraConnection = nil
			end
		end
	end, {})

	local value = React.useMemo(function()
		local function px(value: number): number
			return math.round(value * scaleFactor)
		end

		local function raw(scaled: number): number
			return math.round(scaled / scaleFactor)
		end

		local function scale(value: number): number
			return value * scaleFactor
		end

		local function offset(x: number, y: number): UDim2
			return UDim2.fromOffset(px(x), px(y))
		end

		local function udim2(xScale: number, xOffset: number, yScale: number, yOffset: number): UDim2
			return UDim2.new(xScale, px(xOffset), yScale, px(yOffset))
		end

		local function udim(scaleValue: number, offsetValue: number): UDim
			return UDim.new(scaleValue, px(offsetValue))
		end

		return {
			scaleFactor = scaleFactor,

			setScale = setScaleFactor,

			px = px,
			raw = raw,
			scale = scale,

			offset = offset,
			udim2 = udim2,
			udim = udim,
		}
	end, { scaleFactor })

	local children = props[React.Children] or props.children

	return e(PxContext.Provider, {
		value = value,
	}, children)
end

local function usePx(): PxHelpers
	local value = React.useContext(PxContext)

	if value == nil then
		error("usePx must be used inside Px.Provider")
	end

	return value
end

return {
	Provider = Provider,
	usePx = usePx,
}