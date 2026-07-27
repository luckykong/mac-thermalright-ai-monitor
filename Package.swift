// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacTR",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "CThermalSensor",
            path: "Sources/CThermalSensor",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "MacTR",
            dependencies: [
                "CLibUSB",
                "CThermalSensor",
            ],
            path: "Sources/MacTR",
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(
            name: "MacTRTests",
            dependencies: ["MacTR"],
            path: "Tests/MacTRTests"
        ),
    ]
)
