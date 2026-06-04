--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)
local Objects = require(ReplicatedStorage.Shared.Util.Objects)
local AccountDataStore = require(ServerScriptService.Server.Accounts.Store)
local AccountStore = require(ServerScriptService.Server.Stores.AccountStore)

local DayCycleService = {}

DayCycleService.Name = "DayCycleService"
DayCycleService.Priority = 0
DayCycleService.Dependencies = {}
DayCycleService.Disabled = false

local GAME_MINUTES_PER_DAY = 24 * 60

local REAL_SECONDS_PER_GAME_DAY = 20 * 60 -- 20 real minutes is 1 in game day

local REAL_SECONDS_PER_GAME_MINUTE = REAL_SECONDS_PER_GAME_DAY / GAME_MINUTES_PER_DAY

type NewDayCallback = (
	player: Player,
	account: AccountTypes.Account,
	newDay: number,
	previousDay: number
) -> ()

local newDayCallbacks: { NewDayCallback } = {}

local minuteRemainders: { [number]: number } = {}

local heartbeatConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

local function getClockFields(account: AccountTypes.Account): (number, number, number)
	local accountData = account :: any
	local currentDay = if typeof(accountData.CurrentDay) == "number" and accountData.CurrentDay >= 1
		then accountData.CurrentDay
		else 1
	local currentMinute = if typeof(accountData.CurrentMinute) == "number" then accountData.CurrentMinute else 8 * 60
	local lastClockUpdateUnix = if typeof(accountData.LastClockUpdateUnix) == "number"
		then accountData.LastClockUpdateUnix
		else os.time()

	currentMinute = math.clamp(math.floor(currentMinute), 0, GAME_MINUTES_PER_DAY - 1)

	return currentDay, currentMinute, lastClockUpdateUnix
end

local function fireNewDayCallbacks(
    player: Player,
    account: AccountTypes.Account,
    newDay: number,
    previousDay: number
): ()
    for _, callback in ipairs(newDayCallbacks) do
        task.spawn(function()
            local success, result = pcall(callback, player, account, newDay, previousDay)

            if not success then
                warn(`{script.Name} New day callback failed: {result}`)
            end
        end)
    end
end

local function stepPlayerClock(player: Player, deltaTime: number): ()
	local account = AccountStore.getAccount(player.Name)

	if not account then
		return
	end

	local userId = player.UserId

	local remainder = (minuteRemainders[userId] or 0) + deltaTime
	local gameMinutesToAdd = math.floor(remainder / REAL_SECONDS_PER_GAME_MINUTE)

	if gameMinutesToAdd <= 0 then
		minuteRemainders[userId] = remainder
		return
	end

	minuteRemainders[userId] = remainder - gameMinutesToAdd * REAL_SECONDS_PER_GAME_MINUTE

	local previousDay = 1
	local daysPassed = 0
	local updatedAccount = account

	AccountDataStore:updateImmutable(player, function(currentAccount: AccountTypes.Account)
		local currentDay, currentMinute = getClockFields(currentAccount)

		previousDay = currentDay

		local totalMinutes = currentMinute + gameMinutesToAdd
		daysPassed = math.floor(totalMinutes / GAME_MINUTES_PER_DAY)

		local newMinute = totalMinutes % GAME_MINUTES_PER_DAY
		local newDay = currentDay + daysPassed

		updatedAccount = Objects.join(currentAccount, {
			CurrentDay = newDay,
			CurrentMinute = newMinute,
			LastClockUpdateUnix = os.time(),
		})

		return updatedAccount
	end)

	if daysPassed > 0 then
		for day = previousDay + 1, previousDay + daysPassed do
			fireNewDayCallbacks(player, updatedAccount, day, day - 1)
		end
	end
end

function DayCycleService.OnNewDay(callback: NewDayCallback): () -> ()
    table.insert(newDayCallbacks, callback)
    
    local disconnected = false

    return function()
        if disconnected then
            return
        end

        disconnected = true

        local index = table.find(newDayCallbacks, callback)

        if index then
            table.remove(newDayCallbacks, index)
        end
    end
end

function DayCycleService.GetClock(player: Player): {
	Day: number,
	Hour: number,
	Minute: number,
	CurrentMinute: number,
}?
    local account = AccountStore.getAccount(player.Name)

    if not account then
        return nil
    end

	local currentDay, currentMinute = getClockFields(account)

	return {
		Day = currentDay,
		Hour = math.floor(currentMinute / 60),
		Minute = currentMinute % 60,
		CurrentMinute = currentMinute,
	}
end

function DayCycleService.FormatClock(currentMinute: number): string
	local hour24 = math.floor(currentMinute / 60)
	local minute = currentMinute % 60

	local suffix = if hour24 >= 12 then "PM" else "AM"
	local hour12 = hour24 % 12

	if hour12 == 0 then
		hour12 = 12
	end

	return string.format("%d:%02d %s", hour12, minute, suffix)
end

function DayCycleService:OnInit(): ()
end

function DayCycleService:OnStart(): ()
	if heartbeatConnection then
		return
	end

	playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		minuteRemainders[player.UserId] = nil
	end)

	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		for _, player in ipairs(Players:GetPlayers()) do
			stepPlayerClock(player, deltaTime)
		end
	end)
end


return DayCycleService
