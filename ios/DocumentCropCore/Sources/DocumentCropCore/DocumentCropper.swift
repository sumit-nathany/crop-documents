import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// End-to-end crop pipeline — mirrors `processor.process_image` (stable path).
public enum DocumentCropper {
    /// Crop with the given settings. Matches CLI: detect → expand → warp → [deskew stack] → [enhance].
    @available(iOS 17.0, *)
    public static func crop(cgImage: CGImage, settings: CropSettings = .init()) throws -> CropResult {
        CropLogger.shared.info("Crop start \(cgImage.width)×\(cgImage.height)px straighten=\(settings.straighten) enhance=\(settings.enhance)")
        let detection = try DocumentDetector.detect(in: cgImage)
        return try crop(cgImage: cgImage, detection: detection, settings: settings)
    }

    #if canImport(UIKit)
    @available(iOS 17.0, *)
    public static func crop(image: UIImage, imageData: Data? = nil, settings: CropSettings = .init()) throws -> (UIImage, CropResult) {
        CropLogger.shared.info(
            "Crop UIImage \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))px "
            + "scale=\(image.scale) \(image.imageOrientation.debugLabel)"
        )

        guard let upright = image.normalizedUpCGImage() else {
            CropLogger.shared.error("Failed to normalize orientation to upright bitmap")
            throw CropError.imageLoadFailed
        }

        // Detect on upright bitmap; pass original bytes for Mac-style HEIC file detect.
        let detection = try DocumentDetector.detectForCrop(upright: upright, originalData: imageData)
        CropLogger.shared.info("Detection method: \(detection.method)")

        let result = try crop(cgImage: upright, detection: detection, settings: settings)
        let ui = UIImage(cgImage: result.image, scale: image.scale, orientation: .up)
        CropLogger.shared.success("Crop done → \(result.image.width)×\(result.image.height)px")
        return (ui, result)
    }
    #endif

    @available(iOS 17.0, *)
    private static func crop(
        cgImage: CGImage,
        detection: DocumentDetector.Detection,
        settings: CropSettings
    ) throws -> CropResult {
        var quad = detection.quad

        var leftPad: CGFloat = 0
        if settings.straighten {
            let divergence = quad.topBottomDivergenceDegrees
            if divergence > 4 {
                leftPad = max(CGFloat(cgImage.width) * 0.055, 60)
                CropLogger.shared.info(String(format: "Refine corners (divergence %.1f°) leftPad=%.0f", divergence, leftPad))
            }
            quad = refineCorners(quad, imageHeight: CGFloat(cgImage.height))
        }

        let border = settings.borderPercent
        var expanded = quad
            .expanded(byPercent: border)
            .clamped(to: CGSize(width: cgImage.width, height: cgImage.height))

        if leftPad > 0 {
            expanded.topLeft.x -= leftPad
            expanded.bottomLeft.x -= leftPad
            expanded = expanded.clamped(to: CGSize(width: cgImage.width, height: cgImage.height))
        }

        var warped = try DocumentWarper.warp(cgImage: cgImage, quad: expanded)
        CropLogger.shared.info("Warp → \(warped.width)×\(warped.height)px")

        if settings.straighten {
            warped = DocumentWarper.deskew(warped)
            let trimmed = DocumentTrimmer.trimExternalContent(
                warped,
                marginPercent: border,
                maxTrimFraction: 0.35,
                sides: .topBottom
            )
            if trimmed.width != warped.width || trimmed.height != warped.height {
                CropLogger.shared.info("Trim → \(trimmed.width)×\(trimmed.height)px")
            }
            warped = trimmed
        }

        if settings.enhance {
            warped = DocumentEnhancer.enhance(warped)
            CropLogger.shared.info("Enhanced")
        }

        return CropResult(image: warped, confidence: detection.confidence, quad: expanded)
    }

    /// Keystone refine — port of `processor.refine_corners`.
    public static func refineCorners(_ quad: DocumentQuad, imageHeight: CGFloat) -> DocumentQuad {
        var tl = quad.topLeft
        var tr = quad.topRight
        var br = quad.bottomRight
        var bl = quad.bottomLeft

        let threshold = imageHeight * 0.03

        func intersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> CGPoint? {
            let x1 = p1.x, y1 = p1.y, x2 = p2.x, y2 = p2.y
            let x3 = p3.x, y3 = p3.y, x4 = p4.x, y4 = p4.y
            let denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
            guard abs(denom) > 1e-5 else { return nil }
            let px = ((x1 * y2 - y1 * x2) * (x3 - x4) - (x1 - x2) * (x3 * y4 - y3 * x4)) / denom
            let py = ((x1 * y2 - y1 * x2) * (y3 - y4) - (y1 - y2) * (x3 * y4 - y3 * x4)) / denom
            return CGPoint(x: px, y: py)
        }

        if tl.y > tr.y + threshold {
            let trVirtual = CGPoint(x: tr.x + (bl.x - br.x), y: tr.y + (bl.y - br.y))
            if let n = intersect(bl, tl, tr, trVirtual) { tl = n }
        } else if tr.y > tl.y + threshold {
            let tlVirtual = CGPoint(x: tl.x + (br.x - bl.x), y: tl.y + (br.y - bl.y))
            if let n = intersect(br, tr, tl, tlVirtual) { tr = n }
        } else if bl.y < br.y - threshold {
            let brVirtual = CGPoint(x: br.x + (tl.x - tr.x), y: br.y + (tl.y - tr.y))
            if let n = intersect(tl, bl, br, brVirtual) { bl = n }
        } else if br.y < bl.y - threshold {
            let blVirtual = CGPoint(x: bl.x + (tr.x - tl.x), y: bl.y + (tr.y - tl.y))
            if let n = intersect(tr, br, bl, blVirtual) { br = n }
        }

        return DocumentQuad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }
}

#if canImport(UIKit)
import UIKit

extension UIImage {
    /// Bake EXIF orientation into an upright `.up` CGImage at full pixel resolution.
    func normalizedUpCGImage() -> CGImage? {
        guard let cg = cgImage else { return nil }

        let pixelW = Int((size.width * scale).rounded())
        let pixelH = Int((size.height * scale).rounded())

        if imageOrientation == .up,
           abs(pixelW - cg.width) <= 1,
           abs(pixelH - cg.height) <= 1 {
            return cg
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelW, height: pixelH),
            format: format
        )
        let rendered = renderer.image { _ in
            draw(in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        }
        CropLogger.shared.info("Normalized orientation → \(pixelW)×\(pixelH)px")
        return rendered.cgImage
    }
}
#endif
