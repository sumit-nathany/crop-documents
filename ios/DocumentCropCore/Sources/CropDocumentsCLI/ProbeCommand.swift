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
    /// `crop-documents probe-trim <files...>` — report the trimmer's row analysis for each
    /// file. Use it against the Python reference (`processor.trim_external_content`) when
    /// the two disagree about where the document ends and a flap begins.
    static func runTrim(paths: [String]) {
        guard !paths.isEmpty else {
            print("usage: crop-documents probe-trim <image>...")
            return
        }

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                print("\(url.lastPathComponent): LOAD_FAIL")
                continue
            }

            print("\(url.lastPathComponent)  (\(image.width)x\(image.height))")
            guard let d = DocumentTrimmer.diagnose(image) else {
                print("  no analysis — too few content rows, trim would be skipped")
                continue
            }
            print("  analysis   \(d.analysisWidth)x\(d.analysisHeight)  kernel=\(d.smoothKernel)")
            print("  contentRows=\(d.contentRowCount) first=\(d.firstContentRow) last=\(d.lastContentRow)")
            print("  gap=\(d.gap) mergeGap=\(d.mergeGap) runs=\(d.runCount)")
            print("  merged     \(d.mergedRuns)")
            print("  minRun=\(d.minRun) substantial=\(d.substantialRuns)")
            print("  MAIN BLOCK y_top=\(d.mainBlock[0]) y_bot=\(d.mainBlock[1])")
        }
    }

    /// `crop-documents probe-skew <files...>` — print the raw deskew angle estimate.
    /// Compare against `processor._estimate_skew_angle` on the same post-warp image.
    static func runSkew(paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                print("\(url.lastPathComponent): LOAD_FAIL")
                continue
            }
            if let angle = DocumentWarper.debugEstimateSkewDegrees(image) {
                print(String(format: "%@: %.4f", url.lastPathComponent, angle))
            } else {
                print("\(url.lastPathComponent): nil (no signal — would not rotate)")
            }
        }
    }

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
