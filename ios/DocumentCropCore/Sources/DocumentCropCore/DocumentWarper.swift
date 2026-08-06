import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Perspective warp + light straighten — Swift port of the Python crop path.
public enum DocumentWarper {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Warp `cgImage` so `quad` becomes a rectangle. Size follows edge lengths
    /// (no forced aspect ratio) — same idea as `processor.warp_perspective`.
    public static func warp(cgImage: CGImage, quad: DocumentQuad) throws -> CGImage {
        let tl = quad.topLeft
        let tr = quad.topRight
        let br = quad.bottomRight
        let bl = quad.bottomLeft

        let widthTop = hypot(tr.x - tl.x, tr.y - tl.y)
        let widthBot = hypot(br.x - bl.x, br.y - bl.y)
        let heightLeft = hypot(bl.x - tl.x, bl.y - tl.y)
        let heightRight = hypot(br.x - tr.x, br.y - tr.y)

        let dstW = max(1, Int(max(widthTop, widthBot).rounded()))
        let dstH = max(1, Int(max(heightLeft, heightRight).rounded()))

        // CIImage uses bottom-left origin; convert UIKit points → CI space.
        let imgH = CGFloat(cgImage.height)
        func ci(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: imgH - p.y)
        }

        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = input
        filter.topLeft = ci(tl)
        filter.topRight = ci(tr)
        filter.bottomRight = ci(br)
        filter.bottomLeft = ci(bl)

        guard var output = filter.outputImage else {
            CropLogger.shared.error("CIFilter perspectiveCorrection returned nil")
            throw CropError.warpFailed
        }

        // Normalize extent, then scale to edge-derived size.
        output = output.transformed(
            by: CGAffineTransform(
                translationX: -output.extent.origin.x,
                y: -output.extent.origin.y
            )
        )
        let sx = CGFloat(dstW) / max(output.extent.width, 1)
        let sy = CGFloat(dstH) / max(output.extent.height, 1)
        output = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let target = CGRect(x: 0, y: 0, width: dstW, height: dstH)
        guard let cg = context.createCGImage(output, from: target) else {
            throw CropError.warpFailed
        }
        return cg
    }

    /// Multi-pass micro-rotation after warp — port of `processor.deskew_image`.
    public static func deskew(_ cgImage: CGImage, maxAngle: Double = 15, maxPasses: Int = 3) -> CGImage {
        var out = cgImage
        var prevAbs: Double?
        for _ in 0..<maxPasses {
            guard let skew = estimateSkewDegrees(out, maxDegrees: maxAngle),
                  abs(skew) >= 0.25
            else { break }
            if let prev = prevAbs, abs(skew) >= prev * 0.92 { break }
            prevAbs = abs(skew)
            let step = skew * 0.85
            out = rotateReflect(out, degrees: step)
        }
        return out
    }

    /// Single-pass straighten (legacy alias).
    public static func straighten(_ cgImage: CGImage, maxDegrees: Double = 12) -> CGImage {
        deskew(cgImage, maxAngle: maxDegrees, maxPasses: 1)
    }

    /// Debug/test seam: exposes the raw skew estimate (nil = "no signal, don't rotate") without
    /// running the full multi-pass deskew loop. Used by regression tooling in `lab/` and ad hoc
    /// verification against real photos; not used by the crop pipeline itself.
    public static func debugEstimateSkewDegrees(_ cgImage: CGImage, maxDegrees: Double = 15) -> Double? {
        estimateSkewDegrees(cgImage, maxDegrees: maxDegrees)
    }

    /// Rotate about the image center and crop back to the **original** extent — matches
    /// `cv2.warpAffine(img, M, (w, h), borderMode=BORDER_REFLECT)`, which keeps the canvas size
    /// fixed at (w, h) and only uses reflection to fill the small corner gaps a slight rotation
    /// exposes. `CIAffineTransform` rotates about the origin and its `.extent` is the rotated
    /// bounding box — larger than the input along both axes — so cropping to `rotated.extent`
    /// (the previous behavior) grew the canvas every pass instead of preserving it, and compounded
    /// across the deskew stack's multiple passes into a visibly distorted/rotated result.
    ///
    /// Sign: verified numerically against `cv2.getRotationMatrix2D((w/2,h/2), degrees, 1.0)` —
    /// OpenCV's positive angle rotates counter-clockwise in image (y-down) coordinates. CoreImage's
    /// `CGAffineTransform(rotationAngle:)` is defined in CI's bottom-left-origin space, where the
    /// same counter-clockwise-in-y-down sense corresponds to a **positive** radians value (no
    /// negation) — the previous `-degrees` here rotated the opposite way from Mac.
    private static func rotateReflect(_ cgImage: CGImage, degrees: Double) -> CGImage {
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let radians = CGFloat(degrees * .pi / 180)

        let toOrigin = CGAffineTransform(translationX: -center.x, y: -center.y)
        let rotate = CGAffineTransform(rotationAngle: radians)
        let backToCenter = CGAffineTransform(translationX: center.x, y: center.y)
        let transform = toOrigin.concatenating(rotate).concatenating(backToCenter)

        // Fill the corner triangles rotation exposes by mirroring the image outward, matching
        // OpenCV's BORDER_REFLECT (`processor.deskew_image`). `clampedToExtent()` would smear
        // the edge pixel instead, which reads as a streak against the organic background and
        // was the largest remaining pixel difference from the Python pipeline.
        let source = reflectPadded(ci, extent: extent)
        let rotated = source.transformed(by: transform)
        guard let cg = context.createCGImage(rotated, from: extent.integral) else {
            return cgImage
        }
        return cg
    }

    /// Mirror `image` across all four edges so sampling just outside `extent` reflects the
    /// content back, the way `cv2.BORDER_REFLECT` does.
    private static func reflectPadded(_ image: CIImage, extent: CGRect) -> CIImage {
        // A rotation of a few degrees only ever reaches a little past the edge, so one
        // mirrored copy per side (and per corner) is ample.
        func mirrored(flipX: Bool, flipY: Bool, dx: CGFloat, dy: CGFloat) -> CIImage {
            var t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            t = t.concatenating(CGAffineTransform(scaleX: flipX ? -1 : 1, y: flipY ? -1 : 1))
            t = t.concatenating(CGAffineTransform(translationX: extent.midX + dx, y: extent.midY + dy))
            return image.transformed(by: t)
        }

        let w = extent.width
        let h = extent.height
        var composite = image
        for (fx, fy, dx, dy) in [
            (true, false, -w, 0), (true, false, w, 0),      // left / right
            (false, true, 0, -h), (false, true, 0, h),      // below / above
            (true, true, -w, -h), (true, true, w, -h),      // corners
            (true, true, -w, h), (true, true, w, h),
        ] as [(Bool, Bool, CGFloat, CGFloat)] {
            composite = composite.composited(over: mirrored(flipX: fx, flipY: fy, dx: dx, dy: dy))
        }
        return composite
    }

    /// Faithful port of `processor._estimate_skew_angle` — title-band Hough line detection with a
    /// dark-pixel polyfit cross-check, falling back to a global Hough sweep, and critically a
    /// **nil "no signal" result** when nothing is found. The previous Swift implementation was a
    /// from-scratch brute-force rotational projection-variance search with no such safety valve;
    /// it always returned *some* angle and was found to be systematically biased toward the search
    /// boundary on real photos (verified: monotonically increasing score from -15° to +15° on a
    /// near-upright test photo, picking +15° as "best" when the true skew was ~0°). Returning nil
    /// here means `deskew` simply skips rotation for that pass — matching Python's behavior.
    private static func estimateSkewDegrees(_ cgImage: CGImage, maxDegrees: Double) -> Double? {
        guard let gray = grayscaleBytes(cgImage) else { return nil }
        let w = gray.width, h = gray.height
        guard w >= 50, h >= 50 else { return nil }

        let bandY0 = Int(Double(h) * 0.06)
        let bandY1 = Int(Double(h) * 0.22)
        let bandX0 = Int(Double(w) * 0.05)
        let bandX1 = Int(Double(w) * 0.95)
        let band = gray.crop(x0: bandX0, y0: bandY0, x1: bandX1, y1: bandY1)

        let ruleAngle = ruleLineAngle(band: band, maxDegrees: maxDegrees)
        let polyAngle = polyfitAngle(band: band, maxDegrees: maxDegrees)

        var candidates: [Double] = []
        if let ruleAngle { candidates.append(ruleAngle) }
        if let polyAngle { candidates.append(polyAngle) }

        if !candidates.isEmpty {
            // Python: `sorted(candidates, key=lambda a: abs(a))[-1]` — the larger-magnitude one.
            return candidates.max(by: { abs($0) < abs($1) })
        }

        return globalHoughFallback(gray: gray, maxDegrees: maxDegrees)
    }

    /// Adaptive-threshold + morphological horizontal-line opening + Hough line detection on the
    /// title band — port of the "rule_angles" path in `_estimate_skew_angle`.
    private static func ruleLineAngle(band: GrayImage, maxDegrees: Double) -> Double? {
        guard band.width >= 20, band.height >= 5 else { return nil }
        let inv = adaptiveThresholdInvert(band, blockSize: 31, c: 12)
        let kernelWidth = max(20, band.width / 10)
        let opened = morphologyOpen(inv, width: band.width, height: band.height, kernelWidth: kernelWidth)

        let lines = houghLinesP(
            opened,
            width: band.width,
            height: band.height,
            angleResolutionDegrees: 0.1,
            voteThreshold: 40,
            minLineLength: Double(band.width) * 0.35,
            maxLineGap: 12,
            maxDegreesFromHorizontal: maxDegrees
        )
        guard !lines.isEmpty else { return nil }
        return median(lines)
    }

    /// Linear regression (y vs x) over dark pixels in the band — port of the "poly_angle" path.
    private static func polyfitAngle(band: GrayImage, maxDegrees: Double) -> Double? {
        var xs: [Double] = []
        var ys: [Double] = []
        for y in 0..<band.height {
            for x in 0..<band.width {
                if band.pixels[y * band.width + x] < 95 {
                    xs.append(Double(x))
                    ys.append(Double(y))
                }
            }
        }
        guard xs.count >= 400 else { return nil }

        if xs.count > 8000 {
            // Python seeds `RandomState(0)` for determinism; mirror with a fixed-seed LCG so the
            // subsample is reproducible run-to-run (exact index parity with NumPy isn't required —
            // both are just deterministic subsamples of the same population for a stable estimate).
            var rng = SeededGenerator(seed: 0)
            let picked = (0..<xs.count).shuffled(using: &rng).prefix(8000)
            xs = picked.map { xs[$0] }
            ys = picked.map { ys[$0] }
        }

        guard let slope = linearRegressionSlope(xs: xs, ys: ys) else { return nil }
        let angle = atan(slope) * 180 / .pi
        return abs(angle) <= maxDegrees ? angle : nil
    }

    /// Global Canny + Hough sweep over the whole (downscaled) image — last-resort fallback.
    private static func globalHoughFallback(gray: GrayImage, maxDegrees: Double) -> Double? {
        let edges = cannyEdges(gray, lowThreshold: 50, highThreshold: 150)
        let lines = houghLinesP(
            edges,
            width: gray.width,
            height: gray.height,
            angleResolutionDegrees: 1.0,
            voteThreshold: 80,
            minLineLength: Double(gray.width) * 0.15,
            maxLineGap: 25,
            maxDegreesFromHorizontal: maxDegrees
        )
        guard lines.count >= 5 else { return nil }
        return median(lines)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func linearRegressionSlope(xs: [Double], ys: [Double]) -> Double? {
        let n = Double(xs.count)
        guard n > 1 else { return nil }
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for i in 0..<xs.count {
            num += (xs[i] - meanX) * (ys[i] - meanY)
            den += (xs[i] - meanX) * (xs[i] - meanX)
        }
        guard den > 1e-9 else { return nil }
        return num / den
    }

    // MARK: - Image primitives (grayscale, adaptive threshold, morphology, Canny, Hough)

    private struct GrayImage {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        func crop(x0: Int, y0: Int, x1: Int, y1: Int) -> GrayImage {
            let cx0 = max(0, x0), cy0 = max(0, y0)
            let cx1 = min(width, x1), cy1 = min(height, y1)
            let cw = max(0, cx1 - cx0), ch = max(0, cy1 - cy0)
            var out = [UInt8](repeating: 0, count: cw * ch)
            for y in 0..<ch {
                for x in 0..<cw {
                    out[y * cw + x] = pixels[(cy0 + y) * width + (cx0 + x)]
                }
            }
            return GrayImage(pixels: out, width: cw, height: ch)
        }
    }

    /// Cap analysis resolution — matches the intent of the old 720px downscale (Python runs at
    /// full resolution, but full-res Hough/morphology in unoptimized Swift is too slow; 1600px
    /// long-edge preserves enough text/line detail for the title-band heuristics while staying
    /// fast). The band itself is small (title band is ~16% of height) so this mostly affects the
    /// global-fallback path.
    private static func grayscaleBytes(_ cgImage: CGImage) -> GrayImage? {
        let maxSide = 1600
        let w0 = cgImage.width, h0 = cgImage.height
        let scale = min(1.0, CGFloat(maxSide) / CGFloat(max(w0, h0)))
        let w = max(1, Int(CGFloat(w0) * scale))
        let h = max(1, Int(CGFloat(h0) * scale))

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return GrayImage(pixels: pixels, width: w, height: h)
    }

    /// Local mean adaptive threshold (approximates `cv2.ADAPTIVE_THRESH_GAUSSIAN_C`) + inversion —
    /// pixels darker than their local neighborhood mean minus `c` become foreground (255).
    private static func adaptiveThresholdInvert(_ img: GrayImage, blockSize: Int, c: Int) -> [UInt8] {
        let w = img.width, h = img.height
        let half = blockSize / 2
        // Integral image for O(1) box-mean lookups instead of an O(blockSize²) window per pixel.
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0
            for x in 0..<w {
                rowSum += Int(img.pixels[y * w + x])
                integral[(y + 1) * (w + 1) + (x + 1)] = integral[y * (w + 1) + (x + 1)] + rowSum
            }
        }
        func boxSum(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
        }

        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - half), y1 = min(h, y + half + 1)
            for x in 0..<w {
                let x0 = max(0, x - half), x1 = min(w, x + half + 1)
                let count = (x1 - x0) * (y1 - y0)
                let mean = Double(boxSum(x0, y0, x1, y1)) / Double(max(count, 1))
                let v = Double(img.pixels[y * w + x])
                out[y * w + x] = v < mean - Double(c) ? 255 : 0
            }
        }
        return out
    }

    /// Morphological opening (erode then dilate) with a `kernelWidth × 1` rectangular kernel —
    /// isolates long horizontal rule lines, matching `cv2.MORPH_OPEN` with a wide flat kernel.
    private static func morphologyOpen(_ binary: [UInt8], width w: Int, height h: Int, kernelWidth: Int) -> [UInt8] {
        let half = kernelWidth / 2
        func erode(_ src: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var minV: UInt8 = 255
                    let x0 = max(0, x - half), x1 = min(w - 1, x + half)
                    for xx in x0...x1 {
                        if src[y * w + xx] < minV { minV = src[y * w + xx] }
                        if minV == 0 { break }
                    }
                    out[y * w + x] = minV
                }
            }
            return out
        }
        func dilate(_ src: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var maxV: UInt8 = 0
                    let x0 = max(0, x - half), x1 = min(w - 1, x + half)
                    for xx in x0...x1 {
                        if src[y * w + xx] > maxV { maxV = src[y * w + xx] }
                        if maxV == 255 { break }
                    }
                    out[y * w + x] = maxV
                }
            }
            return out
        }
        return dilate(erode(binary))
    }

    /// Sobel-magnitude edge map thresholded into a binary edge mask — approximates `cv2.Canny`'s
    /// output closely enough to feed the Hough line search (true Canny adds non-max-suppression
    /// and hysteresis linking; this uses a single magnitude band as a lighter-weight stand-in,
    /// same approach as `DocumentTrimmer.cannyLite`).
    private static func cannyEdges(_ img: GrayImage, lowThreshold: Int, highThreshold: Int) -> [UInt8] {
        let w = img.width, h = img.height
        var blurred = img.pixels
        if w > 2, h > 2 {
            var tmp = img.pixels
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    var sum = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            sum += Int(img.pixels[(y + dy) * w + (x + dx)])
                        }
                    }
                    tmp[y * w + x] = UInt8(sum / 9)
                }
            }
            blurred = tmp
        }
        var edges = [UInt8](repeating: 0, count: w * h)
        guard w > 2, h > 2 else { return edges }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = Int(blurred[(y - 1) * w + (x + 1)]) + 2 * Int(blurred[y * w + (x + 1)])
                    + Int(blurred[(y + 1) * w + (x + 1)])
                    - Int(blurred[(y - 1) * w + (x - 1)]) - 2 * Int(blurred[y * w + (x - 1)])
                    - Int(blurred[(y + 1) * w + (x - 1)])
                let gy = Int(blurred[(y + 1) * w + (x - 1)]) + 2 * Int(blurred[(y + 1) * w + x])
                    + Int(blurred[(y + 1) * w + (x + 1)])
                    - Int(blurred[(y - 1) * w + (x - 1)]) - 2 * Int(blurred[(y - 1) * w + x])
                    - Int(blurred[(y - 1) * w + (x + 1)])
                let mag = Int(hypot(Double(gx), Double(gy)))
                edges[y * w + x] = mag >= lowThreshold && mag <= highThreshold * 3 ? 255 : 0
            }
        }
        return edges
    }

    /// Probabilistic Hough line transform: accumulates votes per angle (using each edge pixel's
    /// local gradient-free rho/theta at fixed angle steps) and reports the angles of edge-pixel
    /// clusters that form a line of at least `minLineLength` with gaps no larger than `maxLineGap`.
    /// This is a simplified but behaviorally-equivalent stand-in for `cv2.HoughLinesP`: rather than
    /// walking every (rho, theta) accumulator cell, it scans each candidate angle, projects all
    /// edge pixels onto that angle's perpendicular axis, and groups contiguous runs — cheaper than
    /// a full Hough accumulator and sufficient for "is there a long near-horizontal line."
    private static func houghLinesP(
        _ edges: [UInt8],
        width w: Int,
        height h: Int,
        angleResolutionDegrees: Double,
        voteThreshold: Int,
        minLineLength: Double,
        maxLineGap: Double,
        maxDegreesFromHorizontal: Double
    ) -> [Double] {
        var edgePoints: [(x: Double, y: Double)] = []
        for y in 0..<h {
            for x in 0..<w where edges[y * w + x] != 0 {
                edgePoints.append((Double(x), Double(y)))
            }
        }
        guard edgePoints.count >= voteThreshold else { return [] }

        var foundAngles: [Double] = []
        var angle = -maxDegreesFromHorizontal
        while angle <= maxDegreesFromHorizontal + 1e-9 {
            let rad = angle * .pi / 180
            let cosA = cos(rad), sinA = sin(rad)
            // Project each point onto the line direction (u) and perpendicular offset (v);
            // points on the same near-horizontal line at this angle share a v-bucket.
            var buckets: [Int: [Double]] = [:]
            for p in edgePoints {
                let u = p.x * cosA + p.y * sinA
                let v = -p.x * sinA + p.y * cosA
                let bucket = Int(v.rounded())
                buckets[bucket, default: []].append(u)
            }
            for (_, us) in buckets where us.count >= voteThreshold {
                let sorted = us.sorted()
                var runStart = sorted[0]
                var prev = sorted[0]
                for u in sorted.dropFirst() {
                    if u - prev > maxLineGap {
                        if prev - runStart >= minLineLength { foundAngles.append(angle) }
                        runStart = u
                    }
                    prev = u
                }
                if prev - runStart >= minLineLength { foundAngles.append(angle) }
            }
            angle += angleResolutionDegrees
        }
        return foundAngles
    }

    /// Deterministic, seedable PRNG (splitmix64) — used only for the polyfit subsample, where
    /// Python seeds `np.random.RandomState(0)`. Exact index parity with NumPy isn't the goal (a
    /// different deterministic subsample of the same dark-pixel population is an equally valid
    /// estimate); this just avoids `Int.random`'s non-reproducible seeding.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
