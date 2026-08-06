import XCTest
@testable import DocumentCropCore

final class DocumentImageIOTests: XCTestCase {
    /// The Swift CLI must accept exactly what the Python CLI accepted.
    func testSupportedExtensionsMatchPythonSet() {
        XCTAssertEqual(
            DocumentImageIO.supportedExtensions,
            ["jpg", "jpeg", "png", "tiff", "tif", "heic", "heif"]
        )
    }

    /// HEIC/HEIF save as .jpg under the same stem; every other format keeps its extension.
    func testOutputURLRewritesHEICToJPEG() {
        let dir = URL(fileURLWithPath: "/out")
        func output(_ name: String) -> String {
            DocumentImageIO.outputURL(for: URL(fileURLWithPath: "/in/\(name)"), in: dir)
                .lastPathComponent
        }
        XCTAssertEqual(output("a.HEIC"), "a.jpg")
        XCTAssertEqual(output("a.heif"), "a.jpg")
        XCTAssertEqual(output("a.jpg"), "a.jpg")
        XCTAssertEqual(output("a.png"), "a.png")
        XCTAssertEqual(output("a.tiff"), "a.tiff")
    }
}

final class DetectionPolicyTests: XCTestCase {
    /// The strict floor is what keeps iOS from accepting a 25%-area sub-region latch;
    /// the lenient floor is what keeps the Mac CLI matching Python's no-floor behaviour.
    func testPolicyFloorsDifferByPlatformIntent() {
        XCTAssertEqual(DetectionPolicy.strict.minAreaFraction, 0.35)
        XCTAssertLessThan(DetectionPolicy.lenient.minAreaFraction, 0.35)

        #if canImport(UIKit)
        XCTAssertEqual(DetectionPolicy.platformDefault, .strict)
        #else
        XCTAssertEqual(DetectionPolicy.platformDefault, .lenient)
        #endif
    }
}

final class CropSettingsTests: XCTestCase {
    /// Deskew widens the initial border so the later flap trim doesn't snug against ink.
    func testDeskewAddsBorderHeadroom() {
        let plain = CropSettings(expansionPercent: 4, straighten: false)
        let aligned = CropSettings(expansionPercent: 4, straighten: true)
        XCTAssertEqual(plain.borderPercent, 4)
        XCTAssertEqual(aligned.borderPercent, 4 + CropConstants.deskewBorderExtraPercent)
    }

    /// Straighten stays off by default — it is not yet trusted on real photos.
    func testStraightenDefaultsOff() {
        XCTAssertFalse(CropSettings().straighten)
    }
}
