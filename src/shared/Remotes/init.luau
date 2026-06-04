local ReplicatedStorage = game:GetService("ReplicatedStorage")

local gt = require(ReplicatedStorage.Packages.GreenTea)
local lib = require("./Remotes/Lib")

return {
    assert = lib.assert,
    patch = lib.event(gt.anyTable())
}