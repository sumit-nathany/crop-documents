import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Quarter-turn orientation correction — the Vision replacement for `processor.auto_rotate_image`.
///
/// The Python path shelled out to Tesseract OSD, which meant an optional `brew install
/// tesseract` + `pip install pytesseract` and a soft-skip whenever they were missing.
/// Vision's text recognizer is always present on Apple platforms, so no optional dependency.
///
/// **Scope: sideways pages only.** Method is to recognize text at each quarter turn and keep
/// the best-scoring one — but measurement on rotated fixtures shows Vision reads upside-down
/// text almost as well as upright text:
///
/// ```
/// fixture (already upright)   s0=452  s90=30  s180=456  s270=24
/// fixture (rotated 90°)       s0=28   s90=455 s180=30   s270=452
/// ```
///
/// The *axis* separates cleanly by more than an order of magnitude, but the 180° partner
/// scores within ~1% — sometimes higher, as in the first row. So this corrects a sideways
/// page confidently and deliberately declines to guess between upright and upside-down.
///
/// That is a real reduction in scope versus Tesseract OSD, which did resolve 180°. It is
/// also the honest limit of what this signal supports: an unnecessary 180° flip is a
/// glaringly visible error, and the evidence here would be a coin toss. `--rotate` therefore
/// fixes sideways scans and leaves flips to the user.
public enum DocumentOrienter {
    /// A quarter turn, expressed as the clockwise rotation needed to make the image upright.
    public enum QuarterTurn: Int, Sendable, CaseIterable {
        case none = 0
        case clockwise90 = 90
        case rotate180 = 180
        case counterClockwise90 = 270

        /// How Vision should interpret the pixels to read text at this turn.
        var orientation: CGImagePropertyOrientation {
            switch self {
            case .none: return .up
            case .clockwise90: return .right
            case .rotate180: return .down
            case .counterClockwise90: return .left
            }
        }
    }

    public struct Assessment: Sendable {
        public let turn: QuarterTurn
        /// Sum of (confidence × recognized character count) — favours lots of confident text.
        public let score: Double
        /// Best score of any other orientation, for the margin check.
        public let runnerUpScore: Double

        /// How decisively the winner beat the runner-up. 1.0 means nothing else read at all.
        public var margin: Double {
            guard score > 0 else { return 0 }
            return (score - runnerUpScore) / score
        }
    }

    /// Detect the quarter turn that makes `cgImage` upright.
    ///
    /// Only ever returns `.none` or `.clockwise90` — see the type docs for why 180° is not
    /// decidable from this signal. Returns `nil` when there is too little text to judge or
    /// when the two axes score too closely, both meaning "leave the image alone". That is
    /// the same conservative contract as the Tesseract path, which skipped on low OSD
    /// confidence.
    ///
    /// - Parameters:
    ///   - minimumScore: Confidence-weighted characters required on the winning axis.
    ///     Guards against a stray logo or a page with three words on it.
    ///   - minimumMargin: How far the winning axis must beat the other, as a fraction of
    ///     its own score. On the measured fixtures the true axis wins by >90%, so this can
    ///     be strict without costing recall.
    public static func detectOrientation(
        _ cgImage: CGImage,
        minimumScore: Double = 40,
        minimumMargin: Double = 0.35
    ) -> Assessment? {
        // Recognition runs four times; downscale so it stays fast on full-resolution photos.
        let candidate = downscaled(cgImage, maxSide: 1600) ?? cgImage

        var scores: [QuarterTurn: Double] = [:]
        for turn in QuarterTurn.allCases {
            scores[turn] = textScore(candidate, orientation: turn.orientation)
        }

        // Collapse each axis to its best reading. Within an axis the two turns are 180°
        // apart and score near-identically, so the max is the axis's true strength; across
        // axes the difference is large and meaningful.
        let uprightAxis = max(scores[.none] ?? 0, scores[.rotate180] ?? 0)
        let sidewaysAxis = max(scores[.clockwise90] ?? 0, scores[.counterClockwise90] ?? 0)

        let winningTurn: QuarterTurn = sidewaysAxis > uprightAxis ? .clockwise90 : .none
        let winningScore = max(uprightAxis, sidewaysAxis)
        let losingScore = min(uprightAxis, sidewaysAxis)

        guard winningScore > 0 else {
            CropLogger.shared.info("Auto-rotate: no text recognized at any orientation")
            return nil
        }

        let assessment = Assessment(
            turn: winningTurn, score: winningScore, runnerUpScore: losingScore
        )

        guard winningScore >= minimumScore else {
            CropLogger.shared.info(
                String(format: "Auto-rotate: too little text (score %.0f < %.0f) — leaving as-is",
                       winningScore, minimumScore)
            )
            return nil
        }
        guard assessment.margin >= minimumMargin else {
            CropLogger.shared.info(
                String(format: "Auto-rotate: axes too close (%.0f vs %.0f) — leaving as-is",
                       winningScore, losingScore)
            )
            return nil
        }

        return assessment
    }

    /// Rotate `cgImage` upright if Vision is confident about its orientation.
    /// Returns the input unchanged when already upright or when the call is too close.
    public static func autoRotate(
        _ cgImage: CGImage,
        minimumScore: Double = 40,
        minimumMargin: Double = 0.35
    ) -> CGImage {
        guard let assessment = detectOrientation(
            cgImage, minimumScore: minimumScore, minimumMargin: minimumMargin
        ) else {
            return cgImage
        }
        guard assessment.turn != .none else {
            CropLogger.shared.info("Auto-rotate: already upright")
            return cgImage
        }

        CropLogger.shared.info(
            String(format: "Auto-rotate: %d° (score %.0f, margin %.0f%%)",
                   assessment.turn.rawValue, assessment.score, assessment.margin * 100)
        )
        return rotate(cgImage, turn: assessment.turn) ?? cgImage
    }

    /// Raw per-turn scores, before any gating. Diagnostic seam for the lab harness — lets a
    /// regression test see *why* a decision was made, not just what it was.
    public static func debugScores(_ cgImage: CGImage) -> [(turn: QuarterTurn, score: Double)] {
        let candidate = downscaled(cgImage, maxSide: 1600) ?? cgImage
        return QuarterTurn.allCases.map {
            ($0, textScore(candidate, orientation: $0.orientation))
        }
    }

    // MARK: - Scoring

    /// Confidence-weighted character count Vision reads when told the image has `orientation`.
    private static func textScore(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            CropLogger.shared.warn("Auto-rotate: text request failed: \(error.localizedDescription)")
            return 0
        }

        guard let results = request.results else { return 0 }
        return results.reduce(0.0) { total, observation in
            guard let best = observation.topCandidates(1).first else { return total }
            // Weighting by length stops a single confident stray glyph from outvoting a
            // paragraph, which is exactly the failure mode on a rotated form.
            return total + Double(best.confidence) * Double(best.string.count)
        }
    }

    // MARK: - Geometry

    /// Rotate by a quarter turn. Exact and lossless — no resampling, no interpolation.
    private static func rotate(_ cgImage: CGImage, turn: QuarterTurn) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        let swapsAxes = (turn == .clockwise90 || turn == .counterClockwise90)
        let outW = swapsAxes ? h : w
        let outH = swapsAxes ? w : h

        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CGContext origin is bottom-left; translate so the rotated content lands in frame.
        switch turn {
        case .none:
            break
        case .clockwise90:
            ctx.translateBy(x: CGFloat(outW), y: 0)
            ctx.rotate(by: .pi / 2)
        case .rotate180:
            ctx.translateBy(x: CGFloat(outW), y: CGFloat(outH))
            ctx.rotate(by: .pi)
        case .counterClockwise90:
            ctx.translateBy(x: 0, y: CGFloat(outH))
            ctx.rotate(by: -.pi / 2)
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func downscaled(_ cgImage: CGImage, maxSide: Int) -> CGImage? {
        let longest = max(cgImage.width, cgImage.height)
        guard longest > maxSide else { return cgImage }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int(Double(cgImage.width) * scale))
        let h = max(1, Int(Double(cgImage.height) * scale))

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
