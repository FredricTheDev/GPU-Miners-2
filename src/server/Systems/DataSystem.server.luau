--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local DataCache = require(ServerScriptService.Server.Cache.DataCache)
local DataTypes = require(ServerScriptService.Server.Types.DataTypes)
local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local ReplicaServer = require(ReplicatedStorage.Packages.Replica)
local ReplicaTypes = require(ReplicatedStorage.Shared.PackageTypeHelpers.ReplicaTypes)

local PROFILE_TEMPATE: DataTypes.ProfileData = {
	Cash = 0,
	LastJoinTime = 0,
}

local PlayerStore = ProfileStore.New("PlayerStore", PROFILE_TEMPATE)

type Profile = typeof(PlayerStore:StartSessionAsync("" :: string, {} :: any))

local Profiles: { [Player]: Profile } = {}
local Replicas: { [Player]: ReplicaTypes.Replica } = {}

local PlayerToken = ReplicaServer.Token("PlayerData")

local function OnPlayerAdded(Player: Player): ()
	local Profile = PlayerStore:StartSessionAsync(`{Player.UserId}`, {
		Cancel = function()
			return Player.Parent ~= Players
		end,
	})

	if Profile ~= nil then
		Profile:AddUserId(Player.UserId)
		Profile:Reconcile()

		Profile.OnSessionEnd:Connect(function()
			Profiles[Player] = nil
			Player:Kick("Profile session ended - Please rejoin")
		end)

		if Player.Parent == Players then
			Profiles[Player] = Profile
			print(`Profile loaded for {Player.DisplayName}!`)

			local PlayerReplica = ReplicaServer.New({
				Token = PlayerToken,
				Data = Profile.Data,
				Tags = { OwnerId = Player.UserId, OwnerName = Player.Name },
			})
			PlayerReplica:Replicate()
			Replicas[Player] = PlayerReplica

			DataCache:SetPlayerData(Player.UserId, Profile.Data, PlayerReplica)
		else
			Profile:EndSession()
		end
	else
		Player:Kick("Profile load failed - Please rejoin")
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(OnPlayerAdded, player)
end

Players.PlayerAdded:Connect(OnPlayerAdded)

Players.PlayerRemoving:Connect(function(player: Player)
	local Profile = Profiles[player]
	if Profile ~= nil then
		Profile.Data.LastJoinTime = os.time()
		Profile:EndSession()
	end
	local Replica = Replicas[player]
	if not Replica then
		return
	end
	Replica:Destroy()
	Replicas[player] = nil
end)
