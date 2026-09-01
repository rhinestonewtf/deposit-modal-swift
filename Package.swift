// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RhinestoneDepositModal",
    // macOS is here for the tests, not for a product: the bridge core is free
    // of WebKit and UIKit so `swift test` runs the whole contract on a laptop,
    // which is the same split the React Native wrapper makes.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "RhinestoneDepositModal", targets: ["RhinestoneDepositModal"])
    ],
    targets: [
        .target(name: "RhinestoneDepositModal"),
        .testTarget(
            name: "RhinestoneDepositModalTests",
            dependencies: ["RhinestoneDepositModal"],
            resources: [.copy("Resources/bridge-transcript.json")]
        ),
    ]
)
