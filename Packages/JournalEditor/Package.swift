// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JournalEditor",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "JournalEditor", targets: ["JournalEditor"]),
    ],
    dependencies: [
        .package(path: "../JournalCore"),
    ],
    targets: [
        // Swift 5 mode, because Apple's text system predates Swift 6's stricter concurrency rules.
        .target(name: "JournalEditor", dependencies: ["JournalCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "JournalEditorTests", dependencies: ["JournalEditor"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
