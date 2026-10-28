// swift-tools-version: 5.9
import PackageDescription

// `workbench`: Workbench's terminals, from another Mac's terminal. It is one more
// client of the protocol the iPhone app speaks, so it needs TabTermKit and
// nothing else — no libghostty, no AppKit — and builds in seconds on a Mac
// that has never built the app.
let package = Package(
    name: "workbench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "workbench", targets: ["tabterm"]),
        // Keep existing scripts working after the rename.
        .executable(name: "tabterm", targets: ["tabterm"]),
    ],
    dependencies: [
        .package(path: "../TabTermKit"),
    ],
    targets: [
        .executableTarget(
            name: "tabterm",
            dependencies: [.product(name: "TabTermKit", package: "TabTermKit")],
            path: "Sources/tabterm"
        ),
        .testTarget(
            name: "tabtermTests",
            dependencies: ["tabterm", .product(name: "TabTermKit", package: "TabTermKit")],
            path: "Tests/tabtermTests"
        ),
    ]
)
