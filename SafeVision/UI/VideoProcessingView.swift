import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 视频处理页：选视频 -> 显示时长/尺寸 -> 开始处理（进度+取消）-> 播放结果 -> 保存到相册。
struct VideoProcessingView: View {
    @EnvironmentObject private var appSettings: AppSettingsManager
    @StateObject private var processor = VideoProcessor()

    @State private var videoItem: PhotosPickerItem?
    @State private var sourceURL: URL?
    @State private var outputURL: URL?
    @State private var resultPlayer: AVPlayer?
    @State private var duration: TimeInterval?
    @State private var videoSize: CGSize?
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var cancelRequested = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PhotosPicker(selection: $videoItem, matching: .videos) {
                        Label(localizedKey("action_select_video"), systemImage: "film")
                    }
                    .buttonStyle(.borderedProminent)
                    .onChange(of: videoItem) { _, newValue in
                        Task { await loadVideoItem(newValue) }
                    }

                    if let sourceURL {
                        // MARK: - 视频信息
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localizedKey("label_video_info"))
                                .font(.headline)
                            LabeledContent(localizedKey("label_file_name"),
                                           value: sourceURL.lastPathComponent)
                            if let duration {
                                LabeledContent(localizedKey("label_duration"),
                                               value: formattedDuration(duration))
                            }
                            if let videoSize {
                                LabeledContent(localizedKey("label_size"),
                                               value: "\(Int(videoSize.width)) × \(Int(videoSize.height))")
                            }
                        }

                        Button {
                            startProcessing()
                        } label: {
                            Label(localizedKey("action_start_processing"),
                                  systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(processor.isProcessing)
                    } else {
                        ContentUnavailableView(
                            localizedKey("status_select_video_hint"),
                            systemImage: "film",
                            description: Text(localizedKey("status_video_ready"))
                        )
                        .frame(height: 280)
                    }

                    // MARK: - 处理进度
                    if processor.isProcessing {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: processor.progress)
                            Text(processor.statusMessage.isEmpty
                                 ? localized("status_processing_video")
                                 : processor.statusMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button {
                                cancelRequested = true
                                processor.cancel()
                            } label: {
                                Label(localizedKey("action_cancel"), systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // MARK: - 处理结果
                    if let outputURL, let resultPlayer {
                        Text(localizedKey("status_video_done"))
                            .font(.headline)
                        VideoPlayer(player: resultPlayer)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button {
                            saveResultToPhotos(url: outputURL)
                        } label: {
                            Label(localizedKey("action_save_to_photos"),
                                  systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                    }

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
                .padding()
            }
            .navigationTitle(localizedKey("tab_video"))
        }
    }

    // MARK: - 选视频

    private func loadVideoItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                await MainActor.run {
                    errorMessage = localizedFormat("status_video_failed",
                                                   localized("error_unknown"))
                }
                return
            }
            await MainActor.run {
                sourceURL = movie.url
                outputURL = nil
                resultPlayer = nil
                duration = nil
                videoSize = nil
                statusMessage = localized("status_video_ready")
                errorMessage = nil
            }
            await loadVideoInfo(url: movie.url)
        } catch {
            await MainActor.run {
                errorMessage = localizedFormat("status_video_failed",
                                               error.localizedDescription)
            }
        }
    }

    private func loadVideoInfo(url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            let durationValue = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let naturalSize = try await tracks.first?.load(.naturalSize)
            await MainActor.run {
                duration = CMTimeGetSeconds(durationValue)
                videoSize = naturalSize
            }
        } catch {
            // 时长/尺寸读不到不影响处理，只是不显示信息。
        }
    }

    // MARK: - 处理

    private func startProcessing() {
        guard let sourceURL else { return }
        errorMessage = nil
        statusMessage = localized("status_processing_video")
        cancelRequested = false
        outputURL = nil
        resultPlayer = nil
        processor.processVideo(sourceURL: sourceURL,
                               profile: appSettings.modelProfile) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    outputURL = url
                    resultPlayer = AVPlayer(url: url)
                    statusMessage = localized("status_video_done")
                case .failure(let error):
                    if cancelRequested {
                        statusMessage = localized("status_video_cancelled")
                    } else {
                        errorMessage = localizedFormat("status_video_failed",
                                                       error.localizedDescription)
                        statusMessage = ""
                    }
                }
            }
        }
    }

    // MARK: - 保存

    private func saveResultToPhotos(url: URL) {
        isSaving = true
        requestPhotoLibraryAddAccess { granted in
            DispatchQueue.main.async {
                guard granted else {
                    isSaving = false
                    errorMessage = localizedFormat(
                        "status_save_failed", localized("error_photo_access_denied"))
                    return
                }
                MediaSaveHelper.saveVideoToPhotos(url) { success, error in
                    DispatchQueue.main.async {
                        isSaving = false
                        if success {
                            statusMessage = localized("status_saved_to_photos")
                            errorMessage = nil
                        } else {
                            errorMessage = localizedFormat(
                                "status_save_failed",
                                error?.localizedDescription ?? localized("error_unknown"))
                        }
                    }
                }
            }
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "--:--" }
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// PhotosPicker 传输用的视频文件：把系统相册的视频复制一份到临时目录。
private struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileName = "picked-video-\(UUID().uuidString).mov"
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}
