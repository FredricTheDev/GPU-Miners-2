local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Root = require("../UI/Components/Root")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local container = Instance.new("ScreenGui")
container.Name = "React"
container.IgnoreGuiInset = true
container.ResetOnSpawn = false
container.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
container.ClipToDeviceSafeArea = false
container.Parent = playerGui
local root = ReactRoblox.createRoot(container)
local app = React.createElement(Root)
root:render(app)
