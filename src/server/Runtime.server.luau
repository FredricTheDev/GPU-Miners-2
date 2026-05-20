--!strict
--# selene: allow(global_usage)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ModuleRuntime = require(ReplicatedStorage.Shared.Runtime.ModuleRuntime)

local ServerFolder = script.Parent
local ServicesFolder = ServerFolder:WaitForChild("Services") :: Folder

local result = ModuleRuntime.BootstrapServer(ServicesFolder, function(context)
	_G.ServerRuntime = context
end)
if not result.Success or result.Context == nil then
	error(ModuleRuntime.formatDiagnostics(result.Diagnostics))
end
