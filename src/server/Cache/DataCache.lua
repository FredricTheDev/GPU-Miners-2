--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Promise = require(ReplicatedStorage.Packages.Promise)
local PromiseTypes = require(ReplicatedStorage.Shared.PackageTypeHelpers.PromiseTypes)
local PlayerUtil = require(ReplicatedStorage.Shared.Util.PlayerUtil)
local DataTypes = require(ServerScriptService.Server.Types.DataTypes)

type PendingPromiseResolver = (playerData: DataTypes.PlayerData) -> ()
type GlobalCallback = (player: Player, playerData: DataTypes.PlayerData) -> ()

type DataCacheType = {
    _pendingDataPromises: {
		[number]: { PendingPromiseResolver }
	},

	_serverPlayerData: {
		[number]: DataTypes.PlayerData
	},

	_globalCallbacks: {
        [number]: GlobalCallback
	},

    SetPlayerData: (
		self: DataCacheType,
		id: number,
		profileData: DataTypes.ProfileData,
		replicaData: DataTypes.ReplicaData
	) -> (),

    GetPlayerData: (
        self: DataCacheType,
        id: number,
        yield: boolean?
    ) -> PromiseTypes.Promise<DataTypes.PlayerData?>,

    GetCachedPlayerData: (
        self: DataCacheType,
        id: number
    ) -> DataTypes.PlayerData?,

    OnDataLoaded: (
        self: DataCacheType,
        id: number,
        callback: (DataTypes.PlayerData) -> ()
    ) -> ()
}

local DataCache = {
    _pendingDataPromises = {},
    _serverPlayerData = {},
    _globalCallbacks = {},
} :: DataCacheType

local function ResolvePendingPromises(id: number, playerData: DataTypes.PlayerData): ()
    if DataCache._pendingDataPromises[id] then
		for _, resolver in ipairs(DataCache._pendingDataPromises[id]) do
			resolver(playerData)
		end
		DataCache._pendingDataPromises[id] = nil
	end
end

function DataCache:SetPlayerData(
    id: number, 
    profileData: DataTypes.ProfileData,
    replicaData: DataTypes.ReplicaData
): ()
    local PlayerData = { ProfileData = profileData, ReplicaData = replicaData }
    self._serverPlayerData[id] = PlayerData
    ResolvePendingPromises(id, PlayerData)

    local Player = PlayerUtil.GetPlayerByUserId(id)
    if not Player then return end

    for _, callback in ipairs(self._globalCallbacks) do
        task.spawn(callback, Player, PlayerData)
    end
end

function DataCache:GetPlayerData(id: number, yield: boolean?): PromiseTypes.Promise<DataTypes.PlayerData?>
    local PlayerData = self._serverPlayerData[id]
    
    if PlayerData ~= nil or not yield then
		return Promise.resolve(PlayerData)
	end

    return Promise.new(function(resolve)
        if not self._pendingDataPromises[id] then
            self._pendingDataPromises[id] = {}
        end
        table.insert(self._pendingDataPromises[id], resolve)
    end)
end

function DataCache:GetCachedPlayerData(id: number): DataTypes.PlayerData?
    return self._serverPlayerData[id]
end

function DataCache:OnDataLoaded(id: number, callback: (DataTypes.PlayerData) -> ()): ()
    local PlayerData = self._serverPlayerData[id]

    if PlayerData then
        task.defer(callback, PlayerData)
        return
    end

    self:GetPlayerData(id, true):andThen(callback)
end

return DataCache
