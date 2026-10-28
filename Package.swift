// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MailPilot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MailPilot",
            path: "Sources/MailPilot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
