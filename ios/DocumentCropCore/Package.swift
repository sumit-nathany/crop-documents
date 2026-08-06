// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DocumentCropCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "DocumentCropCore", targets: ["DocumentCropCore"])
    ],
    targets: [
        .target(name: "DocumentCropCore")
    ]
)
