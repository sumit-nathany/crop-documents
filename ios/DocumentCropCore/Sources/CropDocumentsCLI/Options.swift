import DocumentCropCore
import Foundation

/// Parsed command line. Flag names and defaults mirror `batch.py` exactly so existing
/// muscle memory and scripts keep working.
struct Options {
    var input: URL
    var output: URL?
    var expansion: Double = 4.0
    var deskew = false
    var rotate = false
    var enhance = false
    var watch = false
    /// Kept as the raw argument, not a URL: `URL(fileURLWithPath:)` resolves a relative path
    /// against the process CWD immediately, which would lose the distinction between
    /// "receipts.pdf" (meaning: in the output directory) and an explicit absolute path.
    var pdf: String?
    var jpegQuality: Double = 0.95
    var verbose = false

    var settings: CropSettings {
        CropSettings(
            expansionPercent: expansion,
            straighten: deskew,
            enhance: enhance,
            autoRotate: rotate
        )
    }

    /// Where the `--pdf` file should land. A bare name goes in the output directory (matching
    /// `batch.py`); an absolute path is honoured as given.
    static func resolvePDFURL(_ argument: String, outputDirectory: URL) -> URL {
        argument.hasPrefix("/")
            ? URL(fileURLWithPath: argument)
            : outputDirectory.appendingPathComponent(argument)
    }

    /// Output directory, defaulting to the input folder (or the file's parent).
    func resolvedOutputDirectory() -> URL {
        if let output { return output }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? input : input.deletingLastPathComponent()
    }
}

enum OptionsError: Error, LocalizedError {
    case unknownFlag(String)
    case missingValue(String)
    case badNumber(String, String)
    case watchNeedsDirectory

    var errorDescription: String? {
        switch self {
        case .unknownFlag(let f):
            return "Unknown option: \(f)  (try --help)"
        case .missingValue(let f):
            return "\(f) requires a value."
        case .badNumber(let f, let v):
            return "\(f) expects a number, got '\(v)'."
        case .watchNeedsDirectory:
            return "--watch requires a directory as --input."
        }
    }
}

extension Options {
    static let usage = """
    crop-documents — auto-crop document photos with Apple Vision.

    USAGE
      crop-documents [options]

    OPTIONS
      -i, --input <path>        Image file or folder of images (default: current directory)
      -o, --output <dir>        Output directory (default: same folder as --input)
      -e, --expansion <pct>     Border expanded beyond the detected edges (default: 4)
      -d, --deskew              Align: keystone refine, micro-rotation, top/bottom flap trim
      -r, --rotate              Straighten a sideways page via Vision text detection.
                                Does not flip 180° — see DocumentOrienter for why.
      -a, --enhance             Apple Photos CoreImage auto-enhancement
      -w, --watch               Watch the input folder and process new images as they land
          --pdf <name>          Combine the cropped images into one PDF in the output dir
          --jpeg-quality <0-1>  JPEG encode quality (default: 0.95)
      -v, --verbose             Print the full pipeline log for each image
      -h, --help                Show this help

    EXAMPLES
      crop-documents --input ./photos/
      crop-documents --input ./photos/ --deskew --rotate --pdf receipts.pdf
    """

    /// Parse `batch.py`-compatible arguments. Returns nil when `--help` was requested.
    static func parse(_ args: [String]) throws -> Options? {
        var options = Options(input: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var index = 0

        /// Consume the value following a flag.
        func nextValue(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw OptionsError.missingValue(flag) }
            return args[index]
        }

        func number(_ flag: String) throws -> Double {
            let raw = try nextValue(flag)
            guard let value = Double(raw) else { throw OptionsError.badNumber(flag, raw) }
            return value
        }

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                return nil
            case "-i", "--input":
                options.input = URL(fileURLWithPath: try nextValue(arg)).standardizedFileURL
            case "-o", "--output":
                options.output = URL(fileURLWithPath: try nextValue(arg)).standardizedFileURL
            case "-e", "--expansion":
                options.expansion = try number(arg)
            case "-d", "--deskew":
                options.deskew = true
            case "-r", "--rotate":
                options.rotate = true
            case "-a", "--enhance":
                options.enhance = true
            case "-w", "--watch":
                options.watch = true
            case "--pdf":
                options.pdf = try nextValue(arg)
            case "--jpeg-quality":
                options.jpegQuality = try number(arg)
            case "-v", "--verbose":
                options.verbose = true
            default:
                throw OptionsError.unknownFlag(arg)
            }
            index += 1
        }

        if options.watch {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: options.input.path, isDirectory: &isDirectory)
            guard isDirectory.boolValue else { throw OptionsError.watchNeedsDirectory }
        }

        return options
    }
}
