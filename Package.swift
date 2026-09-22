// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "PowerMeterMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PowerMeterMac", targets: ["PowerMeterApp"]),
        .executable(name: "powermeter", targets: ["PowerMeterCLI"]),
        .executable(name: "PowerMeterSelfTest", targets: ["PowerMeterSelfTest"]),
        .library(name: "PowerMeterCore", targets: ["PowerMeterCore"])
    ],
    targets: [
        .target(name: "CUSB", cSettings: [.headerSearchPath("../../Vendor/libusb")],
                linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]), .linkedLibrary("usb-1.0")]),
        .target(name: "PowerMeterCore", dependencies: ["CUSB"]),
        .executableTarget(name: "PowerMeterApp", dependencies: ["PowerMeterCore"]),
        .executableTarget(name: "PowerMeterCLI", dependencies: ["PowerMeterCore"]),
        .executableTarget(name: "PowerMeterSelfTest", dependencies: ["PowerMeterCore", "CUSB"])
    ]
)
