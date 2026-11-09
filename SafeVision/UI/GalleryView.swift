import AVFoundation
import AVKit
import SwiftUI

/// 相册页：网格展示应用内已保存的媒体，点开全屏查看，可分享 / 删除 / 导出到相册。
struct GalleryView: View {
    @State private var mediaURLs: [URL] = []
    @State private var selectedURL: URL?
    @State private var isPresentingDetail = false

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if mediaURLs.isEmpty {
                    ContentUnavailableView(
                        localizedKey("status_gallery_empty"),
                        systemImage: "photo.on.rectangle",
                        description: Text(localizedKey("status_gallery_empty_hint"))
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(mediaURLs, id: \.self) { url in
                                GalleryCell(url: url)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .onTapGesture {
                                        selectedURL = url
                                        isPresentingDetail = true
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .refreshable {
                        reload()
                    }
                }
            }
            .navigationTitle(localizedKey("tab_gallery"))
            .onAppear {
                reload()
            }
            .fullScreenCover(isPresented: $isPresentingDetail) {
                if let selectedURL {
                    MediaDetailView(url: selectedURL) {
                        reload()
                    }
                }
            }
        }
    }

    private func reload() {
        mediaURLs = MediaSaveHelper.listSavedMedia()
    }
}

// MARK: - 网格单元格

private struct GalleryCell: View {
    let url: URL

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isVideo(url) {
                Rectangle()
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                    )
                VideoDurationLabel(url: url)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            } else {
                FileThumbnailView(url: url)
            }
        }
    }
}

// MARK: - 全屏详情

private struct MediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var onDeleted: () -> Void

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var showingDeleteConfirm = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?

    private var isVideoFile: Bool { isVideo(url) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if isVideoFile {
                        if let player {
                            VideoPlayer(player: player)
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    } else if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedKey("action_close")) { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 24) {
                        ShareLink(item: url) {
                            Label(localizedKey("action_share"),
                                  systemImage: "square.and.arrow.up")
                        }
                        Button {
                            exportToPhotos()
                        } label: {
                            Label(localizedKey("action_export_to_photos"),
                                  systemImage: "square.and.arrow.down")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label(localizedKey("action_delete"), systemImage: "trash")
                        }
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .alert(localizedKey("gallery_delete_title"), isPresented: $showingDeleteConfirm) {
                Button(localizedKey("action_delete"), role: .destructive) {
                    deleteMedia()
                }
                Button(localizedKey("action_cancel"), role: .cancel) {}
            } message: {
                Text(localizedFormat("gallery_delete_message", url.lastPathComponent))
            }
            .alert(localizedKey("common_notice"), isPresented: Binding(
                get: { !statusMessage.isEmpty || errorMessage != nil },
                set: { if !$0 { statusMessage = ""; errorMessage = nil } }
            )) {
                Button(localizedKey("action_done"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? statusMessage)
            }
            .onAppear {
                if isVideoFile {
                    player = AVPlayer(url: url)
                } else {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let loaded = UIImage(contentsOfFile: url.path)
                        DispatchQueue.main.async { image = loaded }
                    }
                }
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    private func deleteMedia() {
        MediaSaveHelper.deleteSavedMedia(url)
        onDeleted()
        dismiss()
    }

    private func exportToPhotos() {
        requestPhotoLibraryAddAccess { granted in
            DispatchQueue.main.async {
                guard granted else {
                    errorMessage = localizedFormat(
                        "gallery_export_failed", localized("error_photo_access_denied"))
                    return
                }
                if isVideoFile {
                    MediaSaveHelper.saveVideoToPhotos(url) { success, error in
                        DispatchQueue.main.async {
                            if success {
                                statusMessage = localized("gallery_export_success")
                            } else {
                                errorMessage = localizedFormat(
                                    "gallery_export_failed",
                                    error?.localizedDescription ?? localized("error_unknown"))
                            }
                        }
                    }
                } else if let image {
                    MediaSaveHelper.saveImageToPhotos(image) { success, error in
                        DispatchQueue.main.async {
                            if success {
                                statusMessage = localized("gallery_export_success")
                            } else {
                                errorMessage = localizedFormat(
                                    "gallery_export_failed",
                                    error?.localizedDescription ?? localized("error_unknown"))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 共享小组件

/// 本地文件缩略图（后台加载原图；视频文件不走这里）。
struct FileThumbnailView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
            }
        }
        .onAppear {
            load()
        }
    }

    private func load() {
        guard image == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = UIImage(contentsOfFile: url.path)
            DispatchQueue.main.async { image = loaded }
        }
    }
}

/// 视频时长小标签。
private struct VideoDurationLabel: View {
    let url: URL
    @State private var duration: TimeInterval?

    var body: some View {
        Text(formattedDuration)
            .onAppear {
                Task {
                    let asset = AVURLAsset(url: url)
                    if let value = try? await asset.load(.duration) {
                        duration = CMTimeGetSeconds(value)
                    }
                }
            }
    }

    private var formattedDuration: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "--:--" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private func isVideo(_ url: URL) -> Bool {
    ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
}
