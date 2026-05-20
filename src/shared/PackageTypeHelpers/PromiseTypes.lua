local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Promise = require(ReplicatedStorage.Packages.Promise)

export type Promise<T> = typeof(Promise.resolve(nil :: any))

return {}