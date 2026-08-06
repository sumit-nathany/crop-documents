import CoreGraphics
import Foundation

/// Four corners in **pixel** space, UIKit top-left origin.
/// Order matches the Python/Vision convention: TL → TR → BR → BL.
public struct DocumentQuad: Sendable, Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public var points: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    public var centroid: CGPoint {
        let pts = points
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / 4, y: sum.y / 4)
    }

    /// Push corners outward from the centroid — the organic “margin” border.
    public func expanded(byPercent percent: Double) -> DocumentQuad {
        let factor = 1.0 + (percent / 100.0)
        let c = centroid
        func push(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: c.x + (p.x - c.x) * factor,
                y: c.y + (p.y - c.y) * factor
            )
        }
        return DocumentQuad(
            topLeft: push(topLeft),
            topRight: push(topRight),
            bottomRight: push(bottomRight),
            bottomLeft: push(bottomLeft)
        )
    }

    public func clamped(to size: CGSize) -> DocumentQuad {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(p.x, 0), max(size.width - 1, 0)),
                y: min(max(p.y, 0), max(size.height - 1, 0))
            )
        }
        return DocumentQuad(
            topLeft: clamp(topLeft),
            topRight: clamp(topRight),
            bottomRight: clamp(bottomRight),
            bottomLeft: clamp(bottomLeft)
        )
    }

    /// Absolute angle difference (degrees) between top and bottom edges.
    public var topBottomDivergenceDegrees: Double {
        func angle(_ a: CGPoint, _ b: CGPoint) -> Double {
            atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180.0 / .pi
        }
        var diff = abs(angle(topLeft, topRight) - angle(bottomLeft, bottomRight))
            .truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
    }

    /// Fraction of image area covered by the quad (0–1).
    public func areaFraction(in imageSize: CGSize) -> Double {
        func area(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
            abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5
        }
        let quadArea = area(topLeft, topRight, bottomRight) + area(topLeft, bottomRight, bottomLeft)
        let imageArea = Double(imageSize.width * imageSize.height)
        return quadArea / max(imageArea, 1)
    }

    /// Reject degenerate / out-of-bounds quads before warp.
    public func isValid(in imageSize: CGSize) -> Bool {
        let w = imageSize.width
        let h = imageSize.height
        guard w > 1, h > 1 else { return false }

        for p in points {
            if p.x.isNaN || p.y.isNaN { return false }
            if p.x < -w * 0.05 || p.x > w * 1.05 || p.y < -h * 0.05 || p.y > h * 1.05 {
                return false
            }
        }

        let frac = areaFraction(in: imageSize)
        return frac >= 0.08 && frac <= 0.98
    }

    /// True when Vision returned essentially the whole frame (failed to find edges).
    public func isFullFrame(in imageSize: CGSize, marginPixels: CGFloat = 40) -> Bool {
        let w = imageSize.width
        let h = imageSize.height
        return topLeft.x <= marginPixels
            && topLeft.y <= marginPixels
            && abs(bottomRight.x - (w - 1)) <= marginPixels
            && abs(bottomRight.y - (h - 1)) <= marginPixels
    }
}

public enum CropConstants {
    /// Extra border when straighten/deskew is on — matches `processor.DESKEW_BORDER_EXTRA_PCT`.
    public static let deskewBorderExtraPercent: Double = 4.0
}

/// How aggressively to reject a Vision detection that covers too little of the frame.
///
/// This is genuinely platform-dependent policy, not an algorithm difference, so the core
/// exposes it rather than hardcoding one platform's tuning:
///
/// - **iOS** photos come straight from the camera, framed by someone pointing at a
///   document. A detection covering a third of the frame is far more likely to be a
///   sub-region (a barcode sticker, a bottom strip) than the real page, and accepting
///   one produces a badly wrong crop. Hence the strict floor.
/// - **Mac** inputs are curated files the user deliberately pointed the CLI at, often
///   already-cropped or scanned, and a document legitimately occupying ~34% of a tall
///   phone photo is normal. The Python CLI applied no floor at all and was right not to;
///   a strict floor here silently skips images that previously worked.
public struct DetectionPolicy: Sendable, Equatable {
    /// Minimum fraction of the frame a detection must cover to be accepted.
    public var minAreaFraction: Double
    /// Above this fraction, a detection needs `highAreaMinConfidence` to be trusted.
    public var maxAreaFraction: Double
    /// Reject anything below this confidence outright.
    public var minConfidence: Float
    /// Confidence required when the detection covers more than `maxAreaFraction`.
    public var highAreaMinConfidence: Float
    /// Confidence required when the detection is essentially the whole frame.
    public var fullFrameMinConfidence: Float

    public init(
        minAreaFraction: Double,
        maxAreaFraction: Double = 0.94,
        minConfidence: Float = 0.12,
        highAreaMinConfidence: Float = 0.50,
        fullFrameMinConfidence: Float = 0.55
    ) {
        self.minAreaFraction = minAreaFraction
        self.maxAreaFraction = maxAreaFraction
        self.minConfidence = minConfidence
        self.highAreaMinConfidence = highAreaMinConfidence
        self.fullFrameMinConfidence = fullFrameMinConfidence
    }

    /// Camera-roll default: strict area floor to reject sub-region latches.
    public static let strict = DetectionPolicy(minAreaFraction: 0.35)

    /// Curated-file default: trust Vision's confidence and keep only a degenerate-quad
    /// guard, matching the Python CLI's behaviour.
    public static let lenient = DetectionPolicy(minAreaFraction: 0.10)

    #if canImport(UIKit)
    public static let platformDefault = strict
    #else
    public static let platformDefault = lenient
    #endif
}

public struct CropSettings: Sendable, Equatable {
    /// Organic border beyond the detected edge (matches CLI `expansion_pct`).
    public var expansionPercent: Double
    /// When true, run the conservative `--deskew` stack (refine, wider border, deskew, flap trim).
    /// Defaults off: the deskew angle estimate is not yet trusted on real device photos (see
    /// ios/HANDOFF.md Round 3/4) — the UI hides this toggle for now until it's re-verified. Also
    /// matches Python's `config.yaml` default (`deskew: false`), which Swift previously diverged from.
    public var straighten: Bool
    /// Apple Photos CoreImage auto-enhance (matches CLI `--enhance`).
    public var enhance: Bool
    /// Correct 90°/180°/270° orientation via Vision text recognition (matches CLI `--rotate`).
    /// Off by default, like Python's `config.yaml` — a wrong quarter turn is very visible,
    /// so this stays opt-in.
    public var autoRotate: Bool

    public init(
        expansionPercent: Double = 4.0,
        straighten: Bool = false,
        enhance: Bool = false,
        autoRotate: Bool = false
    ) {
        self.expansionPercent = expansionPercent
        self.straighten = straighten
        self.enhance = enhance
        self.autoRotate = autoRotate
    }

    /// Effective expansion for warp + trim padding.
    public var borderPercent: Double {
        straighten ? expansionPercent + CropConstants.deskewBorderExtraPercent : expansionPercent
    }
}

public struct CropResult: Sendable {
    public let image: CGImage
    public let confidence: Float
    public let quad: DocumentQuad

    public init(image: CGImage, confidence: Float, quad: DocumentQuad) {
        self.image = image
        self.confidence = confidence
        self.quad = quad
    }
}

public enum CropError: Error, LocalizedError, Sendable {
    case imageLoadFailed
    case noDocumentDetected
    case visionFailed(String)
    case warpFailed

    public var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            return "Couldn’t read that photo."
        case .noDocumentDetected:
            return "No document found. Include the full page with some background around it."
        case .visionFailed(let message):
            return "Detection failed: \(message)"
        case .warpFailed:
            return "Couldn’t crop that photo."
        }
    }
}
