import CLua
import Foundation
import HyprmacCore

/// One Lua state running a Hyprland Lua config.
public final class LuaRuntime {
    let L: OpaquePointer

    /// Called from Lua for `exec`, `dispatch`, `activewindow`, `activemonitor`, `log`.
    /// Returns a string for Lua (or nil).
    var host: ((String, String) -> String?)?

    private static var byState: [OpaquePointer: LuaRuntime] = [:]

    init() throws {
        guard let L = luaL_newstate() else { throw LuaError("cannot create Lua state") }
        self.L = L
        luaL_openlibs(L)
        LuaRuntime.byState[L] = self
        hm_register(L, "__hm_host", { L in
            guard let L, let rt = LuaRuntime.byState[L] else { return 0 }
            let op = hm_tostring(L, 1).map { String(cString: $0) } ?? ""
            let arg = hm_tostring(L, 2).map { String(cString: $0) } ?? ""
            if let reply = rt.host?(op, arg) {
                _ = lua_pushstring(L, reply)
            } else {
                lua_pushnil(L)
            }
            return 1
        })
        _ = try run(prelude, chunk: "=hyprmac-prelude")
    }

    deinit {
        LuaRuntime.byState[L] = nil
        lua_close(L)
    }

    /// Runs code; returns its first result as a string (nil when it returns nothing/nil).
    @discardableResult
    func run(_ code: String, chunk: String) throws -> String? {
        let status = hm_dostring(L, code, chunk)
        defer { hm_pop(L, 1) }
        let top = hm_tostring(L, -1).map { String(cString: $0) }
        guard status == LUA_OK else { throw LuaError(top ?? "Lua error \(status)") }
        return top
    }

    /// Lua string literal for any Swift string.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.utf8 {
            switch u {
            case UInt8(ascii: "\\"): out += "\\\\"
            case UInt8(ascii: "\""): out += "\\\""
            case 32...126: out += String(UnicodeScalar(u))
            default: out += String(format: "\\%03d", u)  // 3 digits: next char can't extend it
            }
        }
        return out + "\""
    }
}

struct LuaError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Glue between hyprmac and Lua configs.
public enum LuaConfig {
    /// Runtimes from the latest config load, by id. Bind args look like "<id>:<n>".
    private static var runtimes: [Int: LuaRuntime] = [:]
    private static var nextID = 1

    /// Handles calls from Lua configs at run time (set by the window manager).
    public static var host: ((String, String) -> String?)? {
        didSet { for rt in runtimes.values { rt.host = host } }
    }

    /// Makes `source = x.lua` and `hyprmac --config x.lua` work.
    public static func install() {
        ConfigParser.luaLoader = { path in load(path) }
    }

    /// Drops runtimes from an earlier load. Call before reloading the config.
    public static func reset() {
        runtimes.removeAll()
    }

    static func load(_ path: String) -> (text: String, files: [String], error: String?) {
        let rt: LuaRuntime
        do {
            rt = try LuaRuntime()
        } catch {
            return ("", [], "\(error)")
        }
        let id = nextID
        nextID += 1
        runtimes[id] = rt
        rt.host = host

        let dir = (path as NSString).deletingLastPathComponent
        var loadError: String?
        do {
            try rt.run("package.path = \(LuaRuntime.quote(dir + "/?.lua;")) .. package.path", chunk: "=setup")
            try rt.run("__hm.loading = true; dofile(\(LuaRuntime.quote(path)))", chunk: "=" + (path as NSString).lastPathComponent)
        } catch {
            loadError = "\(error)"
        }
        var text = (try? rt.run("return __hm.export()", chunk: "=export")) ?? ""
        // Function binds point at this runtime.
        text = text.replacingOccurrences(of: ", lua, ", with: ", lua, \(id):")
        let files = ((try? rt.run("return __hm.filelist()", chunk: "=files")) ?? "")
            .split(separator: "\n").map { ConfigParser.expand(String($0)) }
        return (text, files, loadError)
    }

    /// Runs a stored bind ("<runtime>:<n>").
    public static func call(_ arg: String) {
        let parts = arg.split(separator: ":")
        guard parts.count == 2, let id = Int(parts[0]), let rt = runtimes[id], let n = Int(parts[1]) else { return }
        _ = try? rt.run("__hm.call(\(n))", chunk: "=bind")
    }

    /// The shell command behind a stored bind, if it is one (not a function).
    public static func storedCommand(_ arg: String) -> String? {
        let parts = arg.split(separator: ":")
        guard parts.count == 2, let id = Int(parts[0]), let rt = runtimes[id], let n = Int(parts[1]) else { return nil }
        return try? rt.run("local c = __hm.callables[\(n)]; if type(c) == 'string' then return c end", chunk: "=cmd")
    }

    /// Fires `hl.on(event, ...)` handlers; "hyprland.start" also runs top-level hl.exec_cmd calls.
    public static func emit(_ event: String) {
        for id in runtimes.keys.sorted() {
            _ = try? runtimes[id]?.run("__hm.emit(\(LuaRuntime.quote(event)))", chunk: "=emit")
        }
    }

    /// Builds a Lua table literal (`return {...}`) for get_active_window and friends.
    public static func table(_ fields: [String: Any]) -> String {
        func lit(_ v: Any) -> String {
            switch v {
            case let b as Bool: return b ? "true" : "false"
            case let i as Int: return String(i)
            case let d as Double: return String(d)
            case let s as String: return LuaRuntime.quote(s)
            default: return "nil"
            }
        }
        let body = fields.keys.sorted().map { "[\(LuaRuntime.quote($0))]=\(lit(fields[$0]!))" }.joined(separator: ",")
        return "return {\(body)}"
    }
}
