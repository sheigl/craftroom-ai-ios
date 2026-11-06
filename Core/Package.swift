// swift-tools-version:5.9
import PackageDescription

// CraftRoomCore — the platform-independent half of the harness: the
// `canny_edge_v1` preprocessing recipe, the baked Euler scheduler, the
// device-v2 payload manifest and the spatial (resize/pad/crop) rules.
//
// Everything here is pure Swift + Foundation so the same code runs in the app
// (iOS 17) and under `swift test` on the macOS CI runner and on Linux, which
// is where the parity fixtures are checked.
let package = Package(
    name: "CraftRoomCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CraftRoomCore", targets: ["CraftRoomCore"]),
    ],
    targets: [
        .target(
            name: "CraftRoomCore",
            resources: [
                // device-v2 payload manifest + the baked 30-step Euler schedule:
                // single copies shared by the app (through this package) and the
                // tests, both generated on the Linux box.
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CraftRoomCoreTests",
            dependencies: ["CraftRoomCore"],
            resources: [
                // Canny parity fixtures (inputs + expected `canny_edge_v1`
                // masks) and the scheduler golden, both generated on the
                // Linux box by sdxl/teacher/device_v2/.
                .copy("Fixtures"),
            ]
        ),
    ]
)
