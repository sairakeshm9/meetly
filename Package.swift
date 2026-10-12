// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingAssist",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MeetingAssist", targets: ["MeetingAssist"])],
    targets: [
        .target(name: "MeetingCore"),
        .executableTarget(name: "MeetingAssist", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingAppTests", dependencies: ["MeetingAssist"]),
    ],
    swiftLanguageModes: [.v5]
)
