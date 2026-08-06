import CoreGraphics
import XCTest
@testable import DocumentCropCore

/// The trimmer has diverged from the Python reference twice, both times through the edge
/// detector rather than the run analysis. These tests pin the properties that broke.
final class DocumentTrimmerTests: XCTestCase {
    /// A page with a detached flap above it must read as **two** blocks. If the edge map is
    /// too dense — the pre-NMS failure — sparse texture bridges the void, the runs merge, and
    /// the flap never gets trimmed.
    func testDetachedFlapReadsAsSeparateBlock() throws {
        let image = try XCTUnwrap(syntheticFlapPage())
        let d = try XCTUnwrap(DocumentTrimmer.diagnose(image))

        XCTAssertGreaterThanOrEqual(
            d.mergedRuns.count, 2,
            "flap and page merged into one block (\(d.mergedRuns)) — edge map is too dense"
        )

        // The main block should be the page, not the small flap.
        let mainHeight = d.mainBlock[1] - d.mainBlock[0]
        XCTAssertGreaterThan(mainHeight, d.analysisHeight / 3)
        XCTAssertGreaterThan(d.mainBlock[0], 0, "main block should start below the flap")
    }

    /// Trimming that block off must actually shrink the image.
    func testFlapIsTrimmedAway() throws {
        let image = try XCTUnwrap(syntheticFlapPage())
        let trimmed = DocumentTrimmer.trimExternalContent(image, marginPercent: 4)
        XCTAssertLessThan(trimmed.height, image.height, "flap was not trimmed")
    }

    /// A page with no flap must come back untouched — over-trimming destroys good crops,
    /// which is what the Canny-as-a-band bug did (it cut 30% off a clean image).
    func testCleanPageIsLeftAlone() throws {
        let image = try XCTUnwrap(syntheticCleanPage())
        let trimmed = DocumentTrimmer.trimExternalContent(image, marginPercent: 4)
        XCTAssertEqual(trimmed.height, image.height, "clean page should not be trimmed")
        XCTAssertEqual(trimmed.width, image.width)
    }

    /// The analysis downscale is load-bearing: several thresholds derive from the analysis
    /// height, and at 1200 the smoothing kernel gets small enough to bridge a real gap.
    func testAnalysisResolutionIsHighEnoughToSeparateBlocks() {
        XCTAssertGreaterThanOrEqual(
            DocumentTrimmer.analysisMaxSide, 1600,
            "below 1600 the flap void closes up and trims stop firing"
        )
    }

    // MARK: - Fixtures

    /// A tall page of text lines with a small detached "flap" strip at the top, separated by
    /// a wide blank void — the shape `trim_external_content` exists to handle.
    private func syntheticFlapPage() -> CGImage? {
        draw(width: 900, height: 2400) { ctx in
            // Flap: a short band of content at the very top.
            textLines(ctx, from: 60, to: 200, width: 900)
            // Void from y=200 to y=800 stays blank.
            // Page: the main body.
            textLines(ctx, from: 820, to: 2340, width: 900)
        }
    }

    private func syntheticCleanPage() -> CGImage? {
        draw(width: 900, height: 2400) { ctx in
            textLines(ctx, from: 60, to: 2340, width: 900)
        }
    }

    /// Horizontal dark bars standing in for lines of text.
    private func textLines(_ ctx: CGContext, from y0: Int, to y1: Int, width: Int) {
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        var y = y0
        while y < y1 {
            ctx.fill(CGRect(x: 90, y: y, width: width - 180, height: 14))
            y += 40
        }
    }

    private func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        body(ctx)
        return ctx.makeImage()
    }
}
