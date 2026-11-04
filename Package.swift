// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "terminal-googlebook",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "terminal-googlebook", targets: ["TerminalGooglebook"])],
    targets: [
        .target(name: "TerminalGooglebookCore"),
        .target(name: "CPhoneShim"),
        .target(name: "TerminalUI", dependencies: ["CPhoneShim"]),
        .executableTarget(name: "TerminalGooglebook", dependencies: ["TerminalGooglebookCore", "TerminalUI", "CPhoneShim"],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("ImageIO"), .linkedFramework("UniformTypeIdentifiers")]),
        .testTarget(name: "TerminalGooglebookCoreTests", dependencies: ["TerminalGooglebookCore"])
    ],
    swiftLanguageModes: [.v5]
)
