// GENERATED from shared/hl-prelude.lua by scripts/sync-prelude.sh. Edit that file instead.

/// Lua code loaded before a Hyprland Lua config: defines `hl` and records calls as hyprlang text.
let prelude = #"""
-- hyprmac / hyprwin: Hyprland Lua API shim (hl.*).
-- Loaded before a Hyprland Lua config (hyprland.lua). It records hl.* calls as hyprlang text
-- that the normal config parser understands; function binds and hl.on handlers stay in Lua.
-- Shared by macOS (Sources/HyprLua/Prelude.swift, generated) and Windows (embedded resource).
-- After editing: ./scripts/sync-prelude.sh
local hm = {
    conf = {}, callables = {}, startcmds = {}, handlers = {}, files = {}, flat = {},
    loading = true,
}
__hm = hm

local function host(op, arg)
    if __hm_host then return __hm_host(op, arg or "") end
    return nil
end

local function add(line) hm.conf[#hm.conf + 1] = line end
-- '#' starts a comment in hyprlang; '##' is a literal '#'. Newlines can't appear in a line.
local function esc(s) return (tostring(s):gsub("#", "##"):gsub("\n", " ")) end

local GAP = { top = true, right = true, bottom = true, left = true }
local function isgaps(t)
    if type(t) ~= "table" or next(t) == nil then return false end
    for k in pairs(t) do if not GAP[k] then return false end end
    return true
end

local function scalar(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "table" then
        if isgaps(v) then
            return string.format("%s %s %s %s", v.top or 0, v.right or 0, v.bottom or 0, v.left or 0)
        end
        local parts = {}
        for i, x in ipairs(v) do parts[i] = tostring(x) end
        return table.concat(parts, " ")
    end
    return tostring(v)
end

local function flatten(prefix, t)
    -- Sorted so the generated text is stable.
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = t[k]
        local key = prefix == "" and tostring(k) or (prefix .. ":" .. tostring(k))
        if type(v) == "table" and not isgaps(v) and #v == 0 then
            flatten(key, v)
        else
            key = key:gsub(":col:", ":col.")  -- general:col:active_border -> general:col.active_border
            hm.flat[key] = v
            if hm.loading then add(key .. " = " .. esc(scalar(v))) end
        end
    end
end

local DEFAULTS = { ["cursor:zoom_factor"] = 1.0 }

local function D(d, a) return { __dsp = true, d = d, a = a and tostring(a) or "" } end
local DIRS = { left = "l", right = "r", up = "u", down = "d", l = "l", r = "r", u = "u", d = "d",
               top = "u", bottom = "d" }
local function unsupported(name)
    return function() return D("unsupported", name) end
end

local dsp = {}
dsp.exec_cmd = function(cmd) return D("exec", cmd) end
dsp.exec = dsp.exec_cmd
dsp.exit = function() return D("exit") end
dsp.focus = function(o)
    o = o or {}
    if o.workspace ~= nil then return D("workspace", o.workspace) end
    if o.direction ~= nil then return D("movefocus", DIRS[o.direction] or o.direction) end
    if o.monitor ~= nil then return D("focusmonitor", o.monitor) end
    return D("unsupported", "focus")
end
dsp.workspace = function(o)
    if type(o) == "table" then return D("workspace", o.workspace or o.id or o[1]) end
    return D("workspace", o)
end
dsp.window = {}
dsp.window.close = function() return D("killactive") end
dsp.window.kill = dsp.window.close
dsp.window.fullscreen = function(o) return D("fullscreen", (o or {}).mode or 0) end
dsp.window.float = function(o)
    local a = (o or {}).action
    if a == "enable" or a == "on" or a == "set" or a == true then return D("setfloating") end
    if a == "disable" or a == "off" or a == "unset" or a == false then return D("settiled") end
    return D("togglefloating")
end
dsp.window.center = function() return D("centerwindow") end
dsp.window.move = function(o)
    o = o or {}
    if o.workspace ~= nil then
        return D(o.silent and "movetoworkspacesilent" or "movetoworkspace", o.workspace)
    end
    if o.direction ~= nil then return D("movewindow", DIRS[o.direction] or o.direction) end
    if o.x ~= nil or o.y ~= nil then
        return D("moveactive", (o.relative == false and "exact " or "") .. (o.x or 0) .. " " .. (o.y or 0))
    end
    return D("unsupported", "window.move")
end
dsp.window.swap = function(o) return D("swapwindow", DIRS[(o or {}).direction] or "") end
dsp.window.resize = function(o)
    if o == nil then return D("mouse", "window.resize") end
    return D("resizeactive", (o.relative == false and "exact " or "") .. (o.x or 0) .. " " .. (o.y or 0))
end
dsp.window.drag = function() return D("mouse", "window.drag") end
dsp.window.cycle = function(o) return D("cyclenext", (o or {}).prev and "prev" or "") end
dsp.layout = function(msg) return D("layoutmsg", msg) end
setmetatable(dsp, { __index = function(_, k) return unsupported(tostring(k)) end })
setmetatable(dsp.window, { __index = function(_, k) return unsupported("window." .. tostring(k)) end })

local MODS = { SUPER = "SUPER", WIN = "SUPER", LOGO = "SUPER", MOD4 = "SUPER", META = "SUPER", CMD = "SUPER",
               SHIFT = "SHIFT", ALT = "ALT", MOD1 = "ALT", OPT = "ALT", OPTION = "ALT",
               CTRL = "CTRL", CONTROL = "CTRL" }

local function store(callable)
    hm.callables[#hm.callables + 1] = callable
    return #hm.callables
end

hl = {}
hl.dsp = dsp

function hl.config(t)
    if type(t) ~= "table" then error("hl.config expects a table", 2) end
    flatten("", t)
end

function hl.get_config(key)
    local v = hm.flat[key]
    if v == nil then v = DEFAULTS[key] end
    return v
end

function hl.bind(keys, action, opts)
    if type(keys) ~= "string" then error("hl.bind: keys must be a string", 2) end
    local mods, key = {}, nil
    for tok in keys:gmatch("[^+]+") do
        tok = tok:match("^%s*(.-)%s*$")
        if tok ~= "" then
            local m = MODS[tok:upper()]
            if m then mods[#mods + 1] = m else key = tok end
        end
    end
    if not key then error("hl.bind: no key in '" .. keys .. "'", 2) end
    opts = opts or {}
    local m = table.concat(mods, " ")
    if opts.mouse or key:lower():find("^mouse") then
        add("bindm = " .. m .. ", " .. key .. ", ignored")
        return
    end
    if type(action) == "function" then
        add(string.format("bind = %s, %s, lua, %d", m, key, store(action)))
        return
    end
    if type(action) == "string" then action = D("exec", action) end
    if type(action) ~= "table" or not action.__dsp then
        error("hl.bind: action must be an hl.dsp.* value or a function", 2)
    end
    if action.d == "exec" and (action.a:find("\n") or action.a:find("#")) then
        -- Multi-line scripts don't fit on one hyprlang line: keep them in Lua.
        add(string.format("bind = %s, %s, lua, %d", m, key, store(action.a)))
        return
    end
    add(string.format("bind = %s, %s, %s, %s", m, key, action.d, esc(action.a)))
end

function hl.dispatch(action)
    if type(action) == "string" then action = D("exec", action) end
    if type(action) ~= "table" or not action.__dsp then error("hl.dispatch: expected hl.dsp.* value", 2) end
    if action.d == "exec" then return host("exec", action.a) end
    return host("dispatch", action.d .. "\t" .. action.a)
end

function hl.exec_cmd(cmd)
    if hm.loading then hm.startcmds[#hm.startcmds + 1] = cmd else host("exec", cmd) end
end

function hl.on(event, fn)
    if type(fn) ~= "function" then error("hl.on: handler must be a function", 2) end
    hm.handlers[event] = hm.handlers[event] or {}
    table.insert(hm.handlers[event], fn)
end

local function fromhost(op)
    local src = host(op, "")
    if not src then return nil end
    local f = load(src, "=" .. op, "t", {})
    return f and f() or nil
end
function hl.get_active_window() return fromhost("activewindow") end
function hl.get_active_monitor() return fromhost("activemonitor") end
function hl.get_active_workspace() return fromhost("activeworkspace") end

local SUPPORTED_RULE = { float = "float", tile = "tile", center = "center", fullscreen = "fullscreen",
                         maximize = "maximize" }
function hl.window_rule(t)
    if type(t) ~= "table" then error("hl.window_rule expects a table", 2) end
    local match = {}
    for k, v in pairs(t.match or {}) do
        if k == "class" or k == "title" or k == "initial_class" or k == "initial_title" then
            match[#match + 1] = k:gsub("_", "") .. ":" .. tostring(v)
        else
            add("windowrule:match_" .. tostring(k) .. " = lua")  -- e.g. match on fullscreen state
            return
        end
    end
    if #match == 0 then return end
    table.sort(match)
    local m = table.concat(match, ", ")
    for k, v in pairs(t) do
        if k ~= "match" and k ~= "name" then
            if SUPPORTED_RULE[k] and v == true then
                add("windowrulev2 = " .. SUPPORTED_RULE[k] .. ", " .. esc(m))
            elseif k == "size" then
                add("windowrulev2 = size " .. scalar(v) .. ", " .. esc(m))
            elseif k == "workspace" then
                add("windowrulev2 = workspace " .. scalar(v) .. ", " .. esc(m))
            else
                add("windowrule:" .. tostring(k) .. " = lua")
            end
        end
    end
end

-- Accepted, no macOS meaning.
local IGNORED = { monitor = "monitor", workspace_rule = "workspace", layer_rule = "layerrule",
                  curve = "bezier", animation = "animation", env = "env", gesture = "gesture",
                  permission = "permission", plugin = "plugin", device = "device" }
for name, key in pairs(IGNORED) do
    hl[name] = function() add(key .. " = lua") end
end
setmetatable(hl, { __index = function(_, k)
    return function() add("hyprmac:lua_unsupported = hl." .. tostring(k)) end
end })

-- Track files the config reads so hyprmac reloads when they change.
local _require, _dofile = require, dofile
require = function(name)
    local p = package.searchpath(name, package.path)
    if p then hm.files[#hm.files + 1] = p end
    return _require(name)
end
dofile = function(p)
    if p then hm.files[#hm.files + 1] = p end
    return _dofile(p)
end

function hm.export()
    hm.loading = false
    return table.concat(hm.conf, "\n") .. "\n"
end
function hm.filelist() return table.concat(hm.files, "\n") end

-- Run a stored bind: a function or a multi-line shell command.
function hm.call(n)
    local c = hm.callables[tonumber(n)]
    if type(c) == "string" then
        host("exec", c)
    elseif type(c) == "function" then
        local ok, err = pcall(c)
        if not ok then host("log", "bind function failed: " .. tostring(err)) end
    end
end

function hm.emit(event)
    if event == "hyprland.start" then
        for _, c in ipairs(hm.startcmds) do host("exec", c) end
    end
    for _, fn in ipairs(hm.handlers[event] or {}) do
        local ok, err = pcall(fn)
        if not ok then host("log", event .. " handler failed: " .. tostring(err)) end
    end
end
"""#
