// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Paella",
    platforms: [.macOS(.v14)],
    products: [
        // Used by the Xcode app target (Paella.xcodeproj).
        .library(name: "PaellaCore", targets: ["PaellaCore"]),
        .executable(name: "Paella", targets: ["Paella"]),
    ],
    targets: [
        // Private IOKit HID event-system declarations (SwiftPM has no bridging headers).
        .target(name: "CHIDPrivate", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "PaellaCore", dependencies: ["CHIDPrivate"]),
        .executableTarget(name: "Paella", dependencies: ["PaellaCore"]),
        .testTarget(name: "PaellaCoreTests", dependencies: ["PaellaCore"]),
    ]
)
