import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Loads the original image file from PhotosPicker without JPEG transcode.
struct OriginalPhotoFile: Transferable {
    let data: Data
    let contentType: UTType

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let data = try Data(contentsOf: received.file)
            let ext = received.file.pathExtension.lowercased()
            let type: UTType
            switch ext {
            case "heic", "heif": type = .heic
            case "png": type = .png
            case "tiff", "tif": type = .tiff
            default: type = .jpeg
            }
            return OriginalPhotoFile(data: data, contentType: type)
        }
    }
}
