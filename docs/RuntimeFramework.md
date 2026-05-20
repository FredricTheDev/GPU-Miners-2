# Custom client/server runtime (Services & Controllers)

This project uses a small **ModuleRuntime** bootstrap (`ReplicatedStorage.Shared.Runtime.ModuleRuntime`) that:

1. **Discovers** all `ModuleScripts` under a root folder (`Services` on the server, `Controllers` on the client).
2. **Requires** each module safely (`pcall`).
3. **Validates** the exported table shape (strict rules for metadata fields).
4. **Registers** modules by **`Name`** (or the script’s `Name` if `Name` is omitted).
5. **Runs `Configure(self, registry)`** (optional) after registration but **before** dependency ordering / init.
6. **Resolves** a startup order with **topological sort** over `Dependencies`, breaking ties with **`Priority`** (lower runs earlier) then **name**.
7. **Runs `OnInit(self)`** for every registered module in that order.
8. **Runs `OnStart(self)`** only after **all** `OnInit` calls succeed.

If anything is fatally wrong (circular dependencies, `Configure` / `OnInit` / `OnStart` throws), bootstrap **stops** and returns `Success = false` with **Error** diagnostics.

---

## Rojo / DataModel layout (this repo)

- **Shared code**: `ReplicatedStorage.Shared` → `src/shared`
- **Server entry**: `ServerScriptService.Server` → `src/server`
- **Client entry**: `StarterPlayer.StarterPlayerScripts.Client` → `src/client`

Your runtime scripts should live next to the folders they scan:

- `src/server/Runtime.server.luau` scans `src/server/Services`
- `src/client/Runtime.client.lua` scans `src/client/Controllers`

---

## Setup checklist

1. **Add the bootstrap module** (already included):
   - `src/shared/Runtime/ModuleRuntime.luau`
2. **Create folders**:
   - `src/server/Services` for server modules
   - `src/client/Controllers` for client modules
3. **Add/keep entry scripts**:
   - `Runtime.server.luau` under `src/server`
   - `Runtime.client.lua` (or `.luau`) under `src/client`
4. **Ensure Rojo maps `Shared` into `ReplicatedStorage`** (already configured in `default.project.json`).
5. **Wire `exposeContext`** (recommended): pass a callback so `_G.ServerRuntime` / `_G.ClientRuntime` exists **before** any `OnInit` / `OnStart` runs (`IsStarted()` is still `false` until the very end).

   ```lua
   ModuleRuntime.BootstrapServer(folder, function(context)
       _G.ServerRuntime = context
   end)
   ```

---

## Service / Controller module shape

Each module should `require` **nothing heavy** at file top beyond pure dependencies. Return **one table** (`ModuleExports`) that includes metadata and methods.

### Required / common fields

| Field | Type | Purpose |
|------|------|---------|
| `Name` | `string?` | Registry key. If omitted, **`ModuleScript.Name`** is used. |
| `Priority` | `number?` | Sorting hint when **dependency order allows ties**. **Lower runs earlier**. Default `0`. |
| `Dependencies` | `{ string }?` | Names of modules that must init **before** this one. |
| `Disabled` | `boolean?` | If `true`, module is skipped (not registered, not started). |
| `Configure` | `function?` | `(self, registry) -> ()` — optional pre-init wiring with registry access. |
| `OnInit` | `function?` | `(self) -> ()` — runs after all modules are registered and ordered; **before any** `OnStart`. |
| `OnStart` | `function?` | `(self) -> ()` — runs **after every** eligible module finished `OnInit`. |

You may add **your own methods/fields** (e.g. `GetPlayerData`) as long as they are **simple serializable-ish types** for the runtime validator:

- Allowed extra field value types: `string`, `number`, `boolean`, `table`, `function`
- Disallowed in export “metadata”: `Instance`, `thread`, arbitrary userdata, etc. (prevents accidental `require`-time captures)

### Declaring dependencies

Use the **registry `Name` strings**, not file paths:

```lua
Dependencies = { "DataService", "NetworkService" }
```

Rules:

- Dependencies must refer to modules that **successfully registered**.
- If a dependency is **missing**, **disabled**, or **skipped due to duplicate `Name` collision**, you get a **Warn** diagnostic and the edge is ignored (the dependent may init “too early” relative to intent—fix the graph).
- Cycles produce a hard bootstrap **Error** (topological sort cannot complete).

### Example skeleton

```lua
--!strict

local MyService = {}

MyService.Name = "MyService"
MyService.Priority = 10
MyService.Dependencies = { "DataService" }
MyService.Disabled = false

function MyService:Configure(registry)
	self._data = registry.DataService
end

function MyService:OnInit()
	-- Safe to assume DataService completed OnInit already (dependency order).
end

function MyService:OnStart()
	-- Safe to assume every other module finished OnInit.
end

return MyService
```

---

## Runtime API (`RuntimeContext`)

After a successful bootstrap, `Context` exposes:

- **`Registry`**: `{ [string]: ModuleExports }` map for direct indexing
- **`Get(name)`**: `ModuleExports?`
- **`Expect(name)`**: `ModuleExports` (throws if missing)
- **`Has(name)`**: `boolean`
- **`IsStarted()`**: `boolean` — `true` only after **all** `OnStart` hooks finish
- **`ListRegisteredNames()`**: sorted array of names

---

## Diagnostics & failure modes

The bootstrap collects **`Diagnostics`** with severities:

- **Warn**: failed `require`, invalid export shape, missing dependency target, duplicate `Name` (skipped module), etc.
- **Error**: circular dependencies, thrown `Configure` / `OnInit` / `OnStart`

Use `ModuleRuntime.formatDiagnostics(result.Diagnostics)` to build a single error string in your Runtime script.

---

## Why this ordering model?

- **`Configure`**: deterministic, sorted-by-name hook for **cross-references** using the `registry` table **before** any lifecycle begins. Nothing is “initialized” yet; don’t assume another service finished `OnInit`.
- **`OnInit`**: dependency-ordered construction (load caches, bind remotes, connect low-level listeners).
- **`OnStart`**: cross-service “we’re live” work (start ticking systems, enable UX, publish readiness).

This mirrors common “init vs start” splits while staying lightweight (no OOP framework required).

---

## Files to reference in this repo

- Implementation: `src/shared/Runtime/ModuleRuntime.luau`
- Server entry example: `src/server/Runtime.server.luau`
- Client entry example: `src/client/Runtime.client.lua`
- Example server module: `src/server/Services/ExampleService.luau`
- Example client module: `src/client/Controllers/ExampleController.luau`
