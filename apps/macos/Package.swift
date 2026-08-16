// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotchAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NotchAgentCore",
            targets: ["NotchAgentCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "NotchAgentCore",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "IPCTests",
            dependencies: ["NotchAgentCore"],
            path: "Tests/IPCTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-L", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
    ]
)
