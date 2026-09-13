-- Strict session-lifecycle tests for MoreRVers.
--
-- Adapted from the fixture contributed in aldikosh23's fix/session-cap-lifecycle
-- branch, retargeted at this repository's sweep-based main.lua.
--
-- Where tools/ue4ss_stub_test.lua is a permissive smoke test, this file models
-- the UE4SS boundary and asserts the mod respects it:
--   * every UObject access happens on the game thread
--   * the mod degrades to fewer triggers, never to a silent no-op
--   * writes that fail or silently do not stick are detected, not reported OK
--   * caps reset behind the mod's back are restored by the login trigger
--   * travel to a GameSession subclass patches that subclass's own default
--   * config.ini parses through Windows paths, a BOM, and trailing comments
--
-- It does not run Unreal Engine, UE4SS's native hooks, or Steam networking.
-- Run from the repository root:  lua5.4 tools/session_test.lua

local patched = "Mods/MoreRVers/scripts/main.lua"
local checks = 0
local function check(condition, message)
    if not condition then
        error("FAILED: " .. message, 2)
    end
    checks = checks + 1
end

-- Model the UE4SS boundary, not the mod's implementation. Property access must
-- run on the game thread; BeginPlay context is wrapped in a RemoteUnrealParam,
-- whereas searches return UObjects directly. Only documented members exist:
-- reading an unknown one raises, so a typo in the mod cannot pass as nil.
local function fixture(config)
    local f = {thread = false, logs = {}, queue = {}, loops = {}, hooks = {}, registry = {}}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.UE = nil
    env.print = function(message) f.logs[#f.logs + 1] = tostring(message) end

    local function game_thread()
        assert(f.thread, "UObject access outside the game thread")
    end

    function f.object(class_name, values, cdo)
        local object = {}
        local methods = {
            IsValid = function() game_thread(); return true end,
            GetFullName = function() game_thread(); return class_name .. " /Game/Ride/Maps/Level" end,
            IsA = function(_, cls)
                game_thread()
                return cls ~= nil and cls.__session_class == true
                    and class_name:find("GameSession") ~= nil
            end,
            GetClass = function()
                game_thread()
                return {
                    __session_class = class_name:find("GameSession") ~= nil,
                    GetFName = function() return {ToString = function() return class_name end} end,
                    GetDefaultObject = function() game_thread(); return cdo or object end,
                }
            end,
        }
        setmetatable(object, {
            __index = function(_, key)
                if methods[key] then return methods[key] end
                game_thread()
                if values[key] == nil then error("unknown UObject member: " .. key) end
                return values[key]
            end,
            __newindex = function(_, key, value)
                game_thread()
                if f.reject_write == object then error("reflected property is read only") end
                if f.ignore_write ~= object then values[key] = value end
            end,
        })
        rawset(object, "__values", values)
        return object
    end

    -- Values live outside the proxy so tests can read and reset them off-thread.
    function f.session(class_name, initial, cdo)
        return f.object(class_name, {MaxPlayers = initial, MaxSpectators = 2}, cdo)
    end

    function f.call(callback, ...)
        f.thread = true
        local ok, err = pcall(callback, ...)
        f.thread = false
        if not ok then error(err, 0) end
    end

    function f.flush()
        local queued = f.queue
        f.queue = {}
        for _, callback in ipairs(queued) do f.call(callback) end
    end

    function f.logged(text)
        return table.concat(f.logs, "\n"):find(text, 1, true) ~= nil
    end

    f.engine_cdo = f.session("Default__GameSession", 4)

    env.StaticFindObject = function(path)
        game_thread()
        if path == "/Script/Engine.Default__GameSession" then return f.engine_cdo end
        if path == "/Script/Engine.GameSession" then
            return {
                __session_class = true,
                IsValid = function() return true end,
                GetDefaultObject = function() return f.engine_cdo end,
            }
        end
        return nil
    end
    env.FindAllOf = function(class_name)
        game_thread()
        return f.registry[class_name]
    end
    env.ExecuteInGameThread = function(callback) f.queue[#f.queue + 1] = callback end
    env.RegisterLoadMapPostHook = function(cb) f.hooks.map = cb end
    env.NotifyOnNewObject = function(cls, cb) f.hooks["new:" .. cls] = cb end
    env.RegisterBeginPlayPostHook = function(cb) f.hooks.beginplay = cb end
    env.RegisterHook = function(sig, cb)
        if not sig:find("GameModeBase") and not sig:find("GameSession") then
            error("no such function: " .. sig)
        end
        f.hooks[sig] = cb
    end
    env.LoopAsync = function(ms, cb) f.loops[#f.loops + 1] = {ms = ms, cb = cb} end
    env.RegisterConsoleCommandHandler = function(name, cb) f.hooks["cmd:" .. name] = cb end
    env.RegisterKeyBind = function(key, cb) assert(key == 121); f.hooks.key = cb end
    env.Key = {F10 = 121}
    env.UnrealVersion = {
        GetMajorVersion = function() return 5 end,
        GetMinorVersion = function() return 5 end,
    }

    local windows_source = "C:\\Games\\RV There Yet\\ue4ss\\Mods\\MoreRVers\\scripts\\main.lua"
    if config then
        env.io = {open = function(path)
            assert(path == "C:/Games/RV There Yet/ue4ss/Mods/MoreRVers/scripts/../config.ini"
                or path == "C:\\Games\\RV There Yet\\ue4ss\\Mods\\MoreRVers\\scripts/../config.ini",
                "unexpected config path: " .. tostring(path))
            return {
                lines = function() return config:gmatch("[^\r\n]+") end,
                close = function() end,
            }
        end}
    end

    -- UE4SS runs a mod's main chunk on a thread where object access is allowed,
    -- so trigger installation may touch UObjects; per-callback access is still
    -- held to the game-thread rule below.
    function f.load()
        local chunk
        if config then
            local input = assert(io.open(patched))
            local code = input:read("*a")
            input:close()
            chunk = assert(load(code, "@" .. windows_source, "t", env))
        else
            chunk = assert(loadfile(patched, "t", env))
        end
        f.thread = true
        local ok, result = pcall(chunk)
        f.thread = false
        if not ok then error(result, 0) end
        return result
    end

    return f, env
end

--------------------------------------------------------------------------------
-- Startup: triggers install, and the engine default is patched for hosting.
--------------------------------------------------------------------------------

local f = fixture()
local session = f.session("BP_RideGameSession_C", 4, f.engine_cdo)
f.registry = {GameSession = {session}, GameModeBase = {}, GameStateBase = {}}
local Mod = f.load()

check(Mod.TargetMaxPlayers == 8, "target cap must come from config.ini")
check(#f.queue == 1, "startup sweep must be queued onto the game thread, not run inline")
f.flush()
check(session.__values.MaxPlayers == 8, "startup sweep must patch a live session")
check(f.engine_cdo.__values.MaxPlayers == 8, "startup must patch the engine default for hosting")
check(session.__values.MaxSpectators == 2, "unrelated limits must be left alone")
check(f.hooks["/Script/Engine.GameModeBase:K2_PostLogin"], "login trigger must install")
check(f.hooks.map, "map load trigger must install")
check(f.hooks.key, "F10 diagnostics keybind must install")
check(#f.loops == 1 and f.loops[1].ms == 10000, "periodic re-apply must install at the configured interval")

--------------------------------------------------------------------------------
-- The game resets the cap behind the mod's back; each trigger must restore it.
--------------------------------------------------------------------------------

session.__values.MaxPlayers = 4
f.call(f.hooks["/Script/Engine.GameModeBase:K2_PostLogin"])
check(session.__values.MaxPlayers == 8, "login must restore a cap the game reset")

session.__values.MaxPlayers = 4
local map_result
f.call(function() map_result = f.hooks.map() end)
check(map_result == nil, "map hook must not alter the engine's LoadMap return value")
check(session.__values.MaxPlayers == 8, "map load must restore a cap reset during travel")

session.__values.MaxPlayers = 4
f.call(function() f.loops[1].cb() end)
check(session.__values.MaxPlayers == 8, "periodic re-apply must restore a cap reset off-hook")
f.call(function() check(f.loops[1].cb() == false, "periodic loop must keep running") end)

--------------------------------------------------------------------------------
-- Travel creates a new instance, possibly of a subclass with its own default.
--------------------------------------------------------------------------------

local subclass_cdo = f.session("Default__BP_OtherGameSession_C", 4)
local next_session = f.session("BP_OtherGameSession_C", 4, subclass_cdo)
f.registry.GameSession = {next_session}
f.call(f.hooks.map)
check(next_session.__values.MaxPlayers == 8, "travel must patch the new session instance")
check(subclass_cdo.__values.MaxPlayers == 8, "travel must patch the exact subclass default, not just the engine one")

-- BeginPlay of a spawned actor: only GameSessions are touched.
next_session.__values.MaxPlayers = 4
f.call(f.hooks.beginplay, {get = function() return next_session end})
check(next_session.__values.MaxPlayers == 8, "GameSession actor BeginPlay must apply the cap")

local widget = f.object("BP_LobbyWidget_C", {MaxPlayers = 4})
f.call(f.hooks.beginplay, {get = function() return widget end})
check(widget.__values.MaxPlayers == 4, "a non-GameSession actor must be ignored")

--------------------------------------------------------------------------------
-- Failing writes must be reported, never counted as success.
--------------------------------------------------------------------------------

next_session.__values.MaxPlayers = 4
f.reject_write = next_session
local applied_before = Mod.State.applied
f.call(f.hooks.map)
f.reject_write = nil
check(Mod.State.applied == applied_before, "a rejected write must not count as applied")
check(next_session.__values.MaxPlayers == 4, "a rejected write must leave the value alone")

f.ignore_write = next_session
applied_before = Mod.State.applied
f.call(f.hooks.map)
f.ignore_write = nil
check(Mod.State.applied == applied_before, "a write that silently does not stick must not count as applied")
check(f.logged("write did not stick") or f.logged("not writable"),
    "a failed write must leave a diagnosable trace in the log")

--------------------------------------------------------------------------------
-- Diagnostics: queued onto the game thread, and honest about what it sees.
--------------------------------------------------------------------------------

next_session.__values.MaxPlayers = 4
f.ignore_write = next_session
f.logs = {}
f.hooks.key()
check(#f.queue == 1, "F10 must queue diagnostics onto the game thread")
f.flush()
f.ignore_write = nil
check(f.logged("MaxPlayers = 4"), "diagnostics must report the effective cap it observed")
check(next_session.__values.MaxPlayers == 4, "diagnostics must not conceal state it could not repair")

--------------------------------------------------------------------------------
-- config.ini: Windows paths, a BOM, and trailing comments.
--------------------------------------------------------------------------------

local windows = fixture("\239\187\191MaxPlayers = 12 ; friends\r\nLogLevel = INFO\r\n")
windows.registry = {GameSession = {}, GameModeBase = {}, GameStateBase = {}}
local WinMod = windows.load()
check(WinMod.TargetMaxPlayers == 12,
    "a BOM and a trailing comment must not silently fall back to the default cap")

local clamped = fixture("MaxPlayers = 99\n")
clamped.registry = {GameSession = {}, GameModeBase = {}, GameStateBase = {}}
check(clamped.load().TargetMaxPlayers == 24, "an out-of-range cap must clamp to HardUpperLimit")

local fractional = fixture("MaxPlayers = 8.5\n")
fractional.registry = {GameSession = {}, GameModeBase = {}, GameStateBase = {}}
check(fractional.load().TargetMaxPlayers == 8, "a fractional cap must resolve to a whole number")

--------------------------------------------------------------------------------
-- A reduced UE4SS API must degrade to fewer triggers, and be loud when it has none.
--------------------------------------------------------------------------------

local reduced, reduced_env = fixture()
reduced.registry = {GameSession = {reduced.session("BP_RideGameSession_C", 4)}, GameModeBase = {}, GameStateBase = {}}
reduced_env.LoopAsync = nil
reduced_env.RegisterBeginPlayPostHook = nil
reduced_env.RegisterConsoleCommandHandler = nil
local ReducedMod = reduced.load()
check(next(ReducedMod.State.triggers) ~= nil, "a reduced UE4SS API must still install the remaining triggers")
check(#reduced.loops == 0, "a missing LoopAsync must not be called")
reduced.flush()
check(reduced.registry.GameSession[1].__values.MaxPlayers == 8,
    "the cap must still be applied with a reduced UE4SS API")

local bare, bare_env = fixture()
bare.registry = {GameSession = {}, GameModeBase = {}, GameStateBase = {}}
for _, name in ipairs({"NotifyOnNewObject", "RegisterLoadMapPostHook", "RegisterHook",
                       "RegisterBeginPlayPostHook", "LoopAsync",
                       "RegisterConsoleCommandHandler", "RegisterKeyBind"}) do
    bare_env[name] = nil
end
bare.load()
check(bare.logged("No triggers could be installed"),
    "a UE4SS build exposing no usable API must say so loudly rather than appear to work")

print("PASS: " .. checks .. " assertions; session lifecycle verified in UE4SS stubs")
