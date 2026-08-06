import CoreGraphics
import DocumentCropCore
import Foundation
import ImageIO

/// `crop-documents probe-orientation <files...>` — print what the orienter thinks, and change
/// nothing. Auto-rotate has historically been the least trustworthy part of this pipeline, so
/// having a way to interrogate it on a folder of fixtures without running a full crop is worth
/// the few lines.
///
/// Output is one tab-separated row per file: `name, turn, score, margin`, where `turn` is the
/// clockwise degrees needed to make it upright and `NIL` means "not confident, would leave alone".
enum ProbeCommand {
    static func run(paths: [String]) {
        guard !paths.isEmpty else {
            print("usage: crop-documents probe-orientation <image>...")
            return
        }

        print("file\tturn\tscore\tmargin\ts0\ts90\ts180\ts270")
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                print("\(url.lastPathComponent)\tLOAD_FAIL\t-\t-")
                continue
            }

            let raw = DocumentOrienter.debugScores(image)
                .map { String(format: "%.0f", $0.score) }
                .joined(separator: "\t")

            if let assessment = DocumentOrienter.detectOrientation(image) {
                print(String(
                    format: "%@\t%d\t%.0f\t%.2f\t%@",
                    url.lastPathComponent,
                    assessment.turn.rawValue,
                    assessment.score,
                    assessment.margin,
                    raw
                ))
            } else {
                print("\(url.lastPathComponent)\tNIL\t-\t-\t\(raw)")
            }
        }
    }
}
