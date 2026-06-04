local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local React = require(ReplicatedStorage.Packages.React)
local Fonts = require(StarterPlayer.StarterPlayerScripts.Client.Utils.Fonts)
local FormatInteger = require(StarterPlayer.StarterPlayerScripts.Client.Utils.FormatInteger)
local GameClock = require(ReplicatedStorage.Shared.Util.GameClock)
local AppStore = require("../../Stores/AppStore")
local Px = require("../../Utils/Px")
local useAtom = require("../../Utils/UseAtom")

local e = React.createElement

type DisplayProps = {
	BackgroundColor: Color3,
	Text: string,
}

local function Display(props: DisplayProps)
	local px = Px.usePx()

	return e("Frame", {
		BackgroundColor3 = props.BackgroundColor,
		Size = px.offset(60, 14),
	}, {
		e("UICorner", { CornerRadius = UDim.new(0.4, 0) }),

		e("UIStroke", {
			Color = Color3.fromRGB(0, 0, 0),
			StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			Thickness = 0.08,
		}),

		e("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(131, 131, 131)),
			}),
			Rotation = 90,
		}),

		e("TextLabel", {
			BackgroundTransparency = 1,
			Text = props.Text,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			Font = Enum.Font.Unknown,
			FontFace = Fonts.Montserrat.Bold,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromScale(1, 0.8),
		}, {
			e("UIStroke", {
				Color = Color3.fromRGB(0, 0, 0),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.1,
			}),
		}),
	})
end

local function Cash()
	local px = Px.usePx()

	local cash = useAtom(AppStore.getCash)
	local clock = useAtom(AppStore.getClock)

	return e("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.99),
		Size = px.offset(400, 0),
	}, {
		e("UIListLayout", {
			FillDirection = "Horizontal",
			HorizontalAlignment = "Center",
			VerticalAlignment = "Bottom",
			SortOrder = "LayoutOrder",
			Padding = UDim.new(0.02, 0),
		}),

		e(Display, {
			BackgroundColor = Color3.fromRGB(110, 130, 145),
			Text = GameClock.FormatTime12(clock.CurrentMinute),
		}),

		e("Frame", {
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			Size = px.offset(110, 22),
		}, {

			e("UICorner", { CornerRadius = UDim.new(1, 0) }),

			e("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(124, 138, 125)),
				}),
				Rotation = 90,
			}),

			e("UIStroke", {
				Color = Color3.fromRGB(0, 0, 0),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.08,
			}),

			e("TextLabel", {
				BackgroundTransparency = 1,
				Text = "$",
				TextColor3 = Color3.fromRGB(104, 230, 46),
				TextScaled = true,
				Rotation = -10,
				Font = Enum.Font.Unknown,
				FontFace = Fonts.Montserrat.ExtraBold,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = px.udim2(0, 2, 0.5, 0),
				Size = px.offset(22, 22),
			}, {
				e("UIStroke", {
					Color = Color3.fromRGB(25, 57, 27),
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.07,
				}),
			}),

			e("TextLabel", {
				BackgroundTransparency = 1,
				Text = FormatInteger(cash),
				TextColor3 = Color3.fromRGB(0, 0, 0),
				TextScaled = true,
				TextXAlignment = "Left",
				Font = Enum.Font.Unknown,
				FontFace = Fonts.Montserrat.Bold,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = px.udim2(0, 25, 0.5, 0),
				Size = px.offset(68, 14),
			}),
		}),

		e(Display, {
			BackgroundColor = Color3.fromRGB(145, 145, 145),
			Text = GameClock.GetWeekdayName(clock.CurrentDay),
		}),
	})
end

return Cash
