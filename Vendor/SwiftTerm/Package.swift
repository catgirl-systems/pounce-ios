// swift-tools-version:6.0
import PackageDescription

// SwiftTerm v1.20.0, vendored with only the library target: no build plugin,
// no macOS sources, no Metal shaders (see VENDORED.md).
let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .target(
            name: "SwiftTerm", path: "Sources/SwiftTerm",
            // Upstream's warnings aren't ours to fix; keep the app build quiet.
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
