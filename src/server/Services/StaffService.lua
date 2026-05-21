--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BusinessTypes = require(ReplicatedStorage.Shared.Types.BusinessTypes)
local RuntimeTypes = require(ReplicatedStorage.Shared.Types.RuntimeTypes)
local WorldTags = require(ReplicatedStorage.Shared.WorldTags)

type BusinessState = BusinessTypes.BusinessState
type StaffMember = BusinessTypes.StaffMember
type StaffTask = BusinessTypes.StaffTask
type StaffTaskType = BusinessTypes.StaffTaskType
type StaffMemberRole = BusinessTypes.StaffMemberRole

type StaffServiceType = RuntimeTypes.ModuleRuntimeType & {
	_registry: any,

	_worldQueryService: any?,
	_avatarService: any?,

	Configure: (self: StaffServiceType, registry: any) -> (),
	OnInit: (self: StaffServiceType) -> (),
	OnStart: (self: StaffServiceType) -> (),

	CreateTask: (
		business: BusinessState,
		taskType: StaffTaskType,
		priority: number,
		targetId: string?,
		expiresAfterSeconds: number?
	) -> StaffTask,

	HireStaff: (business: BusinessState, role: StaffMemberRole) -> StaffMember,
	GenerateStoreTasks: (business: BusinessState) -> (),
	AssignTasks: (business: BusinessState) -> (),
	ResolveAssignedTasks: (business: BusinessState, deltaSeconds: number) -> (),
	UpdateStaff: (business: BusinessState, deltaSeconds: number) -> (),
	SpawnPhysicalStaffAsync: (business: BusinessState, staffMember: StaffMember) -> ()
}

local StaffService = {} :: StaffServiceType

StaffService.Name = "StaffService"
StaffService.Priority = 0
StaffService.Dependencies = {}
StaffService.Disabled = false

local taskCounter = 0

local roleTaskTypes: { [string]: { [StaffTaskType]: boolean } } = {
	Cashier = {
		ServeCheckout = true,
	},
	Stocker = {
		RestockShelf = true,
		UnloadDelivery = true,
	},
	Guard = {
		PatrolStore = true,
		ChaseThief = true,
	},
	Technician = {
		RepairRig = true,
		UnloadDelivery = true,
	},
}

local function nextTaskId(taskType: StaffTaskType): string
	taskCounter += 1
	return `{taskType}_{taskCounter}`
end

local function canStaffHandleTask(staffMember: StaffMember, task: StaffTask): boolean
	local allowed = roleTaskTypes[staffMember.role]
	return allowed ~= nil and allowed[task.taskType] == true
end

function StaffService:Configure(registry)
	self._registry = registry

	self._worldQueryService = registry.WorldQueryService
	self._avatarService = registry.AvatarService
end

function StaffService:OnInit() end

function StaffService:OnStart() end

function StaffService.CreateTask(
	business: BusinessState,
	taskType: StaffTaskType,
	priority: number,
	targetId: string?,
	expiresAfterSeconds: number?
): StaffTask
	local now = os.clock()
	local task: StaffTask = {
		id = nextTaskId(taskType),
		taskType = taskType,
		priority = priority,
		assignedStaffId = nil,
		targetId = targetId,
		createdAt = now,
		expiresAt = if expiresAfterSeconds then now + expiresAfterSeconds else nil,
	}

	business.staffTasks[task.id] = task
	return task
end

function StaffService.HireStaff(business: BusinessState, role: StaffMemberRole): StaffMember
	local count = 0
	for _ in business.staff do
		count += 1
	end

	local staffMember: StaffMember = {
		id = `{string.lower(role)}_{count + 1}`,
		role = role,
		wagePerMinute = if role == "Guard" then 18 else 15, -- todo: mock, will react to state
		energy = 100,
		happiness = 75,
		skill = 1,
		currentTaskId = nil,
		physicalModelName = nil,
	}

	business.staff[staffMember.id] = staffMember
	task.spawn(StaffService.SpawnPhysicalStaffAsync, business, staffMember)
	return staffMember
end

function StaffService.SpawnPhysicalStaffAsync(business: BusinessState, staffMember: StaffMember)
	if staffMember.physicalModelName ~= nil then
		return
	end

	-- Todo: custom model rigs // NOT FRIENDS!
	local avatarUserId = StaffService._avatarService.GetAvatarUserIdForOwner(business.ownerUserId)
	local modelName = `{business.id}_{staffMember.id}`
	local model = StaffService._avatarService.CreateCustomerModelAsync(avatarUserId, modelName)
	staffMember.physicalModelName = model.Name

	model:SetAttribute("BusinessId", business.id)
	model:SetAttribute("StaffId", staffMember.id)
	model:SetAttribute("Role", staffMember.role)
	model:SetAttribute("ViewRange", if staffMember.role == "Guard" then 55 else 35)
	model:SetAttribute("ViewFovDegrees", if staffMember.role == "Guard" then 110 else 80)
	model:PivotTo(StaffService._worldQueryService.GetCheckoutCFrame(business.id))
	model.Parent = StaffService._worldQueryService.GetOrCreateStaffFolder()

	CollectionService:AddTag(model, WorldTags.StaffNpc)
end

function StaffService.GenerateStoreTasks(business: BusinessState)
	if business.store.checkoutQueueLength > 0 then
		StaffService.CreateTask(business, "ServeCheckout", 50 + business.store.checkoutQueueLength, nil, 10)
	end

	for _, shelf in business.store.shelves do
		if shelf.gpuId and shelf.stockAmount < shelf.maxStock * 0.35 then
			StaffService.CreateTask(business, "RestockShelf", 35, shelf.id, 20)
		end
	end
end

function StaffService.AssignTasks(business: BusinessState)
	local now = os.clock()

	for taskId, task in business.staffTasks do
		if task.expiresAt and task.expiresAt < now and not task.assignedStaffId then
			business.staffTasks[taskId] = nil
		end
	end

	for _, staffMember in business.staff do
		if staffMember.currentTaskId == nil then
			local bestTask: StaffTask? = nil

			for _, task in business.staffTasks do
				if task.assignedStaffId == nil and canStaffHandleTask(staffMember, task) then
					if not bestTask or task.priority > bestTask.priority then
						bestTask = task
					end
				end
			end

			if bestTask then
                print(`Assigned {staffMember.id} with task {bestTask.id}`)
                bestTask.assignedStaffId = staffMember.id
                staffMember.currentTaskId = bestTask.id
            end
		end
	end
end

function StaffService.ResolveAssignedTasks(business: BusinessState, deltaSeconds: number)
    for _, staffMember in business.staff do
        local taskId = staffMember.currentTaskId
        local task = if taskId then business.staffTasks[taskId] else nil
        -- todo: adjust energy variation based on other staff properties like 
        -- tasks done within a period of time will make energy go down faster
        if task then
            staffMember.energy = math.max(0, staffMember.energy - deltaSeconds * 0.2)

            -- todo: this is placeholder logic, right now itll resolve tasks after each simulation tick
            -- but when we have actual pathfinding systems we will need to resolve the task when the npc
            -- physically moves to it and does it
            if task.taskType == "ServeCheckout" then
                business.store.checkoutQueueLength = math.max(0, business.store.checkoutQueueLength - 1)
            elseif task.taskType == "PatrolStore" then
                business.security.securityLevel = math.clamp(business.security.securityLevel + 0.1, 0, 100)
            end

            business.staffTasks[task.id] = nil
            staffMember.currentTaskId = nil
        else
            staffMember.energy = math.min(100, staffMember.energy + deltaSeconds * 0.1)
        end
    end
end

function StaffService.UpdateStaff(business: BusinessState, deltaSeconds: number)
    StaffService.GenerateStoreTasks(business)
    StaffService.AssignTasks(business)
    StaffService.ResolveAssignedTasks(business, deltaSeconds)
end

return StaffService
