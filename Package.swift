// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Workbench", targets: ["TabTerm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // The wire protocol and terminal bookkeeping shared with the iPhone app.
        .package(path: "TabTermKit"),
    ],
    targets: [
        // libghostty, built from source. See scripts/build-ghostty.sh.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),

        // Spawning a shell on a pty: the part that has to happen between fork
        // and exec, where Swift can't safely run.
        .target(
            name: "CTabTermPTY",
            path: "Sources/CTabTermPTY"
        ),

        .executableTarget(
            name: "TabTerm",
            dependencies: [
                "GhosttyKit",
                "CTabTermPTY",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TabTermKit", package: "TabTermKit"),
            ],
            path: "Sources/TabTerm",
            linkerSettings: [
                // libghostty is a static archive, so every system framework it
                // references has to be resolved here at final link time.
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ColorSync"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(name: "WorkbenchTests", dependencies: ["TabTerm"], path: "Tests/WorkbenchTests"),
    ]
)
