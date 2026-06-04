--!strict
--[[
	ModuleRuntime — lightweight discovery + dependency ordering + lifecycle for Services/Controllers.

	Lifecycle (high level):
	1. Discover — recursively collect ModuleScripts under `rootFolder`
	2. Require — `pcall(require, ...)` each script; record failures
	3. Validate — ensure each export is a table with allowed optional fields
	4. Register — assign Name (explicit or script.Name), Priority, Dependencies; detect duplicates/disabled entries
	5. Configure (optional) — run `Configure(self, registry)` before ordering, after `Registry` exists
	6. Resolve order — topo-sort by Dependencies; ties broken by Priority (lower first), then Name
	7. Init — invoke OnInit(...) in dependency order (`xpcall` + traceback)
	8. Start — invoke OnStart(...) after all inits succeed (same deterministic order)

	Requires `rootFolder` to be your `Services` or `Controllers` container (typically a Folder in a Rojo tree).
]]

local ModuleRuntime = {}

export type LifecycleFn = (self: ModuleExports) -> ()

export type ModuleExports = {
	Name: string?,
	Priority: number?,
	Dependencies: { string }?,
	Disabled: boolean?,
	OnInit: LifecycleFn?,
	OnStart: LifecycleFn?,
	Configure: ((ModuleExports, Registry) -> ())?,
	[string]: any?,
}

export type Registry = { [string]: ModuleExports }

export type BootstrapResult = {
	Context: RuntimeContext?,
	Logs: Logs,
	Diagnostics: { Diagnostic },
	Success: boolean,
}

export type Severity = "Info" | "Warn" | "Error"

export type Diagnostic = {
	Severity: Severity,
	Scope: string,
	Message: string,
}

export type RuntimeContext = {
	Registry: Registry,
	Get: (name: string) -> ModuleExports?,
	Expect: (name: string) -> ModuleExports,
	Has: (name: string) -> boolean,
	IsStarted: () -> boolean,
	ListRegisteredNames: () -> { string },
}

export type Logs = {
	Info: number,
	Warn: number,
	Error: number,
}

local function defaultLogs(): Logs
	return {
		Info = 0,
		Warn = 0,
		Error = 0,
	}
end

local function recordDiag(diagnostics: { Diagnostic }, severity: Severity, scope: string, message: string, logs: Logs)
	table.insert(diagnostics, {
		Severity = severity,
		Scope = scope,
		Message = message,
	})
	logs[severity] += 1

	local prefix = string.format("[%s][%s]", scope, severity)
	if severity == "Info" then
		print(string.format("%s %s", prefix, message))
	else
		warn(string.format("%s %s", prefix, message))
	end
end

function ModuleRuntime.formatDiagnostics(diagnostics: { Diagnostic }): string
	local lines: { string } = {}
	for _, d in diagnostics do
		table.insert(lines, string.format("%s %s: %s", d.Scope, d.Severity, d.Message))
	end
	return table.concat(lines, "\n")
end

local TYPE_FUNCTION = typeof(function() end)

local function validateExportShape(diagnostics: { Diagnostic }, logs: Logs, moduleScriptName: string, export: any): boolean
	local scope = "ValidateExport"
	if typeof(export) ~= "table" then
		recordDiag(diagnostics, "Warn", scope, string.format("`%s` must return a table (got `%s`). Skipping.", moduleScriptName, typeof(export)), logs)
		return false
	end

	if export.Name ~= nil and typeof(export.Name) ~= "string" then
		recordDiag(diagnostics, "Warn", scope, string.format("`%s`: Name must be a string.", moduleScriptName), logs)
		return false
	end

	if export.Priority ~= nil and typeof(export.Priority) ~= "number" then
		recordDiag(diagnostics, "Warn", scope, string.format("`%s`: Priority must be a number.", moduleScriptName), logs)
		return false
	end

	if export.Disabled ~= nil and typeof(export.Disabled) ~= "boolean" then
		recordDiag(diagnostics, "Warn", scope, string.format("`%s`: Disabled must be a boolean.", moduleScriptName), logs)
		return false
	end

	if export.Dependencies ~= nil then
		if typeof(export.Dependencies) ~= "table" then
			recordDiag(diagnostics, "Warn", scope, string.format("`%s`: Dependencies must be an array-like table.", moduleScriptName), logs)
			return false
		end
		local depList = export.Dependencies :: { any }
		for i = 1, #depList do
			local v = depList[i]
			if typeof(v) ~= "string" or v == "" then
				recordDiag(diagnostics, "Warn", scope, string.format("`%s`: Dependencies must be an array of non-empty strings.", moduleScriptName), logs)
				return false
			end
		end
	end

	local function checkFn(field: string, value: any): boolean
		if value == nil then
			return true
		end
		if typeof(value) ~= TYPE_FUNCTION then
			recordDiag(diagnostics, "Warn", scope, string.format("`%s`: %s must be a function.", moduleScriptName, field), logs)
			return false
		end
		return true
	end

	if not checkFn("OnInit", export.OnInit) then
		return false
	end
	if not checkFn("OnStart", export.OnStart) then
		return false
	end
	if not checkFn("Configure", export.Configure) then
		return false
	end

	for k, v in export do
		if typeof(k) ~= "string" then
			recordDiag(diagnostics, "Warn", scope, string.format("`%s`: non-string key in export table is not supported.", moduleScriptName), logs)
			return false
		end

		if k ~= "Name" and k ~= "Priority" and k ~= "Dependencies" and k ~= "Disabled" and k ~= "OnInit" and k ~= "OnStart" and k ~= "Configure" then
			local t = typeof(v)
			if t ~= "string" and t ~= "number" and t ~= "boolean" and t ~= "table" and t ~= TYPE_FUNCTION then
				recordDiag(
					diagnostics,
					"Warn",
					scope,
					string.format(
						"`%s`: export field `%s` has unsupported type `%s` (avoid Instances/threads/userdata in metadata).",
						moduleScriptName,
						k,
						t
					),
					logs
				)
				return false
			end
		end
	end

	return true
end

local function collectModuleScripts(root: Instance): { ModuleScript }
	local list: { ModuleScript } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("ModuleScript") then
			table.insert(list, d :: ModuleScript)
		end
	end
	table.sort(list, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return list
end

local function safeRequire(moduleScript: ModuleScript): (boolean, any, string?)
	local ok, result = pcall(require, moduleScript)
	if ok then
		return true, result, nil
	end
	return false, nil, tostring(result)
end

type InternalModule = {
	Script: ModuleScript,
	Export: ModuleExports,
	Name: string,
	Priority: number,
	Dependencies: { string },
	Disabled: boolean,
}

local function bootstrapInternal(rootFolder: Instance, label: string, exposeContext: ((RuntimeContext) -> ())?): BootstrapResult
	local diagnostics: { Diagnostic } = {}
	local logs = defaultLogs()
	local scopeBase = string.format("Runtime:%s", label)

	local function fail(message: string): BootstrapResult
		recordDiag(diagnostics, "Error", scopeBase, message, logs)
		return {
			Context = nil,
			Logs = logs,
			Diagnostics = diagnostics,
			Success = false,
		}
	end

	if typeof(rootFolder) ~= "Instance" then
		return fail("rootFolder must be an Instance (Folder recommended).")
	end

	local moduleScripts = collectModuleScripts(rootFolder)

	local internals: { InternalModule } = {}
	for _, ms in moduleScripts do
		local okReq, export, reqErr = safeRequire(ms)
		if not okReq then
			recordDiag(
				diagnostics,
				"Warn",
				string.format("%s:Require", scopeBase),
				string.format("Failed require `%s`: %s", ms:GetFullName(), tostring(reqErr)),
				logs
			)
			continue
		end

		if not validateExportShape(diagnostics, logs, ms.Name, export) then
			continue
		end

		local exp = export :: ModuleExports
		local disabled = exp.Disabled == true
		local name = if typeof(exp.Name) == "string" and exp.Name ~= "" then exp.Name else ms.Name
		local priority = if typeof(exp.Priority) == "number" then exp.Priority else 0
		local deps = if typeof(exp.Dependencies) == "table" then exp.Dependencies :: { string } else {}

		table.insert(internals, {
			Script = ms,
			Export = exp,
			Name = name,
			Priority = priority,
			Dependencies = deps,
			Disabled = disabled,
		})
	end

	table.sort(internals, function(a, b)
		return a.Script:GetFullName() < b.Script:GetFullName()
	end)

	local registry: Registry = {}
	local enabledByName: { [string]: InternalModule } = {}
	local registeredNames: { [string]: boolean } = {}

	for _, m in internals do
		if m.Disabled then
			recordDiag(
				diagnostics,
				"Info",
				string.format("%s:Register", scopeBase),
				string.format("Skipping disabled module `%s` (`%s`)", m.Name, m.Script:GetFullName()),
				logs
			)
			continue
		end

		if registeredNames[m.Name] then
			recordDiag(
				diagnostics,
				"Warn",
				string.format("%s:Register", scopeBase),
				string.format(
					"Duplicate module Name `%s`. Skipping `%s` (first registered instance wins).",
					m.Name,
					m.Script:GetFullName()
				),
				logs
			)
			continue
		end

		registeredNames[m.Name] = true
		registry[m.Name] = m.Export
		enabledByName[m.Name] = m
	end

	local configureOrder: { string } = {}
	for name in enabledByName do
		table.insert(configureOrder, name)
	end
	table.sort(configureOrder)

	for _, name in configureOrder do
		local m = enabledByName[name]
		local configure = m.Export.Configure
		if configure ~= nil then
			local okC, errC = xpcall(function()
				configure(m.Export, registry)
			end, debug.traceback)
			if not okC then
				return fail(string.format("Configure failed for `%s`:\n%s", name, tostring(errC)))
			end
		end
	end

	local indegree: { [string]: number } = {}
	local dependents: { [string]: { string } } = {}

	for name in enabledByName do
		indegree[name] = 0
		dependents[name] = {}
	end

	for name, m in enabledByName do
		for _, dep in m.Dependencies do
			if enabledByName[dep] == nil then
				recordDiag(
					diagnostics,
					"Warn",
					string.format("%s:Dependencies", scopeBase),
					string.format("`%s` depends on missing/disabled/duplicate-skipped module `%s`", name, dep),
					logs
				)
				continue
			end
			indegree[name] += 1
			table.insert(dependents[dep], name)
		end
	end

	local ready: { string } = {}
	for name, deg in indegree do
		if deg == 0 then
			table.insert(ready, name)
		end
	end

	local function sortNames(names: { string })
		table.sort(names, function(a, b)
			local ma = enabledByName[a]
			local mb = enabledByName[b]
			if ma.Priority ~= mb.Priority then
				return ma.Priority < mb.Priority
			end
			return a < b
		end)
	end

	sortNames(ready)

	local order: { string } = {}
	while #ready > 0 do
		local name = table.remove(ready, 1) :: string
		table.insert(order, name)

		for _, depName in dependents[name] do
			indegree[depName] -= 1
			if indegree[depName] == 0 then
				table.insert(ready, depName)
				sortNames(ready)
			end
		end
	end

	local enabledCount = 0
	for _ in enabledByName do
		enabledCount += 1
	end

	if #order ~= enabledCount then
		return fail(
			string.format(
				"Circular dependency detected while resolving `%s` modules. Resolved %d/%d. Fix dependency graph.",
				label,
				#order,
				enabledCount
			)
		)
	end

	local startedFlag = false
	local context: RuntimeContext = {
		Registry = registry,
		Get = function(name: string): ModuleExports?
			return registry[name]
		end,
		Expect = function(name: string): ModuleExports
			local mod = registry[name]
			if mod == nil then
				error(string.format("[Runtime:%s] Missing module `%s`", label, name), 2)
			end
			return mod
		end,
		Has = function(name: string): boolean
			return registry[name] ~= nil
		end,
		IsStarted = function(): boolean
			return startedFlag
		end,
		ListRegisteredNames = function(): { string }
			local names: { string } = {}
			for n in registry do
				table.insert(names, n)
			end
			table.sort(names)
			return names
		end,
	}

	if exposeContext ~= nil then
		exposeContext(context)
	end

	for _, name in order do
		local mod = enabledByName[name]
		local onInit = mod.Export.OnInit
		if onInit ~= nil then
			local okI, errI = xpcall(function()
				onInit(mod.Export)
			end, debug.traceback)
			if not okI then
				return fail(string.format("OnInit failed for `%s`:\n%s", name, tostring(errI)))
			end
		end
	end

	for _, name in order do
		local mod = enabledByName[name]
		local onStart = mod.Export.OnStart
		if onStart ~= nil then
			local okS, errS = xpcall(function()
				onStart(mod.Export)
			end, debug.traceback)
			if not okS then
				return fail(string.format("OnStart failed for `%s`:\n%s", name, tostring(errS)))
			end
		end
	end

	startedFlag = true
	recordDiag(diagnostics, "Info", scopeBase, string.format("Successfully started (%d modules).", enabledCount), logs)

	return {
		Context = context,
		Logs = logs,
		Diagnostics = diagnostics,
		Success = true,
	}
end

function ModuleRuntime.BootstrapServer(servicesFolder: Instance, exposeContext: ((RuntimeContext) -> ())?): BootstrapResult
	return bootstrapInternal(servicesFolder, "Server", exposeContext)
end

function ModuleRuntime.BootstrapClient(controllersFolder: Instance, exposeContext: ((RuntimeContext) -> ())?): BootstrapResult
	return bootstrapInternal(controllersFolder, "Client", exposeContext)
end

return ModuleRuntime
