// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SARAKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SARACore", targets: ["SARACore"]),
        .library(name: "SARAKit", targets: ["SARAKit"]),
        .library(name: "SARATesting", targets: ["SARATesting"]),
    ],
    targets: [
        .target(
            name: "SARACore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SARAKit",
            dependencies: ["SARACore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SARATesting",
            dependencies: ["SARACore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SARACoreTests",
            dependencies: ["SARACore", "SARATesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SARAKitTests",
            dependencies: ["SARAKit", "SARATesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
