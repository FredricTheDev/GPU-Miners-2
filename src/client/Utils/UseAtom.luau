local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Charm = require(ReplicatedStorage.Shared.Modules.Charm)

local function useAtom<T>(callback: Charm.Getter<T>, dependencies: { any }?): T
	local state, setState = React.useState(callback)

	React.useEffect(function()
		setState(callback())
		return Charm.subscribe(callback, setState)
	end, dependencies or {})

	return state
end

return useAtom
