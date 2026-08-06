import DocumentCropCore
import Foundation

/// Batch + watch orchestration — port of `batch.run_batch` / `batch.run_watch`.
/// Console formatting is intentionally kept identical to the Python CLI's.
struct BatchRunner {
    let options: Options

    /// Returns true when at least one image was cropped successfully.
    @discardableResult
    func runBatch() -> Bool {
        let outputDirectory = options.resolvedOutputDirectory()

        let images: [URL]
        do {
            images = try DocumentImageIO.collectImages(at: options.input)
        } catch {
            print("❌  \(error.localizedDescription)")
            return false
        }

        guard !images.isEmpty else {
            print("⚠️  No supported images found.")
            return false
        }

        printHeader(count: images.count, outputDirectory: outputDirectory)

        var skipped: [String] = []
        var produced: [URL] = []

        for (offset, imageURL) in images.enumerated() {
            print("[\(offset + 1)/\(images.count)] \(imageURL.lastPathComponent)")
            switch process(imageURL, into: outputDirectory) {
            case .success(let outcome):
                produced.append(outcome.output)
            case .failure(let reason):
                skipped.append("\(imageURL.lastPathComponent): \(reason)")
            }
        }

        printSummary(total: images.count, succeeded: produced.count, skipped: skipped,
                     outputDirectory: outputDirectory)

        if !produced.isEmpty, let pdfName = options.pdf {
            buildPDF(from: produced, name: pdfName, outputDirectory: outputDirectory)
        }

        return !produced.isEmpty
    }

    /// Poll the input folder for new images. Mirrors the Python watchdog behaviour without
    /// the dependency — a 1s poll is plenty for a folder someone is dropping photos into.
    func runWatch() {
        let outputDirectory = options.resolvedOutputDirectory()
        print("👀  Watching \(options.input.path)/ for new images. Press Ctrl+C to stop.\n")

        var seen = Set((try? DocumentImageIO.collectImages(at: options.input))?
            .map(\.lastPathComponent) ?? [])

        while true {
            Thread.sleep(forTimeInterval: 1.0)
            guard let current = try? DocumentImageIO.collectImages(at: options.input) else { continue }

            for imageURL in current where !seen.contains(imageURL.lastPathComponent) {
                seen.insert(imageURL.lastPathComponent)
                // Let the file finish being written before reading it.
                Thread.sleep(forTimeInterval: 0.5)
                print("\n🆕  New file detected: \(imageURL.lastPathComponent)")
                if case .failure(let reason) = process(imageURL, into: outputDirectory) {
                    print("  ⚠️  Skipped (\(reason))")
                }
            }
        }
    }

    // MARK: - Single image

    private enum Outcome {
        case success(DocumentCropper.FileOutcome)
        case failure(String)
    }

    private func process(_ imageURL: URL, into outputDirectory: URL) -> Outcome {
        // The core logs into a shared ring buffer; clear it so --verbose shows only this image.
        CropLogger.shared.clear()

        do {
            let outcome = try DocumentCropper.cropFile(
                at: imageURL,
                outputDirectory: outputDirectory,
                settings: options.settings,
                jpegQuality: options.jpegQuality
            )
            if options.verbose { printLog() }
            let confidence = String(format: "%.2f", outcome.confidence)
            let enhanced = options.enhance ? " ✨ enhanced" : ""
            print("  ✅  Saved → \(outcome.output.lastPathComponent) (confidence \(confidence))\(enhanced)")
            return .success(outcome)
        } catch let error as CropError {
            if options.verbose { printLog() }
            let reason = error.errorDescription ?? "\(error)"
            print("  ⚠️  Skipped (\(reason))")
            return .failure(reason)
        } catch {
            if options.verbose { printLog() }
            print("  ❌  Error: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    private func printLog() {
        for line in CropLogger.shared.snapshot() {
            print("      \(line)")
        }
    }

    // MARK: - Output

    private func printHeader(count: Int, outputDirectory: URL) {
        print("\n📂  Processing \(count) image(s) → \(outputDirectory.path)/")
        print("🔍  Expansion border: \(trim(options.expansion))%")
        if options.deskew {
            let border = options.expansion + CropConstants.deskewBorderExtraPercent
            print("""
            📐  Align (deskew): ON (border \(trim(border))% \
            — +\(trim(CropConstants.deskewBorderExtraPercent)) for trim headroom)
            """)
        }
        if options.rotate {
            print("🔄  Auto-rotate: ON (Vision text orientation)")
        }
        if options.enhance {
            print("✨  Auto-enhance: ON (Apple CoreImage)")
        }
        print("")
    }

    private func printSummary(total: Int, succeeded: Int, skipped: [String], outputDirectory: URL) {
        let rule = String(repeating: "━", count: 48)
        print("\n\(rule)")
        print("  ✅  Processed : \(succeeded)/\(total)")
        print("  ⚠️  Skipped   : \(skipped.count)/\(total)")
        print(rule)

        guard !skipped.isEmpty else { return }
        let logURL = outputDirectory.appendingPathComponent("skipped.txt")
        try? skipped.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        print("\n  Skipped log → \(logURL.path)")
    }

    private func buildPDF(from images: [URL], name: URL, outputDirectory: URL) {
        let pdfURL = name.path.hasPrefix("/")
            ? name
            : outputDirectory.appendingPathComponent(name.lastPathComponent)
        print("\n📄  Combining \(images.count) image(s) into PDF: \(pdfURL.lastPathComponent)")
        do {
            let report = try DocumentPDFBuilder.build(from: images, to: pdfURL)
            for missing in report.skipped {
                print("⚠️  Skipping missing image file: \(missing.lastPathComponent)")
            }
            print("✅  Successfully created PDF → \(pdfURL.path)")
        } catch {
            print("❌  Error generating PDF: \(error.localizedDescription)")
        }
    }

    /// Format a Double without a trailing `.0` — matches Python's `%g`.
    private func trim(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%g", value)
    }
}
