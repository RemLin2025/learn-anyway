// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Braincell",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Braincell", targets: ["BraincellApp"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        // Pure domain + persistence + services. Must never import SwiftUI/AppKit.
        .target(
            name: "BraincellCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/BraincellCore"
        ),
        // SwiftUI shell. Swift 5 mode: SwiftUI + @Observable ergonomics; Core stays Swift 6.
        .executableTarget(
            name: "BraincellApp",
            dependencies: ["BraincellCore"],
            path: "Sources/BraincellApp",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BraincellCoreTests",
            dependencies: ["BraincellCore"],
            path: "Tests/BraincellCoreTests"
        ),
    ]
)
