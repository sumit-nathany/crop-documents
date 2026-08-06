import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Disk image load/save — port of `processor._open_image`, `_apply_exif_rotation`,
/// and the format-specific save block at the end of `process_image`.
///
/// This is core pipeline logic, not platform shell: which formats we accept, how EXIF
/// orientation is baked in, and what a HEIC input saves *as* are all decisions the
/// engine owns. Both the Mac CLI and (potentially) a Mac GUI use this identically.
public enum DocumentImageIO {
    /// Input extensions the pipeline accepts — matches `processor.SUPPORTED_EXTENSIONS`.
    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif",
    ]

    public enum IOError: Error, LocalizedError {
        case cannotRead(URL, String)
        case cannotWrite(URL, String)
        case unsupportedFormat(String)

        public var errorDescription: String? {
            switch self {
            case .cannotRead(let url, let why):
                return "Cannot open \(url.lastPathComponent): \(why)"
            case .cannotWrite(let url, let why):
                return "Cannot write \(url.lastPathComponent): \(why)"
            case .unsupportedFormat(let ext):
                return "Unsupported format: \(ext)"
            }
        }
    }

    /// A loaded source image plus the raw file bytes.
    ///
    /// The bytes matter: `DocumentDetector.detectForCrop` feeds the *original* container
    /// (HEIC especially) to Vision, which detects noticeably better than a re-encoded
    /// bitmap. This mirrors the Mac CLI handing the detector a file path.
    public struct LoadedImage {
        public let cgImage: CGImage
        public let data: Data
        public let url: URL

        public init(cgImage: CGImage, data: Data, url: URL) {
            self.cgImage = cgImage
            self.data = data
            self.url = url
        }
    }

    /// Load any supported image with EXIF orientation baked into an upright bitmap.
    ///
    /// Unlike the Python path, HEIC needs no `sips` shim or `pillow-heif` dependency —
    /// ImageIO decodes it natively on Apple platforms.
    public static func load(contentsOf url: URL) throws -> LoadedImage {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw IOError.unsupportedFormat(url.pathExtension)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IOError.cannotRead(url, error.localizedDescription)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw IOError.cannotRead(url, "unrecognized image data")
        }
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw IOError.cannotRead(url, "no decodable image at index 0")
        }

        let orientation = exifOrientation(from: source)
        let upright = orientation == .up ? raw : applyOrientation(raw, orientation)

        return LoadedImage(cgImage: upright, data: data, url: url)
    }

    /// Resolve the output path for a source image — port of the save block's naming rules.
    ///
    /// HEIC/HEIF inputs become `.jpg`, everything else keeps its extension. The Python
    /// comment explains why: re-encoding HEIC is lossy and version-dependent, so JPEG is
    /// the safe universally-readable choice. Same reasoning holds here.
    public static func outputURL(for sourceURL: URL, in directory: URL) -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        let base = directory.appendingPathComponent(sourceURL.lastPathComponent)
        switch ext {
        case "jpg", "jpeg", "png", "tiff", "tif":
            return base
        default:
            // HEIC/HEIF and anything unrecognized save as JPEG under the same stem.
            return base.deletingPathExtension().appendingPathExtension("jpg")
        }
    }

    /// Write a `CGImage` to disk, picking the encoder from the destination extension.
    public static func save(_ cgImage: CGImage, to url: URL, jpegQuality: Double = 0.95) throws {
        let ext = url.pathExtension.lowercased()
        let type: UTType
        var options: [CFString: Any] = [:]

        switch ext {
        case "png":
            type = .png
        case "tiff", "tif":
            type = .tiff
        default:
            type = .jpeg
            options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw IOError.cannotWrite(url, "could not create \(type.identifier) destination")
        }
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw IOError.cannotWrite(url, "encoder rejected the image")
        }
    }

    /// All supported images under `url` (a single file or a directory), sorted by name.
    /// Non-recursive, matching `batch.collect_images`.
    public static func collectImages(at url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw IOError.cannotRead(url, "not found")
        }

        if !isDirectory.boolValue {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                throw IOError.unsupportedFormat(url.pathExtension)
            }
            return [url]
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Orientation

    private static func exifOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else { return .up }
        return orientation
    }

    /// Bake an EXIF orientation into pixels, producing an upright `.up` bitmap.
    private static func applyOrientation(
        _ cgImage: CGImage,
        _ orientation: CGImagePropertyOrientation
    ) -> CGImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        // Orientations 5–8 swap the axes.
        let swapsAxes: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let outW = Int(swapsAxes ? h : w)
        let outH = Int(swapsAxes ? w : h)

        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }

        // CGContext is bottom-left origin; each case maps the source rect into place.
        var transform = CGAffineTransform.identity
        switch orientation {
        case .up:
            break
        case .upMirrored:
            transform = CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1)
        case .down:
            transform = CGAffineTransform(translationX: w, y: h).rotated(by: .pi)
        case .downMirrored:
            transform = CGAffineTransform(translationX: 0, y: h).scaledBy(x: 1, y: -1)
        case .left:
            transform = CGAffineTransform(translationX: 0, y: w)
                .rotated(by: -.pi / 2)
        case .leftMirrored:
            transform = CGAffineTransform(translationX: h, y: w)
                .scaledBy(x: -1, y: 1)
                .rotated(by: -.pi / 2)
        case .right:
            transform = CGAffineTransform(translationX: h, y: 0)
                .rotated(by: .pi / 2)
        case .rightMirrored:
            transform = CGAffineTransform.identity
                .scaledBy(x: -1, y: 1)
                .rotated(by: .pi / 2)
        }

        ctx.concatenate(transform)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cgImage
    }
}
