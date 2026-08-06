import CoreGraphics
import XCTest
@testable import DocumentCropCore

/// Auto-rotate is the least-trusted part of this pipeline historically, so these tests pin
/// the *contract* — what it promises and what it refuses — rather than exercising Vision,
/// which needs real photographs. End-to-end verification against rotated fixtures lives in
/// `lab/` and is driven by `crop-documents probe-orientation`.
final class DocumentOrienterTests: XCTestCase {
    /// A turn's Vision orientation must be the one that reads text at that turn.
    func testQuarterTurnMapsToExpectedExifOrientation() {
        XCTAssertEqual(DocumentOrienter.QuarterTurn.none.orientation, .up)
        XCTAssertEqual(DocumentOrienter.QuarterTurn.clockwise90.orientation, .right)
        XCTAssertEqual(DocumentOrienter.QuarterTurn.rotate180.orientation, .down)
        XCTAssertEqual(DocumentOrienter.QuarterTurn.counterClockwise90.orientation, .left)
    }

    func testQuarterTurnRawValuesAreDegrees() {
        XCTAssertEqual(DocumentOrienter.QuarterTurn.none.rawValue, 0)
        XCTAssertEqual(DocumentOrienter.QuarterTurn.clockwise90.rawValue, 90)
        XCTAssertEqual(DocumentOrienter.QuarterTurn.rotate180.rawValue, 180)
        XCTAssertEqual(DocumentOrienter.QuarterTurn.counterClockwise90.rawValue, 270)
    }

    /// Margin is the fraction by which the winning axis beat the other. A shutout is 1.0;
    /// a tie is 0. The gate in `detectOrientation` is expressed in these terms.
    func testMarginReflectsSeparationBetweenAxes() {
        func margin(_ winner: Double, _ runnerUp: Double) -> Double {
            DocumentOrienter.Assessment(turn: .none, score: winner, runnerUpScore: runnerUp)
                .margin
        }
        XCTAssertEqual(margin(100, 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(margin(100, 50), 0.5, accuracy: 0.001)
        XCTAssertEqual(margin(100, 100), 0.0, accuracy: 0.001)
        // Guard against a divide-by-zero when nothing was recognized at all.
        XCTAssertEqual(margin(0, 0), 0.0)
    }

    /// A blank image gives Vision nothing to read, so the orienter must decline rather than
    /// pick arbitrarily. This is the "leave it alone" path that keeps a no-text scan safe.
    func testBlankImageIsDeclinedRatherThanGuessed() throws {
        let blank = try XCTUnwrap(solidImage(width: 400, height: 600))
        XCTAssertNil(DocumentOrienter.detectOrientation(blank))
        // autoRotate must be a no-op in that case, returning the same dimensions.
        let result = DocumentOrienter.autoRotate(blank)
        XCTAssertEqual(result.width, 400)
        XCTAssertEqual(result.height, 600)
    }

    private func solidImage(width: Int, height: Int) -> CGImage? {
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
        return ctx.makeImage()
    }
}
