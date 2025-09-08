// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CTRadioKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v14), .macOS(.v11), .tvOS(.v14), .watchOS(.v6)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "CTRadioKit", targets: ["CTRadioKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/KREANIQS/CTSwiftLogger", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CTRadioKit",
            dependencies: [
                .product(name: "CTSwiftLogger", package: "CTSwiftLogger")
                // Alternativ (wenn Produkt- und Target-Namen exakt "CTSwiftLogger" sind):
                // "CTSwiftLogger"
            ],
            path: "CTRadioKit",
            resources: []
        )
    ]
)
