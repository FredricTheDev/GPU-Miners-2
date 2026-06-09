export type CustomerReviewSentiment = "Positive" | "Neutral" | "Angry"

export type CustomerReviewReason =
	"GoodPrices"
	| "FoundWantedGpu"
	| "HighPrices"
	| "OutOfStock"
	| "LongQueue"
	| "BadSelection"
	| "StoleExpensiveGpu"
	| "General"

export type CustomerReview = {
	id: string,
	avatarUserId: number,
	customerId: string,
	createdAt: number,
	sentiment: CustomerReviewSentiment,
	stars: number,
	comment: string,
	reason: CustomerReviewReason,
	satisfaction: number,
	shoppingGoal: string,
	purchasedGpuIds: { string },
	stolenGpuIds: { string },
	wantedGpuIds: { string },
	spentAmount: number,
	stolenValue: number,
}

export type CustomerMemory = {
	avatarUserId: number,
	visits: number,
	lastVisitedAt: number,
	lastSentiment: CustomerReviewSentiment,
	lastStars: number,
	lastReason: CustomerReviewReason,
	lastComment: string,
	totalStars: number,
	positiveVisits: number,
	neutralVisits: number,
	angryVisits: number,
	purchaseCount: number,
	theftCount: number,
	totalSpent: number,
	totalStolenValue: number,
}

export type RankField = "CustomerService" | "Security" | "Stock" | "Mining"

export type RankFieldProgress = {
	Field: RankField,
	Value: number,
	RankIndex: number,
	RankName: string,
	Polarity: string,
}

export type Account = {
	Cash: number,
	PendingCardPayout: number,
	ClaimableCardPayout: number,
	LastBankDay: number,
	LastJoinTime: number,

	CurrentDay: number,
	CurrentMinute: number,
	LastClockUpdateUnix: number,

	CustomerReviews: { CustomerReview },
	CustomerMemoriesByAvatarUserId: { [string]: CustomerMemory },

	RankFields: { [RankField]: RankFieldProgress },
	OverallRank: RankFieldProgress,
	OverallKnownRank: string,
}

local defaultRankFields: { [RankField]: RankFieldProgress } = {
	CustomerService = {
		Field = "CustomerService",
		Value = 0,
		RankIndex = 1,
		RankName = "Rude Reseller",
		Polarity = "Positive",
	},
	Security = {
		Field = "Security",
		Value = 0,
		RankIndex = 1,
		RankName = "Easy Target",
		Polarity = "Positive",
	},
	Stock = {
		Field = "Stock",
		Value = 0,
		RankIndex = 1,
		RankName = "Empty Shelfer",
		Polarity = "Positive",
	},
	Mining = {
		Field = "Mining",
		Value = 0,
		RankIndex = 1,
		RankName = "Single Rig Miner",
		Polarity = "Positive",
	},
}

local accountTemplate: Account = {
	Cash = 1000,
	PendingCardPayout = 0,
	ClaimableCardPayout = 0,
	LastBankDay = 0,
	LastJoinTime = 0,

	CurrentDay = 1,
	CurrentMinute = 8 * 60,
	LastClockUpdateUnix = 0,

	CustomerReviews = {},
	CustomerMemoriesByAvatarUserId = {},

	RankFields = defaultRankFields,
	OverallRank = defaultRankFields.CustomerService,
	OverallKnownRank = defaultRankFields.CustomerService.RankName,
}

return {
	accountTemplate = accountTemplate,
}
