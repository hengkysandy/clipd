// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipdCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClipdCore", targets: ["ClipdCore"])
    ],
    targets: [
        // No AppKit dependency, deliberately. Every decision this app makes
        // must be answerable without a clipboard, a permission or a running
        // app, so the tests run in a fraction of a second with no simulator.
        .target(name: "ClipdCore"),
        .testTarget(name: "ClipdCoreTests", dependencies: ["ClipdCore"])
    ]
)
