import AVFoundation
import Combine
import Foundation
import UIKit
import VideoToolbox

/// 视频处理失败原因。
public enum VideoProcessingError: Error, LocalizedError {
    case noVideoTrack
    case invalidSource
    case readerFailed(String)
    case writerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "未找到视频轨道"
        case .invalidSource:
            return "无法读取视频文件"
        case .readerFailed(let message):
            return "视频解码失败：\(message)"
        case .writerFailed(let message):
            return "视频编码失败：\(message)"
        case .cancelled:
            return "处理已取消"
        }
    }
}

/// 一次运行的取消状态（每次 `processVideo` 新建一个实例，旧运行的
/// 取消不会误伤新运行）。
private final class VideoProcessingRunState {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// 等待检测的一帧（CVPixelBuffer 被数组持有，内存随分段释放）。
private struct PendingFrame {
    let index: Int
    let pts: CMTime
    let pixelBuffer: CVPixelBuffer
}

/// 视频处理主流程（AVFoundation，单遍流式处理）。
///
/// 对应 Android `VideoProcessingManager` + `VideoDetectionProcessor` +
/// `VideoCodecUtils`：AVAssetReader 解码（BGRA）→ 每
/// `AppSettingsManager.shared.videoDetectStride` 帧检测一次（分段中间
/// 帧），其余帧用 `VideoFrameInterpolator` 在相邻两次检测之间插值 →
/// `MaskRenderer` 打码 → AVAssetWriterInputPixelBufferAdaptor 写出
/// H.264，音频直传（失败时回退为无音轨输出）。
///
/// 码率与 Android `DetectionConfig.VideoProcessing` 一致：目标码率 =
/// 原视频码率 × 0.18，夹在 3Mbps…30Mbps 之间；输出帧率上限 30fps
/// （源帧率更高时按 PTS 丢帧）。输出方向与原视频一致
/// （`preferredTransform` 写到编码输入上）。
///
/// 全程在一条后台串行队列上跑；`@Published` 状态一律发到主线程。
/// 每次 `processVideo` 会先取消正在跑的任务；处理全程持有后台任务，
/// 切到后台也不会被立即挂起。
public final class VideoProcessor: ObservableObject {

    @Published public var progress: Double = 0 // 0...1
    @Published public var isProcessing: Bool = false
    @Published public var statusMessage: String = ""

    /// 来自 Android `DetectionConfig.VideoProcessing` 的视频编码常量。
    private enum Constants {
        /// 目标码率 = 原码率 × 该系数。
        static let bitrateFactor = 0.18
        static let minTargetBitrate = 3_000_000
        static let maxTargetBitrate = 30_000_000
        /// 输出帧率上限。
        static let maxFrameRate: Float = 30
        static let maxFrameRateTimescale: Int32 = 30
    }

    private let workQueue = DispatchQueue(
        label: "com.safevision.VideoProcessor",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var currentRunState: VideoProcessingRunState?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    public init() {}

    // MARK: - 对外接口

    public func processVideo(
        sourceURL: URL,
        profile: LabelProfile,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        cancel()
        let runState = VideoProcessingRunState()
        stateLock.lock()
        currentRunState = runState
        stateLock.unlock()
        workQueue.async {
            self.run(
                sourceURL: sourceURL,
                profile: profile,
                runState: runState,
                completion: completion
            )
        }
    }

    public func cancel() {
        stateLock.lock()
        let state = currentRunState
        stateLock.unlock()
        state?.cancel()
    }

    // MARK: - 一次运行

    private func run(
        sourceURL: URL,
        profile: LabelProfile,
        runState: VideoProcessingRunState,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        beginBackgroundTask()
        defer { endBackgroundTask() }
        // 相册 / 文件选择器给的 URL 可能是安全域 URL，全程持有访问权。
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        publishOnMain {
            self.isProcessing = true
            self.progress = 0
            self.statusMessage = "正在解码…"
        }

        // 模型按本次 profile 加载；失败直接报错，不进入重试
        //（重试也解不出同一个模型）。
        let engine = DetectionEngine()
        do {
            try engine.load(profile: profile)
        } catch {
            finish(result: .failure(error), completion: completion)
            return
        }

        var startedWriting = false
        let result: Result<URL, Error>
        do {
            let url = try processInternal(
                sourceURL: sourceURL,
                engine: engine,
                includeAudio: true,
                runState: runState,
                startedWriting: &startedWriting
            )
            result = .success(url)
        } catch {
            if !startedWriting, !runState.isCancelled {
                // 写入开始前就失败，很可能与音轨有关：重试一次无音轨输出。
                startedWriting = false
                do {
                    let url = try processInternal(
                        sourceURL: sourceURL,
                        engine: engine,
                        includeAudio: false,
                        runState: runState,
                        startedWriting: &startedWriting
                    )
                    result = .success(url)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(error)
            }
        }
        finish(result: result, completion: completion)
    }

    private func finish(
        result: Result<URL, Error>,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        switch result {
        case .success:
            publishOnMain {
                self.progress = 1
                self.isProcessing = false
                self.statusMessage = "处理完成"
            }
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            publishOnMain {
                self.isProcessing = false
                self.statusMessage = message
            }
        }
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: - 处理管线（单次尝试）

    private func processInternal(
        sourceURL: URL,
        engine: DetectionEngine,
        includeAudio: Bool,
        runState: VideoProcessingRunState,
        startedWriting: inout Bool
    ) throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw VideoProcessingError.noVideoTrack
        }
        let naturalSize = videoTrack.naturalSize
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            throw VideoProcessingError.invalidSource
        }
        // H.264 要求偶数尺寸；奇数尺寸向下对齐
        //（与 Android `VideoCodecUtils.alignDimensionToEncoder` 一致）。
        let outWidth = max(2, Int(naturalSize.width.rounded()) & ~1)
        let outHeight = max(2, Int(naturalSize.height.rounded()) & ~1)
        let nominalFPS = videoTrack.nominalFrameRate
        let sourceFPS: Float = nominalFPS > 0 ? nominalFPS : 30
        let outputFPS = min(sourceFPS, Constants.maxFrameRate)
        let duration = asset.duration
        let totalFrames: Int
        if duration.seconds.isFinite, duration.seconds > 0, sourceFPS > 0 {
            totalFrames = max(1, Int((duration.seconds * Double(sourceFPS)).rounded()))
        } else {
            totalFrames = 0
        }

        // 目标码率 = 原视频码率 × 0.18，夹在 3Mbps…30Mbps 之间。
        // 取不到原码率时用宽 × 高 × 帧率 × 0.18 估算
        //（Android 的 TARGET_BITRATE_FACTOR 公式）。
        let sourceBitrate = Double(videoTrack.estimatedDataRate)
        let estimatedBitrate: Int
        if sourceBitrate > 0 {
            estimatedBitrate = Int((sourceBitrate * Constants.bitrateFactor).rounded())
        } else {
            estimatedBitrate = Int(
                (Double(outWidth * outHeight) * Double(sourceFPS)
                    * Constants.bitrateFactor).rounded()
            )
        }
        let bitrate = min(
            max(estimatedBitrate, Constants.minTargetBitrate),
            Constants.maxTargetBitrate
        )

        // MARK: Reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoProcessingError.readerFailed(error.localizedDescription)
        }
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw VideoProcessingError.readerFailed("无法添加视频输出")
        }
        reader.add(videoOutput)

        // MARK: Writer
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeVision-Video-\(UUID().uuidString).mp4")
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw VideoProcessingError.writerFailed(error.localizedDescription)
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: NSNumber(value: outputFPS)
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // 保持原视频方向：解码帧按编码方向处理，旋转信息写到输出上。
        videoInput.transform = videoTrack.preferredTransform
        guard writer.canAdd(videoInput) else {
            throw VideoProcessingError.writerFailed("无法添加视频输入")
        }
        writer.add(videoInput)

        // MARK: 音频直传（outputSettings 为 nil 即不重编码）
        // 任何一步失败都回退为无音轨输出，不影响画面处理。
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if includeAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
            let candidateOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            candidateOutput.alwaysCopiesSampleData = false
            let candidateInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            candidateInput.expectsMediaDataInRealTime = false
            if reader.canAdd(candidateOutput), writer.canAdd(candidateInput) {
                reader.add(candidateOutput)
                writer.add(candidateInput)
                audioOutput = candidateOutput
                audioInput = candidateInput
            }
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outWidth,
                kCVPixelBufferHeightKey as String: outHeight
            ]
        )

        let stride = max(1, AppSettingsManager.shared.videoDetectStride)

        var completed = false
        defer {
            if !completed {
                reader.cancelReading()
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        guard reader.startReading() else {
            throw VideoProcessingError.readerFailed(
                reader.error?.localizedDescription ?? "读取失败"
            )
        }
        guard writer.startWriting() else {
            throw VideoProcessingError.writerFailed(
                writer.error?.localizedDescription ?? "写入失败"
            )
        }
        startedWriting = true
        writer.startSession(atSourceTime: .zero)

        // MARK: 帧循环状态
        var pendingFrames: [PendingFrame] = []
        var previousDetection: (frame: Int, boxes: [Detection])?
        var frameIndex = 0
        var processedFrames = 0
        var lastAppendedPTS: CMTime?
        var pendingAudioSample: CMSampleBuffer?
        var didDetect = false
        let minFrameInterval = CMTime(
            value: 1,
            timescale: Constants.maxFrameRateTimescale
        )

        func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
            var waited: TimeInterval = 0
            while !input.isReadyForMoreMediaData {
                if runState.isCancelled { return false }
                if waited >= 5 { return false }
                Thread.sleep(forTimeInterval: 0.005)
                waited += 0.005
            }
            return true
        }

        /// 把音频样本写到不超过 maxPTS 为止；drainAll 时写完剩余全部样本。
        /// 超出 maxPTS 的第一个样本暂存到 pendingAudioSample，下次再写，
        /// 保证音画按 PTS 交错、不丢样。
        func drainAudio(upTo maxPTS: CMTime?, drainAll: Bool) {
            guard let audioOutput, let audioInput else { return }
            while !runState.isCancelled {
                let sample: CMSampleBuffer
                if let held = pendingAudioSample {
                    pendingAudioSample = nil
                    sample = held
                } else if let next = audioOutput.copyNextSampleBuffer() {
                    sample = next
                } else {
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if !drainAll, let maxPTS, CMTimeCompare(pts, maxPTS) > 0 {
                    pendingAudioSample = sample
                    return
                }
                guard waitUntilReady(audioInput) else { return }
                if !audioInput.append(sample) { return }
            }
        }

        func publishProgress() {
            let progressValue: Double
            if totalFrames > 0 {
                progressValue = min(1, Double(processedFrames) / Double(totalFrames))
            } else if duration.seconds.isFinite, duration.seconds > 0,
                      let last = lastAppendedPTS {
                progressValue = min(1, max(0, last.seconds / duration.seconds))
            } else {
                progressValue = 0
            }
            publishOnMain { self.progress = progressValue }
        }

        /// 处理一个检测分段：取分段中间帧做检测，其余帧在上一次与本次
        /// 检测之间插值（与 Android 的分段检测 / blendDetections 一致）。
        /// 检测本身失败会直接抛错——模型坏了不应静默输出未打码的视频。
        func processSegment(_ frames: [PendingFrame]) throws {
            guard !frames.isEmpty else { return }
            if runState.isCancelled { throw VideoProcessingError.cancelled }
            let detectionFrame = frames[frames.count / 2]
            var currentDetections: [Detection] = []
            if let detectionImage = cgImage(from: detectionFrame.pixelBuffer) {
                if !didDetect {
                    didDetect = true
                    publishOnMain { self.statusMessage = "正在检测…" }
                }
                currentDetections = try engine.detect(cgImage: detectionImage)
            } else if let previous = previousDetection {
                // 检测帧取不到像素：沿用上一次检测结果，不中断整段。
                currentDetections = previous.boxes
            }
            let current = (frame: detectionFrame.index, boxes: currentDetections)

            for frame in frames {
                if runState.isCancelled { throw VideoProcessingError.cancelled }
                processedFrames += 1
                // 帧率上限 30fps：源帧率更高时按 PTS 丢帧。
                if let last = lastAppendedPTS, frame.pts - last < minFrameInterval {
                    continue
                }
                let boxes: [Detection]
                if let previous = previousDetection {
                    boxes = VideoFrameInterpolator.interpolate(
                        prev: previous,
                        next: current,
                        at: frame.index
                    )
                } else {
                    boxes = current.boxes
                }
                // 返回 false 表示编码器未就绪或写入失败（外层抛错）；
                // 单帧取不到像素 / 打码失败时跳过该帧，不中断整段。
                let appended = autoreleasepool { () -> Bool in
                    guard let sourceImage = cgImage(from: frame.pixelBuffer) else {
                        return true
                    }
                    let masked = PrivacySettingsManager.shared.maskedBoxes(for: boxes)
                    guard let outputImage = MaskRenderer.maskedCGImage(
                        sourceImage,
                        boxes: masked
                    ) else {
                        return true
                    }
                    guard let outPixelBuffer = renderToPixelBuffer(
                        outputImage,
                        pool: adaptor.pixelBufferPool,
                        width: outWidth,
                        height: outHeight
                    ) else {
                        return true
                    }
                    guard waitUntilReady(videoInput) else { return false }
                    guard adaptor.append(outPixelBuffer, withPresentationTime: frame.pts) else {
                        return false
                    }
                    lastAppendedPTS = frame.pts
                    return true
                }
                if !appended {
                    if runState.isCancelled { throw VideoProcessingError.cancelled }
                    throw VideoProcessingError.writerFailed(
                        writer.error?.localizedDescription ?? "写入帧失败"
                    )
                }
                if processedFrames % 5 == 0 || processedFrames == totalFrames {
                    publishProgress()
                }
            }
            previousDetection = current
        }

        // MARK: 解码循环（按 stride 分段，攒够一段处理一段）
        while let sample = videoOutput.copyNextSampleBuffer() {
            if runState.isCancelled { throw VideoProcessingError.cancelled }
            try autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                pendingFrames.append(
                    PendingFrame(index: frameIndex, pts: pts, pixelBuffer: pixelBuffer)
                )
                frameIndex += 1
                drainAudio(upTo: pts, drainAll: false)
                if pendingFrames.count >= stride {
                    let segment = pendingFrames
                    pendingFrames = []
                    try processSegment(segment)
                }
            }
        }
        if reader.status == .failed {
            throw VideoProcessingError.readerFailed(
                reader.error?.localizedDescription ?? "读取失败"
            )
        }
        if runState.isCancelled { throw VideoProcessingError.cancelled }
        if !pendingFrames.isEmpty {
            let segment = pendingFrames
            pendingFrames = []
            try processSegment(segment)
        }
        drainAudio(upTo: nil, drainAll: true)
        if runState.isCancelled { throw VideoProcessingError.cancelled }

        // MARK: 收尾
        publishOnMain { self.statusMessage = "正在编码…" }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            if writer.status != .completed {
                finishError = writer.error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if writer.status != .completed {
            throw VideoProcessingError.writerFailed(
                (finishError ?? writer.error)?.localizedDescription ?? "写入未完成"
            )
        }
        completed = true
        return outputURL
    }

    // MARK: - 像素缓冲工具

    /// 从解码像素缓冲取 CGImage（零拷贝引用，调用方用完即弃）。
    private func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard status == noErr else { return nil }
        return image
    }

    /// 把打码后的 CGImage 画进编码器的像素缓冲池（BGRA，与 adaptor 一致；
    /// 尺寸与输出尺寸不符时按输出尺寸缩放，顺带处理奇数尺寸对齐）。
    private func renderToPixelBuffer(
        _ image: CGImage,
        pool: CVPixelBufferPool?,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    // MARK: - 后台任务与线程工具

    private func beginBackgroundTask() {
        let begin = {
            if self.backgroundTaskID == .invalid {
                self.backgroundTaskID = UIApplication.shared.beginBackgroundTask {
                    // 后台时间耗尽：标记取消，帧循环在下一帧退出并清理。
                    self.cancel()
                }
            }
        }
        if Thread.isMainThread {
            begin()
        } else {
            DispatchQueue.main.sync(execute: begin)
        }
    }

    private func endBackgroundTask() {
        let end = {
            if self.backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                self.backgroundTaskID = .invalid
            }
        }
        if Thread.isMainThread {
            end()
        } else {
            DispatchQueue.main.sync(execute: end)
        }
    }

    private func publishOnMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}
