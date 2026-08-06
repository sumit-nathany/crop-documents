import DocumentCropCore
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var saveToast: String?
    @State private var previewImage: UIImage?
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.clearFinished()
                        showPicker = true
                    } label: {
                        Label("Choose Photos", systemImage: "photo.on.rectangle")
                    }
                    .photosPicker(
                        isPresented: $showPicker,
                        selection: $pickerItems,
                        maxSelectionCount: 30,
                        matching: .images
                    )

                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                } footer: {
                    if store.needsLibraryReadAccess {
                        Button("Enable “All Photos” access in Settings for the best crop quality") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.footnote)
                    }
                }

                if !store.jobs.isEmpty {
                    Section {
                        if store.isProcessing, let status = store.statusMessage {
                            HStack {
                                ProgressView()
                                Text(status)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(store.jobs) { job in
                            JobRow(job: job)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if case .done(let image, _) = job.state {
                                        previewImage = image
                                        showPreview = true
                                    }
                                }
                                .swipeActions {
                                    Button("Remove", role: .destructive) {
                                        store.remove(job)
                                    }
                                }
                        }
                    } header: {
                        Text("Results")
                    } footer: {
                        if store.jobs.contains(where: {
                            if case .done = $0.state { return true }
                            return false
                        }) {
                            Button("Save All to Photos") {
                                Task {
                                    let msg = await store.saveSuccessfulToPhotos()
                                    saveToast = msg
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    saveToast = nil
                                }
                            }
                        }
                    }
                }

                Section("Debug log") {
                    if store.logLines.isEmpty {
                        Text("Logs appear here when you crop a photo.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(store.logLines.suffix(40).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    HStack {
                        Button("Copy") {
                            UIPasteboard.general.string = store.logLines.joined(separator: "\n")
                        }
                        Spacer()
                        Button("Clear", role: .destructive) {
                            store.clearLogs()
                        }
                    }
                    .font(.footnote)
                }
            }
            .navigationTitle("Margin")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") {
                        store.showSettings = true
                    }
                }
            }
            .sheet(isPresented: $store.showSettings) {
                SettingsView()
                    .environmentObject(store)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    if let image {
                        let data = image.jpegData(compressionQuality: 0.98)
                        store.enqueue([LoadedPhoto(image: image, data: data)])
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showPreview) {
                if let previewImage {
                    CroppedImagePreview(image: previewImage) {
                        showPreview = false
                    }
                }
            }
            .onChange(of: pickerItems) { _, items in
                Task { await loadPickerItems(items) }
            }
            .task {
                await store.ensureLibraryReadAccess()
            }
            .overlay(alignment: .bottom) {
                if let saveToast {
                    Text(saveToast)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private func loadPickerItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var photos: [LoadedPhoto] = []
        for item in items {
            if let photo = await PhotoLoader.loadFullResolution(from: item) {
                photos.append(photo)
            } else {
                CropLogger.shared.warn("Could not load a selected photo")
            }
        }
        pickerItems = []
        store.refreshLogs()
        if !photos.isEmpty {
            store.enqueue(photos)
        }
    }
}

struct CroppedImagePreview: View {
    let image: UIImage
    let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = max(1, min(lastZoom * value, 6))
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                            if zoom == 1 { offset = .zero; lastOffset = .zero }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        zoom = 1
                        lastZoom = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    Spacer()
                    ShareLink(
                        item: ShareableImage(image: image),
                        preview: SharePreview("Cropped", image: Image(uiImage: image))
                    ) {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                }
                .padding()
                Spacer()
            }
        }
    }
}

struct JobRow: View {
    let job: CropJob

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 56, height: 72)
                .clipped()
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(subtitleColor)
                }
            }

            Spacer(minLength: 0)

            if case .done(let image, _) = job.state {
                ShareLink(
                    item: ShareableImage(image: image),
                    preview: SharePreview("Cropped", image: Image(uiImage: image))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var subtitleColor: Color {
        if case .done(_, let confidence) = job.state, confidence < 0.2 {
            return .orange
        }
        return .secondary
    }

    private var thumbnail: some View {
        Group {
            switch job.state {
            case .done(let image, _):
                Image(uiImage: image).resizable().scaledToFill()
            case .processing, .pending:
                ZStack {
                    Image(uiImage: job.source).resizable().scaledToFill().opacity(0.4)
                    ProgressView()
                }
            case .failed:
                ZStack {
                    Image(uiImage: job.source).resizable().scaledToFill().opacity(0.35)
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        switch job.state {
        case .pending: return "Waiting"
        case .processing: return "Cropping…"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    private var subtitle: String? {
        switch job.state {
        case .pending, .processing:
            return nil
        case .done(_, let confidence):
            if confidence < 0.05 {
                return String(format: "%.1f%% confidence (very low)", confidence * 100)
            }
            return String(format: "%.0f%% confidence", confidence * 100)
        case .failed(let message):
            return message
        }
    }
}
