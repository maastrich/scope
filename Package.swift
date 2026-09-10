// swift-tools-version: 6.0
import PackageDescription

// ScopeKit — the Foundation-only core of Scope, shared by the app and by the
// `scope-hook` helper. SwiftTerm and AppKit stay in the app target (project.yml)
// so `swift test` never compiles a terminal emulator.
let package = Package(
    name: "ScopeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScopeCore", targets: ["ScopeCore"]),
        .library(name: "ScopeGit", targets: ["ScopeGit"]),
        .library(name: "ScopeDrivers", targets: ["ScopeDrivers"]),
        .library(name: "ScopeAdapters", targets: ["ScopeAdapters"]),
        .library(name: "ScopeTasks", targets: ["ScopeTasks"]),
        .library(name: "ScopeGraph", targets: ["ScopeGraph"]),
        .library(name: "ScopeControl", targets: ["ScopeControl"]),
        .executable(name: "scope-hook", targets: ["scope-hook"]),
        .executable(name: "scope", targets: ["scope"]),
    ],
    dependencies: [
        // The official MCP SDK, used by `scope mcp` only. It is the package's one external dependency;
        // `swift build` fetches it once and every other target stays offline.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "ScopeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ScopeGit",
            dependencies: ["ScopeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ScopeDrivers",
            dependencies: ["ScopeCore", "ScopeAdapters"],
            resources: [.copy("Builtin")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ScopeAdapters",
            dependencies: ["ScopeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ScopeControl",
            dependencies: ["ScopeCore", "ScopeAdapters"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ScopeTasks",
            dependencies: ["ScopeCore", "ScopeGit", "ScopeDrivers"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ScopeGraph",
            dependencies: ["ScopeCore", "ScopeGit", "ScopeDrivers", "ScopeTasks"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "scope",
            dependencies: ["ScopeControl", .product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "scope-hook",
            dependencies: ["ScopeAdapters"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ScopeKitTests",
            dependencies: ["ScopeCore", "ScopeGit", "ScopeDrivers", "ScopeAdapters", "ScopeTasks", "ScopeGraph", "ScopeControl"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
