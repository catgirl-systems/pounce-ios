// swift-tools-version: 6.0
import PackageDescription

// Dependencies, kept to the two that save real work:
// - swift-nio-ssh: Apple's SSH protocol implementation (transport, auth,
//   channels), vendored in ../Vendor with RSA added (see VENDORED.md).
// - swift-nio-transport-services: runs NIO on Network.framework, which handles
//   Wi-Fi/cellular handover on iOS and avoids pulling in NIOPosix.
let package = Package(
    name: "PounceCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PounceCore", targets: ["PounceCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(path: "../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "PounceCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        )
    ]
)
