local GameClock = {}

local MINUTES_PER_DAY = 24 * 60

local WEEKDAY_NAMES = {
	"Monday",
	"Tuesday",
	"Wednesday",
	"Thursday",
	"Friday",
	"Saturday",
	"Sunday",
}

export type TimeParts = {
	Hour24: number,
	Hour12: number,
	Minute: number,
	Suffix: "AM" | "PM",
}

local function normalizeMinute(currentMinute: number): number
	return math.floor(currentMinute) % MINUTES_PER_DAY
end

function GameClock.GetTimeParts(currentMinute: number): TimeParts
	local normalizedMinute = normalizeMinute(currentMinute)

	local hour24 = math.floor(normalizedMinute / 60)
	local minute = normalizedMinute % 60

	local suffix = if hour24 >= 12 then "PM" else "AM"

	local hour12 = hour24 % 12
	if hour12 == 0 then
		hour12 = 12
	end

	return {
		Hour24 = hour24,
		Hour12 = hour12,
		Minute = minute,
		Suffix = suffix,
	}
end

function GameClock.FormatTime12(currentMinute: number): string
	local timeParts = GameClock.GetTimeParts(currentMinute)

	return string.format(
		"%d:%02d %s",
		timeParts.Hour12,
		timeParts.Minute,
		timeParts.Suffix
	)
end

function GameClock.FormatTime24(currentMinute: number): string
	local timeParts = GameClock.GetTimeParts(currentMinute)

	return string.format(
		"%02d:%02d",
		timeParts.Hour24,
		timeParts.Minute
	)
end

function GameClock.GetWeekdayIndex(currentDay: number): number
	local day = math.max(1, math.floor(currentDay))

	return ((day - 1) % 7) + 1
end

function GameClock.GetWeekdayName(currentDay: number): string
	local weekdayIndex = GameClock.GetWeekdayIndex(currentDay)

	return WEEKDAY_NAMES[weekdayIndex]
end

function GameClock.FormatDayAndTime(currentDay: number, currentMinute: number): string
	return `{GameClock.GetWeekdayName(currentDay)} {GameClock.FormatTime12(currentMinute)}`
end

return GameClock