--!strict

local Workspace = game:GetService("Workspace")

local CrowdService = {}

CrowdService.Name = "CrowdService"
CrowdService.Priority = 0

local SHELF_SLOT_COUNT = 7
local CHECKOUT_SLOT_COUNT = 8
local MOVEMENT_SLOT_LIFETIME = 6

local PERSONAL_SPACE = 4
local HARD_PERSONAL_SPACE = 2.25
local AVOIDANCE_RADIUS = 7
local PREDICTION_TIME = 0.45
local MAX_AVOIDANCE_OFFSET = 2.2

local REPATH_CHECK_RADIUS = 7
local REPATH_AHEAD_DISTANCE = 6

local HEAD_ON_DOT = -0.45
local AHEAD_DOT = 0.35
local COLLISION_LOOKAHEAD = 5

type Reservation = {
	customerId: string,
	expiresAt: number,
}

type MovementReservation = {
	customerId: string,
	position: Vector3,
	expiresAt: number,
}

local shelfReservations: {
	[string]: {
		[number]: Reservation,
	},
} = {}

local checkoutReservations: {
	[string]: {
		[number]: Reservation,
	},
} = {}

local movementReservations: {
	[string]: MovementReservation,
} = {}

local customerBrowseSlots: {
	[string]: {
		shelfKey: string,
		slotIndex: number,
	},
} = {}

local customerCheckoutSlots: {
	[string]: {
		businessKey: string,
		slotIndex: number,
	},
} = {}

local STATE_PRIORITY = {
	Leaving = 4,
	WalkingToExit = 4,
	WalkingToCheckout = 3,
	WalkingToShelf = 2,
	Browsing = 1,
}

function CrowdService:OnInit() end
function CrowdService:OnStart() end

local function getPriority(model: Model): number
	local state = model:GetAttribute("CustomerState")
	if typeof(state) == "string" then
		return STATE_PRIORITY[state] or 1
	end
	return 1
end

local function hashString(value: string): number
	local hash = 0
	for index = 1, #value do
		hash = (hash * 31 + string.byte(value, index)) % 100000
	end
	return hash
end

local function getShelfReservationKey(businessId: string, shelfId: string): string
	return `{businessId}:{shelfId}`
end

local function getCheckoutReservationKey(businessId: string): string
	return `{businessId}:checkout`
end

local function getRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function getFlatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function getFlatDirection(fromPosition: Vector3, toPosition: Vector3): Vector3?
	local delta = Vector3.new(toPosition.X - fromPosition.X, 0, toPosition.Z - fromPosition.Z)
	if delta.Magnitude < 0.05 then
		return nil
	end
	return delta.Unit
end

local function getCustomerId(model: Model): string?
	local customerId = model:GetAttribute("CustomerId")
	return if typeof(customerId) == "string" then customerId else nil
end

local function getBusinessId(model: Model): string?
	local businessId = model:GetAttribute("BusinessId")
	return if typeof(businessId) == "string" then businessId else nil
end

local function cleanExpired<T>(slots: { [number]: T }, isExpired: (T) -> boolean)
	for index, reservation in slots do
		if isExpired(reservation) then
			slots[index] = nil
		end
	end
end

function CrowdService.GetLocalAvoidanceMoveDirection(model: Model, targetPosition: Vector3): Vector3?
	local root = getRoot(model)
	if not root then
		return nil
	end

	local toTarget = targetPosition - root.Position
	if toTarget.Magnitude < 0.1 then
		return nil
	end

	local desiredDirection = Vector3.new(toTarget.X, 0, toTarget.Z).Unit
	local nearby = CrowdService.GetNearbyCustomers(root.Position, COLLISION_LOOKAHEAD, model)

	for _, other in ipairs(nearby) do
		local otherRoot = getRoot(other)
		if not otherRoot then
			continue
		end

		local toOther = otherRoot.Position - root.Position
		local flatToOther = Vector3.new(toOther.X, 0, toOther.Z)

		if flatToOther.Magnitude < 0.1 then
			continue
		end

		local otherDirection = Vector3.new(
			otherRoot.AssemblyLinearVelocity.X,
			0,
			otherRoot.AssemblyLinearVelocity.Z
		)

		if otherDirection.Magnitude < 0.1 then
			otherDirection = flatToOther.Unit
		else
			otherDirection = otherDirection.Unit
		end

		local otherAhead = desiredDirection:Dot(flatToOther.Unit)
		local headOn = desiredDirection:Dot(otherDirection)

		if otherAhead > AHEAD_DOT and headOn < HEAD_ON_DOT then
			local myPriority = getPriority(model)
			local otherPriority = getPriority(other)

			if myPriority < otherPriority then
				return Vector3.zero
			end

			local right = Vector3.new(-desiredDirection.Z, 0, desiredDirection.X)
			local hash = hashString(model.Name)
			local side = if hash % 2 == 0 then 1 else -1

			return (desiredDirection + right * side * 0.65).Unit
		end
	end

	return nil
end

function CrowdService.IsPathCrowdedAhead(model: Model, targetPosition: Vector3): boolean
	local root = getRoot(model)
	if not root then
		return false
	end

	local toTarget = targetPosition - root.Position
	if toTarget.Magnitude < 0.1 then
		return false
	end

	local direction = toTarget.Unit
	local aheadPosition = root.Position + direction * REPATH_AHEAD_DISTANCE

	local nearby = CrowdService.GetNearbyCustomers(aheadPosition, REPATH_CHECK_RADIUS, model)

	return #nearby >= 2
end

function CrowdService.GetSideStepTarget(model: Model, targetPosition: Vector3): Vector3
	local root = getRoot(model)
	if not root then
		return targetPosition
	end

	local toTarget = targetPosition - root.Position
	if toTarget.Magnitude < 0.1 then
		return targetPosition
	end

	local forward = toTarget.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X)

	local hash = hashString(model.Name)
	local side = if hash % 2 == 0 then 1 else -1

	return targetPosition + right * side * 2.8
end

function CrowdService.ReleaseCustomerReservations(customerId: string)
	local browse = customerBrowseSlots[customerId]
	if browse then
		local shelfSlots = shelfReservations[browse.shelfKey]
		if shelfSlots and shelfSlots[browse.slotIndex] then
			if shelfSlots[browse.slotIndex].customerId == customerId then
				shelfSlots[browse.slotIndex] = nil
			end
		end
		customerBrowseSlots[customerId] = nil
	end

	local checkout = customerCheckoutSlots[customerId]
	if checkout then
		local slots = checkoutReservations[checkout.businessKey]
		if slots and slots[checkout.slotIndex] then
			if slots[checkout.slotIndex].customerId == customerId then
				slots[checkout.slotIndex] = nil
			end
		end
		customerCheckoutSlots[customerId] = nil
	end

	movementReservations[customerId] = nil
end

function CrowdService.ReserveShelfSlot(
	businessId: string,
	shelfId: string,
	customerId: string,
	lifetimeSeconds: number?
): number?
	CrowdService.ReleaseCustomerReservations(customerId)

	local key = getShelfReservationKey(businessId, shelfId)
	local slots = shelfReservations[key]

	if not slots then
		slots = {}
		shelfReservations[key] = slots
	end

	cleanExpired(slots, function(reservation)
		return reservation.expiresAt < os.clock()
	end)

	local now = os.clock()
	local startIndex = hashString(`{businessId}:{customerId}:{shelfId}`) % SHELF_SLOT_COUNT + 1

	for offset = 0, SHELF_SLOT_COUNT - 1 do
		local slotIndex = ((startIndex + offset - 1) % SHELF_SLOT_COUNT) + 1
		local reservation = slots[slotIndex]

		if not reservation or reservation.expiresAt < now or reservation.customerId == customerId then
			slots[slotIndex] = {
				customerId = customerId,
				expiresAt = now + (lifetimeSeconds or 18),
			}

			customerBrowseSlots[customerId] = {
				shelfKey = key,
				slotIndex = slotIndex,
			}

			return slotIndex
		end
	end

	return nil
end

function CrowdService.ReserveCheckoutSlot(
	businessId: string,
	customerId: string,
	preferredSlot: number?,
	lifetimeSeconds: number?
): number?
	local key = getCheckoutReservationKey(businessId)
	local slots = checkoutReservations[key]

	if not slots then
		slots = {}
		checkoutReservations[key] = slots
	end

	cleanExpired(slots, function(reservation)
		return reservation.expiresAt < os.clock()
	end)

	local now = os.clock()
	local checkoutSlot = customerCheckoutSlots[customerId]
	if checkoutSlot and checkoutSlot.businessKey == key then
		local reservation = slots[checkoutSlot.slotIndex]
		local ownsCurrentSlot = reservation ~= nil and reservation.customerId == customerId

		if preferredSlot == nil or preferredSlot == checkoutSlot.slotIndex then
			if ownsCurrentSlot and reservation then
				reservation.expiresAt = now + (lifetimeSeconds or 45)
				return checkoutSlot.slotIndex
			end

			customerCheckoutSlots[customerId] = nil
		elseif ownsCurrentSlot then
			slots[checkoutSlot.slotIndex] = nil
			customerCheckoutSlots[customerId] = nil
		end
	elseif checkoutSlot then
		customerCheckoutSlots[customerId] = nil
	end

	if preferredSlot then
		local slotIndex = math.clamp(preferredSlot, 1, CHECKOUT_SLOT_COUNT)
		local reservation = slots[slotIndex]

		if reservation and reservation.customerId ~= customerId and reservation.expiresAt >= now then
			return nil
		elseif reservation and reservation.customerId ~= customerId then
			customerCheckoutSlots[reservation.customerId] = nil
		end

		slots[slotIndex] = {
			customerId = customerId,
			expiresAt = now + (lifetimeSeconds or 45),
		}

		customerCheckoutSlots[customerId] = {
			businessKey = key,
			slotIndex = slotIndex,
		}

		return slotIndex
	end

	local startIndex = preferredSlot or (hashString(`{businessId}:{customerId}`) % CHECKOUT_SLOT_COUNT + 1)

	for offset = 0, CHECKOUT_SLOT_COUNT - 1 do
		local slotIndex = ((startIndex + offset - 1) % CHECKOUT_SLOT_COUNT) + 1
		local reservation = slots[slotIndex]

		if not reservation or reservation.expiresAt < now or reservation.customerId == customerId then
			slots[slotIndex] = {
				customerId = customerId,
				expiresAt = now + (lifetimeSeconds or 45),
			}

			customerCheckoutSlots[customerId] = {
				businessKey = key,
				slotIndex = slotIndex,
			}

			return slotIndex
		end
	end

	return preferredSlot
end

function CrowdService.ReserveMovementPosition(
	customerId: string,
	position: Vector3,
	lifetimeSeconds: number?
): boolean
	local now = os.clock()
	local lifetime = lifetimeSeconds or MOVEMENT_SLOT_LIFETIME

	for otherId, reservation in movementReservations do
		if otherId ~= customerId and reservation.expiresAt >= now then
			if (reservation.position - position).Magnitude < 1.4 then
				return false
			end
		end
	end

	movementReservations[customerId] = {
		customerId = customerId,
		position = position,
		expiresAt = now + lifetime,
	}
	return true
end

function CrowdService.RefreshReservation(customerId: string, extraSeconds: number?)
	local browse = customerBrowseSlots[customerId]
	if browse then
		local slots = shelfReservations[browse.shelfKey]
		if slots then
			local reservation = slots[browse.slotIndex]
			if reservation and reservation.customerId == customerId then
				reservation.expiresAt = os.clock() + (extraSeconds or 12)
			end
		end
	end

	local checkout = customerCheckoutSlots[customerId]
	if checkout then
		local slots = checkoutReservations[checkout.businessKey]
		if slots then
			local reservation = slots[checkout.slotIndex]
			if reservation and reservation.customerId == customerId then
				reservation.expiresAt = os.clock() + (extraSeconds or 30)
			end
		end
	end
end

function CrowdService.GetNearbyCustomers(position: Vector3, radius: number, ignoreModel: Model?): { Model }
	local folder = Workspace:FindFirstChild("ActiveCustomers")
	if not folder or not folder:IsA("Folder") then
		return {}
	end

	local results = {}

	for _, child in ipairs(folder:GetChildren()) do
		if child == ignoreModel then
			continue
		end

		if not child:IsA("Model") then
			continue
		end

		local root = getRoot(child)
		if not root then
			continue
		end

		if (root.Position - position).Magnitude <= radius then
			table.insert(results, child)
		end
	end

	return results
end

function CrowdService.GetCrowdSlowdown(position: Vector3, radius: number, ignoreModel: Model?): number
	local nearby = CrowdService.GetNearbyCustomers(position, radius, ignoreModel)
	local count = #nearby

	if count <= 0 then
		return 1
	elseif count == 1 then
		return 0.92
	elseif count == 2 then
		return 0.78
	elseif count == 3 then
		return 0.64
	end

	return 0.5
end

function CrowdService.GetAvoidanceOffset(model: Model, targetPosition: Vector3): Vector3
	local root = getRoot(model)
	if not root then
		return Vector3.zero
	end

	local position = root.Position
	local desiredDirection = targetPosition - position

	if desiredDirection.Magnitude < 0.1 then
		return Vector3.zero
	end

	desiredDirection = Vector3.new(desiredDirection.X, 0, desiredDirection.Z).Unit

	local avoidance = Vector3.zero
	local nearby = CrowdService.GetNearbyCustomers(position, AVOIDANCE_RADIUS, model)

	for _, other in ipairs(nearby) do
		local otherRoot = getRoot(other)
		if not otherRoot then
			continue
		end

		local offset = position - otherRoot.Position
		local flatOffset = Vector3.new(offset.X, 0, offset.Z)
		local distance = flatOffset.Magnitude

		if distance <= 0.05 then
			continue
		end

		local otherVelocity = otherRoot.AssemblyLinearVelocity
		local predictedOtherPosition = otherRoot.Position + otherVelocity * PREDICTION_TIME
		local predictedOffset = position - predictedOtherPosition
		local predictedFlat = Vector3.new(predictedOffset.X, 0, predictedOffset.Z)
		local predictedDistance = predictedFlat.Magnitude

		local dangerDistance = math.min(distance, predictedDistance)

		if dangerDistance < PERSONAL_SPACE then
			local strength = 1 - math.clamp(dangerDistance / PERSONAL_SPACE, 0, 1)

			if dangerDistance < HARD_PERSONAL_SPACE then
				strength *= 1.6
			end

			-- Blend separation with slight lateral bias (deterministic per model)
			local lateral = Vector3.new(-desiredDirection.Z, 0, desiredDirection.X)
			local side = if hashString(model.Name) % 2 == 0 then 1 else -1
			local separation = flatOffset.Unit * strength * 0.7 + lateral * side * strength * 0.3
			avoidance += separation
		end
	end

	if avoidance.Magnitude < 0.01 then
		return Vector3.zero
	end

	return avoidance.Unit * math.clamp(avoidance.Magnitude, 0, MAX_AVOIDANCE_OFFSET)
end

function CrowdService.GetNaturalTargetPosition(model: Model, targetPosition: Vector3, spreadRadius: number?): Vector3
	local root = getRoot(model)
	if not root then
		return targetPosition
	end

	local hash = hashString(`{model.Name}:{math.floor(targetPosition.X)}:{math.floor(targetPosition.Z)}`)
	local angle = math.rad(hash % 360)
	local radius = spreadRadius or 1.1

	local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)

	return targetPosition + offset
end

function CrowdService.GetAdjustedMoveTarget(model: Model, targetPosition: Vector3): Vector3
	local naturalTarget = CrowdService.GetNaturalTargetPosition(model, targetPosition, 1.0)
	local avoidanceOffset = CrowdService.GetAvoidanceOffset(model, naturalTarget)

	if CrowdService.IsPathCrowdedAhead(model, naturalTarget) then
		naturalTarget = CrowdService.GetSideStepTarget(model, naturalTarget)
	end

	return naturalTarget + avoidanceOffset
end

function CrowdService.ShouldYield(model: Model, targetPosition: Vector3): boolean
	local root = getRoot(model)
	if not root then
		return false
	end

	local nearby = CrowdService.GetNearbyCustomers(root.Position, HARD_PERSONAL_SPACE + 0.5, model)

	if #nearby <= 0 then
		return false
	end

	local toTarget = targetPosition - root.Position
	if toTarget.Magnitude < 0.1 then
		return false
	end

	local moveDirection = Vector3.new(toTarget.X, 0, toTarget.Z).Unit

	for _, other in ipairs(nearby) do
		local otherRoot = getRoot(other)
		if not otherRoot then
			continue
		end

		local toOther = otherRoot.Position - root.Position

		if toOther.Magnitude < 0.1 then
			continue
		end

		local flatOther = Vector3.new(toOther.X, 0, toOther.Z)
		local dot = moveDirection:Dot(flatOther.Unit)

		if dot > 0.5 and getPriority(other) > getPriority(model) then
			return true
		end
	end

	return false
end

return CrowdService
