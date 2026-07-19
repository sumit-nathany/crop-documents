import Foundation
import Vision
import CoreImage

// MARK: - Output structure

struct Corner: Codable {
    let x: Double
    let y: Double
}

struct DetectionResult: Codable {
    let corners: [Corner]?
    let confidence: Float?
    let error: String?
}

func output(_ result: DetectionResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    if let data = try? encoder.encode(result),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

// MARK: - Entry point

guard CommandLine.arguments.count > 1 else {
    output(DetectionResult(corners: nil, confidence: nil, error: "Usage: detect <image_path>"))
    exit(1)
}

let imagePath = CommandLine.arguments[1]
let imageURL = URL(fileURLWithPath: imagePath)

guard FileManager.default.fileExists(atPath: imagePath) else {
    output(DetectionResult(corners: nil, confidence: nil, error: "File not found: \(imagePath)"))
    exit(1)
}

guard let ciImage = CIImage(contentsOf: imageURL) else {
    output(DetectionResult(corners: nil, confidence: nil, error: "Could not load image: \(imagePath)"))
    exit(1)
}

// MARK: - Vision request

let request = VNDetectDocumentSegmentationRequest()

let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])

do {
    try handler.perform([request])
} catch {
    output(DetectionResult(corners: nil, confidence: nil, error: "Vision request failed: \(error.localizedDescription)"))
    exit(1)
}

guard let observation = request.results?.first else {
    output(DetectionResult(corners: nil, confidence: nil, error: "No document detected"))
    exit(0)
}

// MARK: - Extract corners
// Vision uses normalized coordinates with origin at BOTTOM-LEFT.
// We preserve this convention and let Python handle the flip.
// Order: topLeft, topRight, bottomRight, bottomLeft (clockwise)

let corners = [
    Corner(x: Double(observation.topLeft.x),     y: Double(observation.topLeft.y)),
    Corner(x: Double(observation.topRight.x),    y: Double(observation.topRight.y)),
    Corner(x: Double(observation.bottomRight.x), y: Double(observation.bottomRight.y)),
    Corner(x: Double(observation.bottomLeft.x),  y: Double(observation.bottomLeft.y)),
]

output(DetectionResult(corners: corners, confidence: observation.confidence, error: nil))
