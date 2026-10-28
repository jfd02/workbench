// swift-tools-version: 5.9
import PackageDescription

// Code shared by the Mac app and the iPhone app: the wire protocol between
// them, and the terminal bookkeeping both ends have to agree on.
let package = Package(
    name: "TabTermKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TabTermKit", targets: ["TabTermKit"]),
    ],
    targets: [
        .target(name: "TabTermKit"),
        .testTarget(name: "TabTermKitTests", dependencies: ["TabTermKit"]),
    ]
)
