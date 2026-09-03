// swift-tools-version: 5.9
import PackageDescription

// AlarmyCore is deliberately free of UIKit / SwiftUI / AlarmKit so that the
// scheduling, state-machine and mission logic can be unit tested on any
// platform, and so the alarm rules are provably correct independent of iOS.
let package = Package(
    name: "AlarmyCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "AlarmyCore", targets: ["AlarmyCore"])
    ],
    targets: [
        .target(name: "AlarmyCore"),
        .testTarget(name: "AlarmyCoreTests", dependencies: ["AlarmyCore"])
    ]
)
