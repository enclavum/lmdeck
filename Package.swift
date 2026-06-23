// swift-tools-version:6.0
import PackageDescription

// NOTE: tools-version is 6.0, but every target deliberately pins `.swiftLanguageMode(.v5)` —
// lenient Sendable checking (data-race issues are warnings, not errors) rather than strict Swift 6
// concurrency. Concurrency correctness is reasoned about by hand (see ServerController / DiscoveryCache).

let package = Package(
    name: "LMDeck",
    platforms: [.macOS(.v15)],
    products: [
        // Exposing the core as a library product gives it its own Xcode scheme, which is what
        // SwiftUI previews need (previews can't run against the executable target).
        .library(name: "LMDeckCore", targets: ["LMDeckCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")
    ],
    targets: [
        // UI + logic live in a library so SwiftUI previews work (an executableTarget can't
        // be previewed without a debug dylib / separate framework).
        .target(
            name: "LMDeckCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird")
            ],
            path: "Sources/LMDeckCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Thin executable: just @main, depends on the core library.
        .executableTarget(
            name: "LMDeck",
            dependencies: ["LMDeckCore"],
            path: "Sources/LMDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LMDeckCoreTests",
            dependencies: ["LMDeckCore"],
            path: "Tests/LMDeckCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
