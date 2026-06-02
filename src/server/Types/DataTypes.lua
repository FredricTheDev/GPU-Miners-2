export type PlayerData = {
	ProfileData: ProfileData,
	ReplicaData: ReplicaData,
}

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

export type ProfileData = {
	Cash: number,
	LastJoinTime: number,
	CustomerReviews: { CustomerReview },
	CustomerMemoriesByAvatarUserId: { [string]: CustomerMemory },
}

export type ReplicaData = {}

return {}
