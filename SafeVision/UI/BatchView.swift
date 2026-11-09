import PhotosUI
import SwiftUI

/// 批量页：多选图片 -> 逐项显示缩略图/文件名/状态 -> 全部处理 -> 清空。
struct BatchView: View {
    @EnvironmentObject private var appSettings: AppSettingsManager
    @StateObject private var manager = BatchProcessingManager()

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var doneCount: Int {
        manager.items.filter { $0.status == .done }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    PhotosPicker(selection: $photoItems,
                                 maxSelectionCount: 100,
                                 matching: .images) {
                        Label(localizedKey("action_select_images"),
                              systemImage: "photo.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAdding)

                    Button {
                        manager.processAll(profile: appSettings.modelProfile)
                    } label: {
                        Label(localizedKey("action_process_all"),
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isProcessing || manager.items.isEmpty)

                    Button {
                        manager.removeAll()
                    } label: {
                        Label(localizedKey("action_clear"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isProcessing || manager.items.isEmpty)
                }
                .onChange(of: photoItems) { _, newValue in
                    Task { await addPhotoItems(newValue) }
                }

                if manager.isProcessing {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: manager.progress)
                        Text(localizedFormat("label_progress_percent",
                                             Int(manager.progress * 100)))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            manager.cancel()
                        } label: {
                            Label(localizedKey("action_cancel"), systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                    }
                } else if !manager.items.isEmpty {
                    Text(localizedFormat("status_batch_progress",
                                         doneCount, manager.items.count))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if manager.items.isEmpty {
                    ContentUnavailableView(
                        localizedKey("status_batch_empty"),
                        systemImage: "square.stack.3d.up",
                        description: Text(localizedKey("status_batch_empty_hint"))
                    )
                } else {
                    List {
                        ForEach(manager.items) { item in
                            BatchItemRow(item: item) {
                                manager.removeItem(item)
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }
            .padding()
            .navigationTitle(localizedKey("tab_batch"))
        }
    }

    // MARK: - 把选中的图片写入临时文件，交给 BatchProcessingManager

    private func addPhotoItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        await MainActor.run { isAdding = true }
        var urls: [URL] = []
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    continue
                }
                let fileName = "batch-\(UUID().uuidString).jpg"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(fileName)
                try data.write(to: url)
                urls.append(url)
            } catch {
                await MainActor.run {
                    errorMessage = localizedFormat("error_load_image_failed",
                                                   error.localizedDescription)
                }
            }
        }
        await MainActor.run {
            isAdding = false
            if !urls.isEmpty {
                manager.addImages(urls)
                errorMessage = nil
            }
            // 清空选择，避免同一批图片重复触发 onChange。
            photoItems = []
        }
    }
}

// MARK: - 批量列表行

private struct BatchItemRow: View {
    let item: BatchItem
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnailView(url: item.sourceURL)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.sourceURL.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(statusText)
                    .font(.footnote)
                    .foregroundColor(statusColor)
            }

            Spacer()

            if item.status == .done, let outputURL = item.outputURL {
                ShareLink(item: outputURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private var statusText: String {
        switch item.status {
        case .pending:
            return localized("batch_status_pending")
        case .processing:
            return localized("batch_status_processing")
        case .done:
            return localizedFormat("batch_status_done", item.detectionCount)
        case .failed:
            return localizedFormat("batch_status_failed",
                                   item.errorMessage ?? localized("error_unknown"))
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .pending: return .secondary
        case .processing: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}
