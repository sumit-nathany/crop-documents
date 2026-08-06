import CoreTransferable
import UniformTypeIdentifiers
import UIKit

/// Makes a cropped UIImage shareable via ShareLink / drag-and-drop.
struct ShareableImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { value in
            value.image.jpegData(compressionQuality: 0.95)
                ?? Data()
        }
    }
}
