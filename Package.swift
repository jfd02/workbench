// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TabTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // libghostty, built from source. See scripts/build-ghostty.sh.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),

        .executableTarget(
            name: "TabTerm",
            dependencies: [
                "GhosttyKit",
                .product(name: "GRDB", package: "GRDB.swift"),
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
                .linkedFramework("WebKit"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
