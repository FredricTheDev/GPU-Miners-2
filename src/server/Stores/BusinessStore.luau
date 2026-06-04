local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Shared.Modules.Charm)
local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)

type BusinessState = BusinessTypes.BusinessState

type Businesses = {
	[string]: BusinessState,
}

local getBusinesses, setBusinesses = Charm.signal({} :: Businesses)

local function copyDeep<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end

	local result = {}
	local source = value :: any
	for key, child in source do
		result[key] = copyDeep(child)
	end

	return result :: any
end

local function getBusiness(businessId: string): BusinessState?
	return getBusinesses()[businessId]
end

local function getBusinessForOwner(ownerUserId: number): BusinessState?
	for _, business in getBusinesses() do
		if business.ownerUserId == ownerUserId then
			return business
		end
	end

	return nil
end

local function setBusiness(business: BusinessState)
	local snapshot = copyDeep(business)
	setBusinesses(function(state: Businesses)
		local nextState = table.clone(state)
		nextState[business.id] = snapshot
		return nextState
	end)
end

local function removeBusiness(businessId: string)
	setBusinesses(function(state: Businesses)
		if state[businessId] == nil then
			return state
		end

		local nextState = table.clone(state)
		nextState[businessId] = nil
		return nextState
	end)
end

return {
	getBusinesses = getBusinesses,
	getBusiness = getBusiness,
	getBusinessForOwner = getBusinessForOwner,
	setBusiness = setBusiness,
	removeBusiness = removeBusiness,
}
