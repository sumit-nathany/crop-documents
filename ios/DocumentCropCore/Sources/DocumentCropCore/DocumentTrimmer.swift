import CoreGraphics
import Foundation

/// Top/bottom flap trim — port of `processor.trim_external_content` (conservative sides).
public enum DocumentTrimmer {
    public struct Side: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = Side(rawValue: 1 << 0)
        public static let bottom = Side(rawValue: 1 << 1)
        public static let left = Side(rawValue: 1 << 2)
        public static let right = Side(rawValue: 1 << 3)
        public static let topBottom: Side = [.top, .bottom]
        public static let all: Side = [.top, .bottom, .left, .right]
    }

    /// Crop away external flaps/stray paper. Default: top/bottom only (matches `--deskew`).
    public static func trimExternalContent(
        _ cgImage: CGImage,
        marginPercent: Double = 4.0,
        minTrimPercent: Double = 2.0,
        maxTrimFraction: Double = 0.35,
        sides: Side = .topBottom,
        edgeRowThreshold: Double = 0.008,
        edgeColThreshold: Double = 0.006
    ) -> CGImage {
        let maxSide = 1200
        let w0 = cgImage.width
        let h0 = cgImage.height
        let scale = min(1.0, CGFloat(maxSide) / CGFloat(max(w0, h0)))

        if scale >= 0.999 {
            return trimExternalContentFullRes(
                cgImage,
                marginPercent: marginPercent,
                minTrimPercent: minTrimPercent,
                maxTrimFraction: maxTrimFraction,
                sides: sides,
                edgeRowThreshold: edgeRowThreshold,
                edgeColThreshold: edgeColThreshold
            )
        }

        let tw = max(1, Int(CGFloat(w0) * scale))
        let th = max(1, Int(CGFloat(h0) * scale))
        guard let small = resized(cgImage, width: tw, height: th) else { return cgImage }

        guard let crop = cropBounds(
            small,
            marginPercent: marginPercent,
            minTrimPercent: minTrimPercent,
            maxTrimFraction: maxTrimFraction,
            sides: sides,
            edgeRowThreshold: edgeRowThreshold,
            edgeColThreshold: edgeColThreshold
        ) else { return cgImage }

        let sx = CGFloat(w0) / CGFloat(tw)
        let sy = CGFloat(h0) / CGFloat(th)
        let left = Int((CGFloat(crop.left) * sx).rounded())
        let top = Int((CGFloat(crop.top) * sy).rounded())
        let right = min(w0 - 1, Int((CGFloat(crop.right) * sx).rounded()))
        let bottom = min(h0 - 1, Int((CGFloat(crop.bottom) * sy).rounded()))
        guard right > left, bottom > top else { return cgImage }

        return cropCGImage(cgImage, left: left, top: top, right: right, bottom: bottom) ?? cgImage
    }

    private struct CropBounds {
        let left, top, right, bottom: Int
    }

    private static func trimExternalContentFullRes(
        _ cgImage: CGImage,
        marginPercent: Double,
        minTrimPercent: Double,
        maxTrimFraction: Double,
        sides: Side,
        edgeRowThreshold: Double,
        edgeColThreshold: Double
    ) -> CGImage {
        guard let bounds = cropBounds(
            cgImage,
            marginPercent: marginPercent,
            minTrimPercent: minTrimPercent,
            maxTrimFraction: maxTrimFraction,
            sides: sides,
            edgeRowThreshold: edgeRowThreshold,
            edgeColThreshold: edgeColThreshold
        ) else { return cgImage }
        return cropCGImage(cgImage, left: bounds.left, top: bounds.top, right: bounds.right, bottom: bounds.bottom)
            ?? cgImage
    }

    private static func cropBounds(
        _ cgImage: CGImage,
        marginPercent: Double,
        minTrimPercent: Double,
        maxTrimFraction: Double,
        sides: Side,
        edgeRowThreshold: Double,
        edgeColThreshold: Double
    ) -> CropBounds? {
        guard let rgb = rgbBytes(from: cgImage) else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let gray = grayscale(from: rgb, width: w, height: h)
        let edges = cannyLite(gray: gray, width: w, height: h)

        let x0 = Int(Double(w) * 0.08)
        let x1 = Int(Double(w) * 0.92)
        var rowFrac = [Double](repeating: 0, count: h)
        for y in 0..<h {
            var sum = 0.0
            for x in x0..<x1 {
                sum += Double(edges[y * w + x]) / 255.0
            }
            rowFrac[y] = sum / Double(max(x1 - x0, 1))
        }

        let kernel = max(5, h / 150 | 1) | 1
        let rowSmooth = gaussianSmooth1D(rowFrac, kernel: kernel)

        var contentRows: [Int] = []
        for (y, v) in rowSmooth.enumerated() where v >= edgeRowThreshold {
            contentRows.append(y)
        }
        if contentRows.count < max(20, h / 50) { return nil }

        let gap = max(5, h / 120)
        var runs: [[Int]] = []
        var start = contentRows[0]
        var prev = start
        for y in contentRows.dropFirst() {
            if y <= prev + gap {
                prev = y
            } else {
                runs.append([start, prev])
                start = y
                prev = y
            }
        }
        runs.append([start, prev])

        let mergeGap = max(30, h / 12)
        var merged = [runs[0]]
        for run in runs.dropFirst() {
            if run[0] - merged[merged.count - 1][1] <= mergeGap {
                merged[merged.count - 1][1] = run[1]
            } else {
                merged.append(run)
            }
        }

        let minRun = max(40, Int(Double(h) * 0.08))
        var substantial = merged.filter { $0[1] - $0[0] >= minRun }
        if substantial.isEmpty {
            substantial = [merged.max(by: { ($0[1] - $0[0]) < ($1[1] - $1[0]) })!]
        }

        let main = substantial.max(by: { ($0[1] - $0[0]) < ($1[1] - $1[0]) })!
        var yTop = main[0]
        var yBot = main[1]

        var xLeft = 0
        var xRight = w - 1
        var colFrac = [Double](repeating: 0, count: w)
        for y in yTop...yBot {
            for x in 0..<w {
                colFrac[x] += Double(edges[y * w + x]) / 255.0
            }
        }
        let bandRows = yBot - yTop + 1
        for x in 0..<w { colFrac[x] /= Double(bandRows) }

        let contentCols = colFrac.enumerated().compactMap { idx, v in
            v >= edgeColThreshold ? idx : nil
        }
        if contentCols.count >= max(20, w / 50) {
            xLeft = contentCols.first!
            xRight = contentCols.last!
        }

        let padY = Int(Double(h) * (marginPercent / 100.0))
        let padX = Int(Double(w) * (marginPercent / 100.0))
        var cropTop = max(0, yTop - padY)
        var cropBot = min(h - 1, yBot + padY)
        var cropLeft = max(0, xLeft - padX)
        var cropRight = min(w - 1, xRight + padX)

        if !sides.contains(.top) { cropTop = 0 }
        if !sides.contains(.bottom) { cropBot = h - 1 }
        if !sides.contains(.left) { cropLeft = 0 }
        if !sides.contains(.right) { cropRight = w - 1 }

        var trimmedTop = cropTop
        var trimmedBot = h - 1 - cropBot
        var trimmedLeft = cropLeft
        var trimmedRight = w - 1 - cropRight
        let minTrim = Int(Double(h) * (minTrimPercent / 100.0))
        let minTrimX = Int(Double(w) * (minTrimPercent / 100.0))
        let maxTrimY = Int(Double(h) * maxTrimFraction)
        let maxTrimX = Int(Double(w) * maxTrimFraction)

        if trimmedTop < minTrim || trimmedTop > maxTrimY { cropTop = 0; trimmedTop = 0 }
        if trimmedBot < minTrim || trimmedBot > maxTrimY { cropBot = h - 1; trimmedBot = 0 }
        if trimmedLeft < minTrimX || trimmedLeft > maxTrimX { cropLeft = 0; trimmedLeft = 0 }
        if trimmedRight < minTrimX || trimmedRight > maxTrimX { cropRight = w - 1; trimmedRight = 0 }

        if cropTop == 0 && cropBot == h - 1 && cropLeft == 0 && cropRight == w - 1 {
            return nil
        }

        let keepH = cropBot - cropTop + 1
        let keepW = cropRight - cropLeft + 1
        if keepH < Int(Double(h) * 0.45) || keepW < Int(Double(w) * 0.45) {
            return nil
        }

        return CropBounds(left: cropLeft, top: cropTop, right: cropRight, bottom: cropBot)
    }

    private static func cropCGImage(
        _ cgImage: CGImage,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int
    ) -> CGImage? {
        guard let rgb = rgbBytes(from: cgImage) else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        return cropRGB(rgb, width: w, height: h, left: left, top: top, right: right, bottom: bottom)
    }

    private static func resized(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func rgbBytes(from cgImage: CGImage) -> [UInt8]? {
        let w = cgImage.width
        let h = cgImage.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    private static func grayscale(from rgb: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var gray = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(rgb[i])
                let g = Double(rgb[i + 1])
                let b = Double(rgb[i + 2])
                gray[y * w + x] = UInt8(min(255, (0.299 * r + 0.587 * g + 0.114 * b).rounded()))
            }
        }
        return gray
    }

    private static func cannyLite(gray: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        let blurred = boxBlur3(gray, width: w, height: h)
        var edges = [UInt8](repeating: 0, count: w * h)
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
                let mag = min(255, Int(hypot(Double(gx), Double(gy))))
                edges[y * w + x] = mag >= 50 && mag <= 150 ? 255 : 0
            }
        }
        return edges
    }

    private static func boxBlur3(_ gray: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = gray
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var sum = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        sum += Int(gray[(y + dy) * w + (x + dx)])
                    }
                }
                out[y * w + x] = UInt8(sum / 9)
            }
        }
        return out
    }

    private static func gaussianSmooth1D(_ values: [Double], kernel: Int) -> [Double] {
        let k = kernel
        let half = k / 2
        var out = values
        for i in values.indices {
            var sum = 0.0
            var count = 0
            for j in (i - half)...(i + half) {
                if j >= 0 && j < values.count {
                    sum += values[j]
                    count += 1
                }
            }
            out[i] = sum / Double(max(count, 1))
        }
        return out
    }

    private static func cropRGB(
        _ rgb: [UInt8],
        width w: Int,
        height h: Int,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int
    ) -> CGImage? {
        let cw = right - left + 1
        let ch = bottom - top + 1
        var cropped = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            for x in 0..<cw {
                let src = ((top + y) * w + (left + x)) * 4
                let dst = (y * cw + x) * 4
                cropped[dst] = rgb[src]
                cropped[dst + 1] = rgb[src + 1]
                cropped[dst + 2] = rgb[src + 2]
                cropped[dst + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(cropped) as CFData),
              let cg = CGImage(
                width: cw,
                height: ch,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: cw * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }
        return cg
    }
}
