// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "hyprmac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hyprmac", targets: ["hyprmac"]),
        .executable(name: "hyprmacctl", targets: ["hyprmacctl"]),
        .library(name: "HyprmacCore", targets: ["HyprmacCore"]),
    ],
    targets: [
        // Pure Swift: no AppKit, no CoreGraphics. Keeps it reusable for the Windows port.
        .target(name: "HyprmacCore"),
        // Lua 5.4.7, vendored unchanged (MIT, see Sources/CLua/LUA_LICENSE).
        .target(
            name: "CLua",
            exclude: ["LUA_LICENSE"],
            cSettings: [
                .define("LUA_USE_MACOSX", .when(platforms: [.macOS])),
                .define("LUA_USE_LINUX", .when(platforms: [.linux])),
                .unsafeFlags(["-w"]),
            ]
        ),
        // Runs Hyprland Lua configs (hyprland.lua, Hyprland 0.5x) through an hl.* shim.
        .target(name: "HyprLua", dependencies: ["CLua", "HyprmacCore"]),
        .executableTarget(name: "hyprmac", dependencies: ["HyprmacCore", "HyprLua"]),
        .executableTarget(name: "hyprmacctl", dependencies: ["HyprmacCore"]),
        .testTarget(name: "HyprmacCoreTests", dependencies: ["HyprmacCore", "HyprLua"]),
    ]
)
