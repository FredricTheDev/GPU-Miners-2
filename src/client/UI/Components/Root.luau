local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cash = require(script.Parent.Cash)
local React = require(ReplicatedStorage.Packages.React)
local Px = require("../../Utils/Px")

local e = React.createElement

return function()
	return e(Px.Provider, nil, {
		e(React.Fragment, nil, {
			e(Cash),
		}),
	})
end
