--!strict

export type StaffMemberRole = "Cashier" | "Stocker" | "Guard" | "Technician"

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
    preferredGpuId: string?
}

export type CustomerRuntimeState = {
    id: string,
    state: "Entering" | "Browsing" | "Queueing" | "Buying" | "Stealing" | "Leaving",
    profile: CustomerProfile,
    targetShelfId: string?,
    desiredGpuId: string?,
    avatarUserId: number?,
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
    customers: { [string]: CustomerRuntimeState }
}

return {}