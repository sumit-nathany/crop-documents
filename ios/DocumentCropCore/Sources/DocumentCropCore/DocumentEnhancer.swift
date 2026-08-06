import CoreGraphics
import CoreImage
import Foundation

/// Native Apple Photos auto-enhance. Runs in-process; the Python CLI shelled out to a
/// separate compiled binary for this and silently no-op'd when it wasn't built.
public enum DocumentEnhancer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Apply CoreImage auto-adjustment filters (exposure, contrast, tone, color).
    public static func enhance(_ cgImage: CGImage) -> CGImage {
        let ciImage = CIImage(cgImage: cgImage)
        let options: [CIImageAutoAdjustmentOption: Any] = [
            .enhance: true,
            .redEye: false,
        ]
        let filters = ciImage.autoAdjustmentFilters(options: options)

        var current = ciImage
        for filter in filters {
            filter.setValue(current, forKey: kCIInputImageKey)
            if let result = filter.outputImage {
                current = result
            }
        }

        let extent = current.extent.integral
        guard let output = context.createCGImage(current, from: extent) else {
            return cgImage
        }
        return output
    }
}
