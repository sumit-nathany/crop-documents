import CoreGraphics
import Foundation

/// Multi-page PDF assembly — port of `pdf_builder.build_pdf`.
///
/// Each page is sized exactly to its source image in points, so there are no white
/// margins and no rescaling. That's the same guarantee `img2pdf` gave the Python
/// path, achieved here with CoreGraphics' native PDF context (no third-party dep).
public enum DocumentPDFBuilder {
    public enum PDFError: Error, LocalizedError {
        case noImages
        case cannotCreate(URL)

        public var errorDescription: String? {
            switch self {
            case .noImages:
                return "No valid images to combine into a PDF."
            case .cannotCreate(let url):
                return "Could not create PDF at \(url.path)."
            }
        }
    }

    public struct Report {
        public let pageCount: Int
        public let skipped: [URL]
    }

    /// Combine images into a single PDF, one page per image at native pixel dimensions.
    /// Missing or undecodable files are skipped and reported rather than aborting.
    @discardableResult
    public static func build(from imageURLs: [URL], to outputURL: URL) throws -> Report {
        guard !imageURLs.isEmpty else { throw PDFError.noImages }

        var pages: [CGImage] = []
        var skipped: [URL] = []
        for url in imageURLs {
            guard FileManager.default.fileExists(atPath: url.path),
                  let loaded = try? DocumentImageIO.load(contentsOf: url)
            else {
                skipped.append(url)
                continue
            }
            pages.append(loaded.cgImage)
        }

        guard !pages.isEmpty else { throw PDFError.noImages }

        // A nil mediaBox means "size each page when it's begun" — which is what we do below.
        guard let ctx = CGContext(outputURL as CFURL, mediaBox: nil, nil) else {
            throw PDFError.cannotCreate(outputURL)
        }

        for page in pages {
            var box = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            let info = [kCGPDFContextMediaBox as String: Data(
                bytes: &box, count: MemoryLayout<CGRect>.size
            )] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.draw(page, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        return Report(pageCount: pages.count, skipped: skipped)
    }
}
