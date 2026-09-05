// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProxyManClone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrafficModel", targets: ["TrafficModel"]),
        .library(name: "CertKit", targets: ["CertKit"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
        .executable(name: "ProxyManCloneApp", targets: ["ProxyManCloneApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.1.0"),
    ],
    targets: [
        .target(name: "TrafficModel"),
        .target(name: "CertKit", dependencies: [
            "TrafficModel",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .target(name: "ProxyCore", dependencies: [
            "TrafficModel", "CertKit",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "AppCore", dependencies: [
            "TrafficModel", "CertKit", "ProxyCore",
        ]),
        .executableTarget(name: "ProxyManCloneApp", dependencies: [
            "AppCore",
        ]),
        .testTarget(name: "TrafficModelTests", dependencies: ["TrafficModel"]),
        .testTarget(name: "AppTests", dependencies: ["AppCore", "TrafficModel"]),
        .testTarget(name: "CertKitTests", dependencies: [
            "CertKit",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .testTarget(name: "ProxyCoreTests", dependencies: [
            "ProxyCore",
            "TrafficModel",
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
    ]
)
