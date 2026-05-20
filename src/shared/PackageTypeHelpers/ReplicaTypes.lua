local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Replica = require(ReplicatedStorage.Packages.Replica)

export type Replica = typeof(Replica.New({
	Token = Replica.Token("" :: string),
	Data = {},
}))

return {}