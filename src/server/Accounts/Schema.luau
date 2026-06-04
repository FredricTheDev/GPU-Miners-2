local ReplicatedStorage = game:GetService("ReplicatedStorage")

local gt = require(ReplicatedStorage.Packages.GreenTea)
local AccountTypes = require(ReplicatedStorage.Shared.Types.AccountTypes)

type Account = AccountTypes.Account
type CustomerReview = AccountTypes.CustomerReview
type CustomerMemory = AccountTypes.CustomerMemory

local customerReviewSchema: CustomerReview = gt.table({
	id = gt.string(),
	avatarUserId = gt.number(),
	customerId = gt.string(),
	createdAt = gt.number(),
	sentiment = gt.string(),
	stars = gt.number(),
	comment = gt.string(),
	reason = gt.string(),
	satisfaction = gt.number(),
	shoppingGoal = gt.string(),
	purchasedGpuIds = { gt.string() },
	stolenGpuIds = { gt.string() },
	wantedGpuIds = { gt.string() },
	spentAmount = gt.number(),
	stolenValue = gt.number(),
})

local customerMemorySchema: CustomerMemory = gt.table({
	avatarUserId = gt.number(),
	visits = gt.number(),
	lastVisitedAt = gt.number(),
	lastSentiment = gt.string(),
	lastStars = gt.number(),
	lastReason = gt.string(),
	lastComment = gt.string(),
	totalStars = gt.number(),
	positiveVisits = gt.number(),
	neutralVisits = gt.number(),
	angryVisits = gt.number(),
	purchaseCount = gt.number(),
	theftCount = gt.number(),
	totalSpent = gt.number(),
	totalStolenValue = gt.number(),
})

local accountSchema: Account = gt.table({
	Cash = gt.number(),
	PendingCardPayout = gt.number(),
	ClaimableCardPayout = gt.number(),
	LastBankDay = gt.number(),
	LastJoinTime = gt.number(),

	CurrentDay = gt.number(),
	CurrentMinute = gt.number(),
	LastClockUpdateUnix = gt.number(),

	CustomerReviews = { customerReviewSchema },
	CustomerMemoriesByAvatarUserId = { [gt.string()] = customerMemorySchema },
})

return gt.build(accountSchema)
