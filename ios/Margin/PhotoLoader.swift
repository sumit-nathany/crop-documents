import DocumentCropCore
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Load full-resolution photos, preferring untranscoded originals (HEIC) like the Mac CLI.
enum PhotoLoader {
    static func loadFullResolution(from item: PhotosPickerItem) async -> LoadedPhoto? {
        // 1) PHAsset original resource bytes (HEIC on iPhone) — PhotosPicker file transfer often JPEG.
        if let id = item.itemIdentifier {
            // NB: PhotosPicker selection runs out-of-process and grants this item's bytes via
            // Transferable regardless of Photos permission — it does NOT imply the app can
            // resolve `id` through PHAsset. If the app only has limited library access and this
            // asset isn't in the limited grant, `fetchAssets` returns zero results below, even
            // though the user just picked this exact photo. That's expected, not an error.
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                if let asset = assets.firstObject {
                    if let photo = await loadOriginalResource(from: asset) {
                        return photo
                    }
                    if let photo = await loadFromPHAsset(asset) {
                        CropLogger.shared.info("Loaded via PHAsset imageData (\(photo.data?.count ?? 0) bytes)")
                        return photo
                    }
                    CropLogger.shared.warn("PHAsset fetch failed for \(id)")
                } else {
                    CropLogger.shared.warn(
                        "PHAsset \(id) not resolvable (likely outside limited-library grant) — using picker fallback"
                    )
                }
            } else {
                CropLogger.shared.warn("Photo library access denied (status=\(status.rawValue)) — using picker fallback")
            }
        } else {
            CropLogger.shared.warn("No itemIdentifier — PHAsset unavailable")
        }

        // 2) File transfer and raw Data both go through the picker's Transferable pipeline —
        // neither is guaranteed HEIC. Load both candidates and prefer whichever is actually HEIC.
        var fileCandidate: LoadedPhoto?
        var fileLabel = "?"
        if let file = try? await item.loadTransferable(type: OriginalPhotoFile.self),
           let image = UIImage(data: file.data, orientationFromEXIF: true) {
            fileLabel = file.contentType.preferredFilenameExtension ?? sniffExtension(file.data)
            fileCandidate = LoadedPhoto(image: image, data: file.data)
        }

        var dataCandidate: LoadedPhoto?
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data, orientationFromEXIF: true) {
            dataCandidate = LoadedPhoto(image: image, data: data)
        }

        if let file = fileCandidate, fileLabel == "heic" {
            CropLogger.shared.info("Loaded via file transfer .heic (\(file.data?.count ?? 0) bytes)")
            return file
        }
        if let data = dataCandidate, sniffExtension(data.data ?? Data()) == "heic" {
            CropLogger.shared.info("Loaded via picker Data .heic (\(data.data?.count ?? 0) bytes)")
            return data
        }
        if let file = fileCandidate {
            CropLogger.shared.info(
                "Loaded via file transfer .\(fileLabel) (\(file.data?.count ?? 0) bytes) — transcoded, not HEIC"
            )
            return file
        }
        if let data = dataCandidate {
            CropLogger.shared.info("Loaded via picker Data (\(data.data?.count ?? 0) bytes) — may be transcoded")
            return data
        }

        return nil
    }

    /// Original file on disk (HEIC/JPEG) via `PHAssetResourceManager` — matches Mac reading the file.
    private static func loadOriginalResource(from asset: PHAsset) async -> LoadedPhoto? {
        guard let resource = preferredResource(for: asset) else { return nil }

        let data: Data? = await withCheckedContinuation { continuation in
            var buffer = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                buffer.append(chunk)
            } completionHandler: { error in
                if let error {
                    CropLogger.shared.warn("PHAsset resource error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: buffer.isEmpty ? nil : buffer)
                }
            }
        }

        guard let data,
              let image = UIImage(data: data, orientationFromEXIF: true)
        else { return nil }

        let ext = sniffExtension(data)
        CropLogger.shared.info(
            "Loaded via PHAsset resource .\(ext) (\(data.count) bytes, \(resource.uniformTypeIdentifier))"
        )
        return LoadedPhoto(image: image, data: data)
    }

    private static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let order: [PHAssetResourceType] = [.photo, .fullSizePhoto, .alternatePhoto]
        for type in order {
            if let match = resources.first(where: { $0.type == type }) {
                return match
            }
        }
        return resources.first
    }

    private static func loadFromPHAsset(_ asset: PHAsset) async -> LoadedPhoto? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.version = .current

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, orientation, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    CropLogger.shared.warn("PHAsset load error: \(error.localizedDescription)")
                }
                if info?[PHImageResultIsDegradedKey] as? Bool == true {
                    CropLogger.shared.warn("PHAsset returned degraded preview")
                }
                guard let data,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                if let uti {
                    CropLogger.shared.info("PHAsset UTI: \(uti)")
                }
                let uiOrientation = UIImage.Orientation(orientation)
                let image = UIImage(cgImage: cg, scale: 1.0, orientation: uiOrientation)
                continuation.resume(returning: LoadedPhoto(image: image, data: data))
            }
        }
    }

    private static func sniffExtension(_ data: Data) -> String {
        guard data.count > 12 else { return "?" }
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<min(12, bytes.count)], encoding: .ascii) ?? ""
            if brand.contains("heic") || brand.contains("heif") || brand.contains("mif1") {
                return "heic"
            }
        }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "jpg" }
        if bytes[0] == 0x89, bytes[1] == 0x50 { return "png" }
        return "?"
    }
}

extension UIImage {
    convenience init?(data: Data, orientationFromEXIF: Bool) {
        guard orientationFromEXIF else {
            self.init(data: data)
            return
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            self.init(data: data)
            return
        }

        var orientation: UIImage.Orientation = .up
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exifOrient = props[kCGImagePropertyOrientation] as? UInt32,
           let exif = CGImagePropertyOrientation(rawValue: exifOrient) {
            orientation = UIImage.Orientation(exif)
        }

        self.init(cgImage: cg, scale: 1.0, orientation: orientation)
    }
}

extension UIImage.Orientation {
    init(_ exif: CGImagePropertyOrientation) {
        switch exif {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
