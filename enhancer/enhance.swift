import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Usage check
guard CommandLine.arguments.count > 2 else {
    print("Usage: enhance <input_path> <output_path> [quality]")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let quality = CommandLine.arguments.count > 3 ? (Float(CommandLine.arguments[3]) ?? 0.95) : 0.95

let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = URL(fileURLWithPath: outputPath)

guard let ciImage = CIImage(contentsOf: inputURL) else {
    fputs("Error: Could not load image at \(inputPath)\n", stderr)
    exit(1)
}

// MARK: - Native Apple Photos Auto Enhancement
// Obtains Apple's native CoreImage auto-adjustment filters
// (exposure, contrast, color balance, shadow/highlight tone curves)
let options: [CIImageAutoAdjustmentOption: Any] = [
    .enhance: true,
    .redEye: false
]
let filters = ciImage.autoAdjustmentFilters(options: options)

var currentImage = ciImage
for filter in filters {
    filter.setValue(currentImage, forKey: kCIInputImageKey)
    if let result = filter.outputImage {
        currentImage = result
    }
}

// Render using software/hardware rendering context
let context = CIContext(options: nil)
guard let cgImage = context.createCGImage(currentImage, from: currentImage.extent) else {
    fputs("Error: Could not render output image\n", stderr)
    exit(1)
}

// Save output with requested compression quality
let ext = outputURL.pathExtension.lowercased()
let uti: CFString = (ext == "png") ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString

guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, uti, 1, nil) else {
    fputs("Error: Could not create image destination at \(outputPath)\n", stderr)
    exit(1)
}

let properties: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: quality
]
CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

if CGImageDestinationFinalize(destination) {
    print("OK")
} else {
    fputs("Error: Failed to write image\n", stderr)
    exit(1)
}
