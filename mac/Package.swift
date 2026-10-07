// swift-tools-version:6.2
import PackageDescription

// Builds with Xcode 27 (Swift 6.4); runs on macOS 26 and later. No external dependencies.
let package = Package(
    name: "GelScribe",
    platforms: [.macOS("26.0")],
    targets: [
        // Image loading, lane/band detection, figure layout and PDF/PNG/SVG rendering.
        // Shared by the app and the CLI so both produce identical figures.
        .target(name: "GelKit"),
        // Model Context Protocol server core (JSON-RPC, stdio + localhost HTTP transports). Knows nothing about gels.
        .target(name: "GelMCP"),
        // The LLM-facing tool surface: GelKit operations exposed as MCP tools over a ProjectHost
        // (files on disk for the CLI, live documents for the app).
        .target(name: "GelService", dependencies: ["GelKit", "GelMCP"]),
        .executableTarget(name: "gelscribe", dependencies: ["GelKit", "GelMCP", "GelService"]),
        .executableTarget(
            name: "GelScribeApp",
            dependencies: ["GelKit", "GelMCP", "GelService"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "GelKitTests", dependencies: ["GelKit"], path: "Tests/GelKitTests"),
        // The MCP transports and the LLM tools (the tools run over files on disk here).
        .testTarget(name: "GelMCPTests", dependencies: ["GelMCP", "GelService", "GelKit"], path: "Tests/GelMCPTests"),
        // The app's own logic, run without launching it: the Workspace (what the Figure and gel views show, the gels' own settings)
        // and the canvas, driven with mouse events on an offscreen window.
        .testTarget(name: "GelScribeAppTests", dependencies: ["GelScribeApp", "GelKit"], path: "Tests/GelScribeAppTests"),
    ]
)
