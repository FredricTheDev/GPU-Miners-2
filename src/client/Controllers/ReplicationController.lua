local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local ReplicaClient = require(ReplicatedStorage.Packages.Replica)
local ReplicaTypes = require(ReplicatedStorage.Shared.PackageTypeHelpers.ReplicaTypes)
local PromiseTypes = require(ReplicatedStorage.Shared.PackageTypeHelpers.PromiseTypes)

local LocalPlayer = Players.LocalPlayer

local ReplicationController = {}

ReplicationController.Name = "ReplicationController"
ReplicationController.Priority = 0
ReplicationController.Dependencies = {}
ReplicationController.Disabled = false

type PendingResolve = (ReplicaTypes.Replica) -> ()

function ReplicationController:Configure(registry)
	self._registry = registry
end

function ReplicationController:OnInit()
	self._replicasByUserId = {} :: { [number]: ReplicaTypes.Replica }
	self._pendingByUserId = {} :: { [number]: { PendingResolve } }
end

function ReplicationController:GetPlayerDataReplica(userId: number): ReplicaTypes.Replica?
	return (self._replicasByUserId :: { [number]: ReplicaTypes.Replica })[userId]
end

function ReplicationController:AwaitPlayerDataReplica(
	userId: number,
	timeoutSeconds: number?
): PromiseTypes.Promise<ReplicaTypes.Replica>
	local existing = self:GetPlayerDataReplica(userId)
	if existing ~= nil then
		return Promise.resolve(existing)
	end

	local timeout = timeoutSeconds
	return Promise.new(function(resolve, reject)
		local pendingByUserId = self._pendingByUserId :: { [number]: { PendingResolve } }
		if pendingByUserId[userId] == nil then
			pendingByUserId[userId] = {}
		end
		table.insert(pendingByUserId[userId], resolve)

		if timeout ~= nil then
			task.delay(timeout, function()
				if self:GetPlayerDataReplica(userId) ~= nil then
					return
				end

				local list = pendingByUserId[userId]
				if list ~= nil then
					for i = #list, 1, -1 do
						if list[i] == resolve then
							table.remove(list, i)
							break
						end
					end
					if #list == 0 then
						pendingByUserId[userId] = nil
					end
				end

				reject(string.format("Timed out waiting for PlayerData replica (userId=%d)", userId))
			end)
		end
	end)
end

function ReplicationController:AwaitLocalPlayerDataReplica(
	timeoutSeconds: number?
): PromiseTypes.Promise<ReplicaTypes.Replica>
	return self:AwaitPlayerDataReplica(LocalPlayer.UserId, timeoutSeconds)
end

function ReplicationController:OnStart()
	ReplicaClient.OnNew("PlayerData", function(replica: ReplicaTypes.Replica)
		local ownerId = replica.Tags.OwnerId :: number
		local ownerName = tostring(replica.Tags.OwnerName)

		local replicasByUserId = self._replicasByUserId :: { [number]: ReplicaTypes.Replica }
		replicasByUserId[ownerId] = replica

		local pendingByUserId = self._pendingByUserId :: { [number]: { PendingResolve } }
		local waiters = pendingByUserId[ownerId]
		if waiters ~= nil then
			for _, resolve in ipairs(waiters) do
				resolve(replica)
			end
			pendingByUserId[ownerId] = nil
		end

		replica.Maid:Add(function()
			if replicasByUserId[ownerId] == replica then
				replicasByUserId[ownerId] = nil
			end
			print(string.format("[%s] PlayerData replica for %s destroyed; cleaned up", self.Name, ownerName))
		end)
	end)

	local success, result = pcall(function()
		ReplicaClient.RequestData()
	end)
	if not success then
		warn(result)
	end
end

return ReplicationController
