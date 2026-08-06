import Combine
import DocumentCropCore
import Photos
import SwiftUI
import UIKit

@MainActor
final class AppStore: ObservableObject {
    @Published var settings: CropSettings
    @Published var jobs: [CropJob] = []
    @Published var isProcessing = false
    @Published var statusMessage: String?
    @Published var showSettings = false
    @Published var logLines: [String] = []
    @Published var needsLibraryReadAccess = false

    private let defaults = UserDefaults.standard
    private var logTimer: Timer?

    init() {
        let expansion = defaults.object(forKey: "expansionPercent") as? Double ?? 4.0
        // Straighten/deskew is force-disabled while its UI toggle is hidden (see SettingsView) —
        // ignore any previously-persisted value so a prior install that had it on doesn't silently
        // keep using it with no way to turn it off from the UI.
        let enhance = defaults.object(forKey: "enhance") as? Bool ?? false
        settings = CropSettings(expansionPercent: expansion, straighten: false, enhance: enhance)
        refreshLogs()
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLogs() }
        }
    }

    deinit {
        logTimer?.invalidate()
    }

    func refreshLogs() {
        logLines = CropLogger.shared.snapshot()
    }

    func clearLogs() {
        CropLogger.shared.clear()
        refreshLogs()
    }

    func persistSettings() {
        defaults.set(settings.expansionPercent, forKey: "expansionPercent")
        defaults.set(settings.straighten, forKey: "straighten")
        defaults.set(settings.enhance, forKey: "enhance")
    }

    func enqueue(_ photos: [LoadedPhoto]) {
        let newJobs = photos.map { CropJob(source: $0.image, sourceData: $0.data) }
        jobs.append(contentsOf: newJobs)
        CropLogger.shared.info("Queued \(photos.count) photo(s)")
        Task { await processPending() }
    }

    /// Full library **read** access is required to get original HEIC bytes via `PHAsset` — the
    /// same bytes the Mac CLI reads from disk. "Add Photos Only" (write-only) or "Limited" (unless
    /// the picked photo is in the limited grant) both leave us stuck with PhotosPicker's transcoded
    /// JPEG, which Vision segmentation mis-detects far more often than the true HEIC.
    func ensureLibraryReadAccess() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized, .limited:
            needsLibraryReadAccess = false
        case .denied, .restricted, .notDetermined:
            needsLibraryReadAccess = true
        @unknown default:
            needsLibraryReadAccess = true
        }
    }

    func remove(_ job: CropJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }

    func processPending() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        for index in jobs.indices {
            guard case .pending = jobs[index].state else { continue }
            jobs[index].state = .processing
            statusMessage = "\(index + 1) of \(jobs.count)"

            let source = jobs[index].source
            let sourceData = jobs[index].sourceData
            let settings = self.settings
            do {
                let (image, result) = try await Task.detached(priority: .userInitiated) {
                    try DocumentCropper.crop(image: source, imageData: sourceData, settings: settings)
                }.value
                jobs[index].state = .done(image: image, confidence: result.confidence)
                CropLogger.shared.success(
                    String(format: "Job %d done (confidence %.1f%%)", index + 1, result.confidence * 100)
                )
            } catch {
                jobs[index].state = .failed(message: error.localizedDescription)
                CropLogger.shared.error("Job \(index + 1) failed: \(error.localizedDescription)")
            }
            refreshLogs()
        }
        statusMessage = nil
    }

    func saveSuccessfulToPhotos() async -> String {
        let images: [UIImage] = jobs.compactMap {
            if case .done(let image, _) = $0.state { return image }
            return nil
        }
        guard !images.isEmpty else { return "Nothing to save yet." }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Photo access is needed to save. You can enable it in Settings."
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
            return images.count == 1
                ? "Saved to Photos."
                : "Saved \(images.count) photos."
        } catch {
            return "Couldn’t save: \(error.localizedDescription)"
        }
    }
}

struct LoadedPhoto {
    let image: UIImage
    let data: Data?
}

struct CropJob: Identifiable {
    enum State {
        case pending
        case processing
        case done(image: UIImage, confidence: Float)
        case failed(message: String)

        var isTerminal: Bool {
            switch self {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let source: UIImage
    let sourceData: Data?
    var state: State = .pending
}
