--!strict
--# selene: allow(global_usage)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ModuleRuntime = require(ReplicatedStorage.Shared.Runtime.ModuleRuntime)

local ClientFolder = script.Parent
local ControllersFolder = ClientFolder:WaitForChild("Controllers") :: Folder

local result = ModuleRuntime.BootstrapClient(ControllersFolder, function(context)
	_G.ClientRuntime = context
end)
if not result.Success or result.Context == nil then
	error(ModuleRuntime.formatDiagnostics(result.Diagnostics))
end
