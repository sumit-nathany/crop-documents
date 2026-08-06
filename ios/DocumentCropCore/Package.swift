// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DocumentCropCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "DocumentCropCore", targets: ["DocumentCropCore"]),
        .executable(name: "crop-documents", targets: ["CropDocumentsCLI"]),
    ],
    targets: [
        .target(name: "DocumentCropCore"),
        // Mac front end. Deliberately thin: argument parsing, file walking, and console
        // output only — every pixel decision lives in DocumentCropCore so the CLI and the
        // iOS app cannot drift apart.
        .executableTarget(
            name: "CropDocumentsCLI",
            dependencies: ["DocumentCropCore"]
        ),
        .testTarget(
            name: "DocumentCropCoreTests",
            dependencies: ["DocumentCropCore"]
        ),
    ]
)
