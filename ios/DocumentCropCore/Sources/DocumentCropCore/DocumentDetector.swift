import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

#if canImport(UIKit)
import UIKit
#endif

/// Wraps `VNDetectDocumentSegmentationRequest` — same detector as `detector/detect.swift`.
public enum DocumentDetector {
    public struct Detection: Sendable {
        public let quad: DocumentQuad
        public let confidence: Float
        public let method: String
        public let areaFraction: Double
    }

    /// Detect on the upright bitmap used for warp. Tries several strategies and picks the best.
    /// Available on both platforms — only the JPEG-re-encode last-resort branch needs UIKit, and
    /// that's gated internally so this function itself has no platform-specific dependency.
    public static func detectForCrop(
        upright: CGImage,
        originalData: Data? = nil,
        policy: DetectionPolicy = .platformDefault
    ) throws -> Detection {
        let targetW = upright.width
        let targetH = upright.height
        CropLogger.shared.info("Detect for crop \(targetW)×\(targetH)px")

        var candidates: [Detection] = []

        if let data = originalData, !data.isEmpty {
            if let d = detectFromOriginalFile(data: data, targetWidth: targetW, targetHeight: targetH, policy: policy) {
                candidates.append(d)
            }
            if let d = detectFromImageSource(data: data, targetWidth: targetW, targetHeight: targetH, policy: policy) {
                candidates.append(d)
            }
        }

        if let d = detectOnCIImage(
            CIImage(cgImage: upright),
            detectWidth: targetW,
            detectHeight: targetH,
            targetWidth: targetW,
            targetHeight: targetH,
            method: "upright ci",
            policy: policy
        ) {
            candidates.append(d)
        }

        // Last resort — can mis-detect partial regions on iPhone HEIC; only if nothing else passes.
        if candidates.isEmpty, let jpeg = jpegReencode(upright, quality: 0.98),
           let d = detectFromOriginalFile(
               data: jpeg, targetWidth: targetW, targetHeight: targetH,
               method: "jpeg re-encode", policy: policy
           ) {
            candidates.append(d)
        }

        if let best = pickBest(candidates, targetWidth: targetW, targetHeight: targetH) {
            CropLogger.shared.info(
                String(format: "Picked [%@] confidence=%.3f area=%.0f%%", best.method, best.confidence, best.areaFraction * 100)
            )
            return best
        }

        // Final fallback: axis-aligned rectangle (often works when doc segmentation latches onto a strip).
        CropLogger.shared.info("Trying rectangle fallback")
        if let rect = detectLargestRectangle(
            ciImage: CIImage(cgImage: upright),
            targetWidth: targetW,
            targetHeight: targetH,
            policy: policy
        ) {
            // Refine rectangle quad with doc-seg on the cropped region (Mac-style perspective).
            if let refined = refineDocSegInRegion(
                ciImage: CIImage(cgImage: upright),
                regionQuad: rect.quad,
                targetWidth: targetW,
                targetHeight: targetH,
                policy: policy
            ) {
                CropLogger.shared.info(
                    String(format: "Picked [%@] confidence=%.3f area=%.0f%%", refined.method, refined.confidence, refined.areaFraction * 100)
                )
                return refined
            }
            CropLogger.shared.info(
                String(format: "Picked [%@] confidence=%.3f area=%.0f%%", rect.method, rect.confidence, rect.areaFraction * 100)
            )
            return rect
        }

        CropLogger.shared.warn("All detect strategies rejected (\(candidates.count) doc-seg candidates)")
        throw CropError.noDocumentDetected
    }

    private static func jpegReencode(_ cgImage: CGImage, quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
        #else
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
        #endif
    }

    #if canImport(UIKit)
    public static func detect(
        in image: UIImage,
        imageData: Data? = nil,
        policy: DetectionPolicy = .platformDefault
    ) throws -> Detection {
        guard let upright = image.normalizedUpCGImage() else {
            throw CropError.imageLoadFailed
        }
        return try detectForCrop(upright: upright, originalData: imageData, policy: policy)
    }
    #endif

    public static func detect(
        in cgImage: CGImage,
        policy: DetectionPolicy = .platformDefault
    ) throws -> Detection {
        try detectForCrop(upright: cgImage, policy: policy)
    }

    // MARK: - Strategies

    private static func detectFromOriginalFile(
        data: Data,
        targetWidth: Int,
        targetHeight: Int,
        method: String? = nil,
        policy: DetectionPolicy
    ) -> Detection? {
        let ext = sniffExtension(data)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-detect-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        guard let ci = CIImage(contentsOf: url) else { return nil }
        let label = method ?? "original file (\(ext))"
        let extent = ci.extent.integral
        CropLogger.shared.info("\(label): CIImage extent \(Int(extent.width))×\(Int(extent.height))")
        return detectOnCIImage(
            ci,
            detectWidth: Int(extent.width),
            detectHeight: Int(extent.height),
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            method: label,
            policy: policy
        )
    }

    private static func detectFromImageSource(
        data: Data,
        targetWidth: Int,
        targetHeight: Int,
        policy: DetectionPolicy
    ) -> Detection? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        var ci = CIImage(cgImage: cg)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = props[kCGImagePropertyOrientation] as? UInt32 {
            ci = ci.oriented(forExifOrientation: Int32(raw))
        }
        ci = ci.transformed(
            by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y)
        )
        let extent = ci.extent.integral
        CropLogger.shared.info("image source: oriented CIImage \(Int(extent.width))×\(Int(extent.height))")
        return detectOnCIImage(
            ci,
            detectWidth: Int(extent.width),
            detectHeight: Int(extent.height),
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            method: "image source",
            policy: policy
        )
    }

    private static func detectOnCIImage(
        _ ciImage: CIImage,
        detectWidth: Int,
        detectHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        method: String,
        policy: DetectionPolicy
    ) -> Detection? {
        guard let raw = runDocumentSegmentation(
            ciImage: ciImage, pixelWidth: detectWidth, pixelHeight: detectHeight, method: method
        ) else { return nil }

        let mapped = mapQuad(
            raw.quad,
            detectWidth: detectWidth,
            detectHeight: detectHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        let imageSize = CGSize(width: targetWidth, height: targetHeight)
        let area = mapped.areaFraction(in: imageSize)
        guard isAcceptable(confidence: raw.confidence, area: area, quad: mapped, imageSize: imageSize, policy: policy) else {
            CropLogger.shared.info(
                String(format: "Rejected [%@] confidence=%.3f area=%.0f%%", method, raw.confidence, area * 100)
            )
            return nil
        }
        return Detection(quad: mapped, confidence: raw.confidence, method: method, areaFraction: area)
    }

    private static func runDocumentSegmentation(
        ciImage: CIImage,
        pixelWidth: Int,
        pixelHeight: Int,
        method: String
    ) -> (quad: DocumentQuad, confidence: Float)? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            CropLogger.shared.warn("Vision [\(method)] failed: \(error.localizedDescription)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }

        let quad = quad(from: observation, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let area = quad.areaFraction(in: CGSize(width: pixelWidth, height: pixelHeight))
        CropLogger.shared.info(
            String(
                format: "Vision [%@] confidence=%.3f area=%.0f%% TL(%.0f,%.0f) BR(%.0f,%.0f)",
                method, observation.confidence, area * 100,
                quad.topLeft.x, quad.topLeft.y, quad.bottomRight.x, quad.bottomRight.y
            )
        )
        return (quad, observation.confidence)
    }

    // MARK: - Scoring

    private static func isAcceptable(
        confidence: Float,
        area: Double,
        quad: DocumentQuad,
        imageSize: CGSize,
        policy: DetectionPolicy
    ) -> Bool {
        guard quad.isValid(in: imageSize) else { return false }
        if confidence < policy.minConfidence { return false }
        if area < policy.minAreaFraction {
            return false  // e.g. 25% bottom strip — would crop away most of the doc
        }
        if area > policy.maxAreaFraction && confidence < policy.highAreaMinConfidence { return false }
        if quad.isFullFrame(in: imageSize) && confidence < policy.fullFrameMinConfidence { return false }
        return true
    }

    private static func score(_ det: Detection) -> Double {
        // Favour confident detections that cover a plausible document area.
        Double(det.confidence) * sqrt(det.areaFraction)
    }

    private static func pickBest(_ candidates: [Detection], targetWidth: Int, targetHeight: Int) -> Detection? {
        candidates.max(by: { score($0) < score($1) })
    }

    private static func mapQuad(
        _ quad: DocumentQuad,
        detectWidth: Int,
        detectHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> DocumentQuad {
        guard detectWidth > 0, detectHeight > 0 else { return quad }
        if detectWidth == targetWidth && detectHeight == targetHeight { return quad }
        let sx = CGFloat(targetWidth) / CGFloat(detectWidth)
        let sy = CGFloat(targetHeight) / CGFloat(detectHeight)
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        CropLogger.shared.info(
            String(format: "Map quad %d×%d → %d×%d", detectWidth, detectHeight, targetWidth, targetHeight)
        )
        return DocumentQuad(
            topLeft: m(quad.topLeft),
            topRight: m(quad.topRight),
            bottomRight: m(quad.bottomRight),
            bottomLeft: m(quad.bottomLeft)
        )
    }

    private static func sniffExtension(_ data: Data) -> String {
        if data.count > 12 {
            let bytes = [UInt8](data.prefix(12))
            if bytes.count >= 8,
               bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
                let brand = String(bytes: bytes[8..<min(12, bytes.count)], encoding: .ascii) ?? ""
                if brand.contains("heic") || brand.contains("heif") || brand.contains("mif1") || brand.contains("hevx") {
                    return "heic"
                }
            }
            if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "jpg" }
            if bytes[0] == 0x89, bytes[1] == 0x50 { return "png" }
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let uti = CGImageSourceGetType(source) as String? {
            let lower = uti.lowercased()
            if lower.contains("heic") || lower.contains("heif") { return "heic" }
            if lower.contains("png") { return "png" }
            if lower.contains("tiff") { return "tiff" }
        }
        return "jpg"
    }

    private static func detectLargestRectangle(
        ciImage: CIImage,
        targetWidth: Int,
        targetHeight: Int,
        policy: DetectionPolicy
    ) -> Detection? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 6.0
        request.minimumSize = 0.20
        request.maximumObservations = 12
        request.minimumConfidence = 0.30

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            CropLogger.shared.warn("Rectangle fallback failed: \(error.localizedDescription)")
            return nil
        }

        guard let results = request.results, !results.isEmpty else {
            CropLogger.shared.warn("Rectangle fallback: no results")
            return nil
        }

        let imageSize = CGSize(width: targetWidth, height: targetHeight)
        var best: Detection?
        var bestScore = -Double.infinity

        for obs in results.sorted(by: { $0.confidence > $1.confidence }) {
            let quad = quad(from: obs, pixelWidth: targetWidth, pixelHeight: targetHeight)
            let area = quad.areaFraction(in: imageSize)
            CropLogger.shared.info(
                String(format: "Rectangle candidate confidence=%.3f area=%.0f%%", obs.confidence, area * 100)
            )
            guard isAcceptable(confidence: obs.confidence, area: area, quad: quad, imageSize: imageSize, policy: policy) else {
                continue
            }
            let det = Detection(quad: quad, confidence: obs.confidence, method: "rectangle", areaFraction: area)
            let s = score(det)
            if s > bestScore {
                bestScore = s
                best = det
            }
        }
        return best
    }

    /// Run doc-seg on a crop around `regionQuad` and map the result back to full-image coords.
    private static func refineDocSegInRegion(
        ciImage: CIImage,
        regionQuad: DocumentQuad,
        targetWidth: Int,
        targetHeight: Int,
        policy: DetectionPolicy
    ) -> Detection? {
        let imageSize = CGSize(width: targetWidth, height: targetHeight)
        let xs = regionQuad.points.map(\.x)
        let ys = regionQuad.points.map(\.y)
        let padX = CGFloat(targetWidth) * 0.03
        let padY = CGFloat(targetHeight) * 0.03
        let cropRect = CGRect(
            x: max(0, (xs.min() ?? 0) - padX),
            y: max(0, (ys.min() ?? 0) - padY),
            width: min(CGFloat(targetWidth), (xs.max() ?? 0) - (xs.min() ?? 0) + 2 * padX),
            height: min(CGFloat(targetHeight), (ys.max() ?? 0) - (ys.min() ?? 0) + 2 * padY)
        ).integral
        guard cropRect.width >= 80, cropRect.height >= 80 else { return nil }

        // CIImage uses bottom-left origin.
        let imgH = ciImage.extent.height
        let ciCrop = CGRect(
            x: cropRect.origin.x + ciImage.extent.origin.x,
            y: imgH - cropRect.maxY + ciImage.extent.origin.y,
            width: cropRect.width,
            height: cropRect.height
        )
        let cropped = ciImage.cropped(to: ciCrop)
        let cw = Int(cropRect.width)
        let ch = Int(cropRect.height)
        CropLogger.shared.info(String(format: "Refine doc-seg in crop %d×%d at (%.0f,%.0f)", cw, ch, cropRect.origin.x, cropRect.origin.y))

        guard let raw = runDocumentSegmentation(
            ciImage: cropped,
            pixelWidth: cw,
            pixelHeight: ch,
            method: "region refine"
        ) else { return nil }

        func mapPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + cropRect.origin.x, y: p.y + cropRect.origin.y)
        }
        let mapped = DocumentQuad(
            topLeft: mapPoint(raw.quad.topLeft),
            topRight: mapPoint(raw.quad.topRight),
            bottomRight: mapPoint(raw.quad.bottomRight),
            bottomLeft: mapPoint(raw.quad.bottomLeft)
        )
        let area = mapped.areaFraction(in: imageSize)
        guard isAcceptable(confidence: raw.confidence, area: area, quad: mapped, imageSize: imageSize, policy: policy) else {
            CropLogger.shared.info(
                String(format: "Rejected [region refine] confidence=%.3f area=%.0f%%", raw.confidence, area * 100)
            )
            return nil
        }
        return Detection(quad: mapped, confidence: raw.confidence, method: "region refine", areaFraction: area)
    }

    private static func quad(
        from observation: VNRectangleObservation,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> DocumentQuad {
        let w = CGFloat(pixelWidth)
        let h = CGFloat(pixelHeight)
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * w, y: (1 - p.y) * h)
        }
        return DocumentQuad(
            topLeft: px(observation.topLeft),
            topRight: px(observation.topRight),
            bottomRight: px(observation.bottomRight),
            bottomLeft: px(observation.bottomLeft)
        )
    }
}

#if canImport(UIKit)
extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

extension UIImage.Orientation {
    var debugLabel: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .upMirrored: return "upMirrored"
        case .downMirrored: return "downMirrored"
        case .leftMirrored: return "leftMirrored"
        case .rightMirrored: return "rightMirrored"
        @unknown default: return "unknown"
        }
    }
}
#endif
