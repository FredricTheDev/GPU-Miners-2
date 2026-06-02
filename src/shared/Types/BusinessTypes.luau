--!strict

export type StaffMemberRole = "Cashier" | "Stocker" | "Guard" | "Technician"

export type ShoppingGoal = "Gaming" | "Mining" | "Budget" | "Premium"

export type CustomerReviewReason =
    "GoodPrices"
    | "FoundWantedGpu"
    | "HighPrices"
    | "OutOfStock"
    | "LongQueue"
    | "BadSelection"
    | "StoleExpensiveGpu"
    | "General"

export type StaffTaskType =
    "ServeCheckout"
    | "RestockShelf"
    | "PatrolStore"
    | "ChaseThief"
    | "RepairRig"
    | "UnloadDelivery"

export type StaffTask = {
    id: string,
    taskType: StaffTaskType,
    priority: number,
    assignedStaffId: string?,
    targetId: string?,
    createdAt: number,
    expiresAt: number?,
}

export type StaffMember = {
	id: string,
	role: StaffMemberRole,
	wagePerMinute: number,
	energy: number,
	happiness: number,
	skill: number,
	currentTaskId: string?,
    physicalModelName: string?,
}

export type ShelfState = {
    id: string;
    gpuId: string?,
    stockAmount: number,
    maxStock: number,
    priceMultiplier: number,
}

export type StoreState = {
    shelves: { [string]: ShelfState },
    checkoutQueueLength: number,
    checkoutQueueSlots: { [string]: number },
    open: boolean,
}

export type WarehouseState = {
    inventory: { [string]: number },
    capacity: number,
    usedCapacity: number,
}

export type CustomerProfile = {
    budget: number,
    patience: number,
    theftRiskTolerance: number,
    priceSensitivity: number,
    preferredGpuId: string?,
    shoppingGoal: ShoppingGoal,
    wantedGpuIds: { string },
    maxPurchases: number,
    impulseBuyChance: number,
}

export type CustomerRuntimeState = {
    id: string,
    state: "Entering" | "Browsing" | "Queueing" | "Buying" | "Stealing" | "Leaving",
    profile: CustomerProfile,
    isSpawningPhysicalModel: boolean,
    targetShelfId: string?,
    desiredGpuId: string?,
    browseShelfIds: { string },
    browseIndex: number,
    cartShelfIds: { string },
    cartGpuIds: { string },
    purchasedGpuIds: { string },
    stolenGpuIds: { string },
    remainingBudget: number,
    spentAmount: number,
    stolenValue: number,
    avatarUserId: number?,
    returningCustomer: boolean,
    memoryReason: CustomerReviewReason?,
    reviewReasonScores: { [CustomerReviewReason]: number },
    reviewSaved: boolean,
    physicalModelName: string?,
    lastObservedScore: number,
    lastDecisionAt: number,
    timeInState: number,
    satisfaction: number,
}

export type DeliveryOrder = {
    id: string,
    gpuId: string,
    quantity: number,
    unitCost: number,
    state: "Preparing" | "InTransit" | "Arrived" | "Unloading" | "Complete",
    secondsRemaining: number,
    assignedStaffId: string?,
}

export type MiningRig = {
    id: string,
    gpuIds: { string },
    hashrate: number,
    powerUsageKw: number,
    heat: number,
    condition: number,
    running: boolean,
    needsRepair: boolean,
}

export type SecurityState = {
    securityLevel: number,
    cameraCoverage: number,
    alarmLevel: number,
    activeThefts: { [string]: boolean },
    lastTheftDetectedAt: number?,
}

export type EconomyState = {
    marketDemand: number,
    cryptoPriceIndex: number,
    electricityPricePerKwh: number,
    lastWagePaidAt: number,
}

export type BusinessState = {
    id: string,
    ownerUserId: number,
    cash: number,
    reputation: number,
    store: StoreState,
    warehouse: WarehouseState,
    staff: { [string]: StaffMember },
    staffTasks: { [string]: StaffTask },
    deliveries: { [string]: DeliveryOrder },
    miningRigs: { [string]: MiningRig },
    security: SecurityState,
    economy: EconomyState,
    customers: { [string]: CustomerRuntimeState },
    customerSpawnBudget: number,
}

return {}
