// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxMachineSessions",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxMachineSessions", targets: ["CmuxMachineSessions"]),
        .executable(name: "cmux-machine", targets: ["MachineAttach"])
    ],
    dependencies: [.package(path: "../CmuxFoundation")],
    targets: [
        .target(name: "CmuxMachineSessions", dependencies: ["CmuxFoundation"]),
        .executableTarget(name: "MachineAttach", dependencies: ["CmuxMachineSessions"]),
        .testTarget(name: "CmuxMachineSessionsTests", dependencies: ["CmuxMachineSessions", "CmuxFoundation"])
    ]
)
