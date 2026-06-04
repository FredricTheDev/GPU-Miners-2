local client = require("./CharmSync/client")
local config = require("./CharmSync/config")
local patch = require("./CharmSync/patch")
local server = require("./CharmSync/server")
local types = require("./CharmSync/types")
local utils = require("./CharmSync/utils")

export type None = types.None
export type SyncPayload = types.SyncPayload

return {
	config = config,
	client = client,
	server = server,
	patch = patch,
	isNone = patch.isNone,
	flatten = utils.flatten,
	signalToAtom = utils.signalToAtom,
}