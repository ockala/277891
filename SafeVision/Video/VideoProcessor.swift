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
    /// 音频无法保留（直传与重编码都失败，或源有音轨但 0 个采样被写入）。
    /// 不静默输出无声视频：音频保不住时直接报错，让用户知道。
    case audioFailed(String)
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
        case .audioFailed(let message):
            return "音频无法保留：\(message)"
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

/// 音频直传（AAC passthrough）运行时系统性失败的内部信号。
/// `run` 捕获后改走 PCM → AAC 重编码重试一次；不直接展示给用户。
private struct AudioPassthroughFailure: Error {
    let reason: String
}

/// 视频处理主流程（AVFoundation，单遍流式处理）。
///
/// 对应 Android `VideoProcessingManager` + `VideoDetectionProcessor` +
/// `VideoCodecUtils`：AVAssetReader 解码（BGRA）→ 每
/// `AppSettingsManager.shared.videoDetectStride` 帧检测一次（分段中间
/// 帧），其余帧用 `VideoFrameInterpolator` 在相邻两次检测之间插值 →
/// `MaskRenderer` 打码 → AVAssetWriterInputPixelBufferAdaptor 写出
/// H.264，音频 AAC 直传（非 AAC 则重编码为 AAC；保不住直接报错，
/// 不静默输出无音轨视频）。
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
        /// 探采样时最多跳过的空音频采样数（与 Android
        /// `MAX_EMPTY_AUDIO_SAMPLES_TO_SKIP = 16` 一致）。
        static let maxEmptyAudioSamplesToSkip = 16
        /// 直传 append 连续失败达到该次数时，改走重编码重试。
        static let maxConsecutiveAudioAppendFailures = 3
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
                runState: runState,
                startedWriting: &startedWriting,
                forceReencodeAudio: false
            )
            result = .success(url)
        } catch let failure as AudioPassthroughFailure
            where !runState.isCancelled {
            // 音频直传运行时系统性失败：改走 PCM → AAC 重编码重试一次。
            // 取消时不重试，直接按取消处理。
            NSLog("[VideoProcessor] 音频直传失败（\(failure.reason)），改用重编码重试")
            publishOnMain { self.statusMessage = "音频直传失败，改用重编码重试…" }
            startedWriting = false
            do {
                let url = try processInternal(
                    sourceURL: sourceURL,
                    engine: engine,
                    runState: runState,
                    startedWriting: &startedWriting,
                    forceReencodeAudio: true
                )
                result = .success(url)
            } catch {
                result = .failure(error)
            }
        } catch {
            // 不再静默重试无音轨输出：音频保不住时 `processInternal`
            // 会抛 `audioFailed`，让用户知道而不是悄悄出无声视频。
            result = .failure(error)
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
        runState: VideoProcessingRunState,
        startedWriting: inout Bool,
        forceReencodeAudio: Bool
    ) throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw VideoProcessingError.noVideoTrack
        }
        let naturalSize = videoTrack.naturalSize
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            throw VideoProcessingError.invalidSource
        }
        // 输出尺寸取编码帧尺寸（`formatDescriptions`），不是显示尺寸
        // `naturalSize`：iPhone 竖屏视频的编码帧是横屏（如 1920x1080），
        // 显示尺寸是竖屏（如 1080x1920），两者由 `preferredTransform`
        // 的 90° 旋转联系。旧实现用 `naturalSize` 当输出尺寸，把
        // 1920x1080 的解码帧硬画进 1080x1920 的缓冲，导致画面拉伸、
        // 马赛克变横条纹、打码位置错位；方向仍由 `preferredTransform`
        // 写到编码输入上（与原来一致）。
        // 取不到编码尺寸时回退为显示尺寸。
        let encodedSize: CGSize
        if let firstDescription = videoTrack.formatDescriptions.first {
            // 视频轨的 formatDescriptions 一定是 CMVideoFormatDescription
            //（编译器也如此判定，as? 会报“条件转换一定成功”），
            // 故先判空再无条件转换。
            let formatDescription = firstDescription as! CMVideoFormatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            if dimensions.width > 0, dimensions.height > 0 {
                encodedSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            } else {
                encodedSize = naturalSize
            }
        } else {
            encodedSize = naturalSize
        }
        // H.264 要求偶数尺寸；奇数尺寸向下对齐
        //（与 Android `VideoCodecUtils.alignDimensionToEncoder` 一致）。
        let outWidth = max(2, Int(encodedSize.width.rounded()) & ~1)
        let outHeight = max(2, Int(encodedSize.height.rounded()) & ~1)
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

        // MARK: 音频（与 Android `VideoCodecUtils.AudioTrackCopier` 一致：
        // AAC 直传，否则解码成 PCM 再重编码为 AAC）
        // 源有音轨时音频必须接上：直传与重编码都失败直接报错，
        // 不静默输出无声视频。源没有音轨时正常输出无声视频。
        // 只把 reader 输出接进 reader；writer 输入只做 canAdd 校验，
        // 不立即 writer.add——探采样确认音轨有有效采样后，
        // 在 writer.startWriting 之前再接进 writer。
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        var audioUsedPassthrough = false
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let pair = makeAudioPair(
                track: audioTrack,
                forceReencode: forceReencodeAudio,
                reader: reader,
                writer: writer
            )
            audioOutput = pair.output
            audioInput = pair.input
            audioUsedPassthrough = pair.passthrough
            if audioOutput == nil {
                throw VideoProcessingError.audioFailed("音频轨道无法接入（直传与重编码均失败）")
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

        // MARK: 探采样（对齐 Android `findFirstReadableSample`）
        // 接好音频输出后立刻读一个有效采样验证：音轨存在但读不到
        // 有效采样时当作“空音轨”，只出视频、不报错。
        // 跳过最多 16 个空采样；第一个非空采样存进 pendingAudioSample，
        // 后续 drainAudio 会先写它（不丢弃）。
        var pendingAudioSample: CMSampleBuffer?
        if let output = audioOutput, let input = audioInput {
            var firstSample: CMSampleBuffer?
            var emptySkipped = 0
            while emptySkipped <= Constants.maxEmptyAudioSamplesToSkip {
                guard let sample = output.copyNextSampleBuffer() else { break }
                if CMSampleBufferGetNumSamples(sample) == 0
                    || CMSampleBufferGetTotalSampleSize(sample) == 0 {
                    emptySkipped += 1
                    continue
                }
                firstSample = sample
                break
            }
            if let firstSample {
                pendingAudioSample = firstSample
                guard writer.canAdd(input) else {
                    throw VideoProcessingError.audioFailed("音频输入无法接入")
                }
                writer.add(input)
            } else {
                // 空音轨：不接音频输入，只出视频。
                audioOutput = nil
                audioInput = nil
            }
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
        /// 成功写入的音频采样数（源有音轨时应 > 0；为 0 说明音频丢了）。
        var appendedAudioSamples = 0
        /// 直传 append 连续失败次数；达到阈值时改走重编码重试。
        var audioAppendFailures = 0
        /// 直传已系统性失败（帧循环里据此抛 AudioPassthroughFailure）。
        var audioPassthroughFailed = false
        /// 音频失败原因（超时 / append 失败时记录的 writer/reader 状态），
        /// 报错时带进错误信息，方便诊断。
        var audioFailureReason: String?
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
                guard waitUntilReady(audioInput) else {
                    // 超时（非取消）：记下原因，供报错与重试诊断用。
                    if !runState.isCancelled, audioFailureReason == nil {
                        audioFailureReason = "等待音频输入就绪超时（writer.status=\(writer.status)，writer.error=\(writer.error?.localizedDescription ?? "无")，reader.error=\(reader.error?.localizedDescription ?? "无")）"
                    }
                    return
                }
                if audioInput.append(sample) {
                    appendedAudioSamples += 1
                    audioAppendFailures = 0
                } else {
                    audioAppendFailures += 1
                    if audioFailureReason == nil {
                        audioFailureReason = "音频采样 append 失败（writer.status=\(writer.status)，writer.error=\(writer.error?.localizedDescription ?? "无")，reader.error=\(reader.error?.localizedDescription ?? "无")）"
                    }
                    // 直传系统性失败：首个采样就失败，或连续失败达到阈值。
                    // 标记后帧循环抛 AudioPassthroughFailure，
                    // run 改走 PCM → AAC 重编码重试一次。
                    if audioUsedPassthrough
                        && (audioAppendFailures >= Constants.maxConsecutiveAudioAppendFailures
                            || (appendedAudioSamples == 0 && audioAppendFailures >= 1)) {
                        audioPassthroughFailed = true
                    }
                    return
                }
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
                // 走 `renderDetections`（不是低阶的 `maskedCGImage`），
                // 让视频帧也应用反向遮挡与全屏回退（与图片管线一致）。
                let appended = autoreleasepool { () -> Bool in
                    guard let sourceImage = cgImage(from: frame.pixelBuffer) else {
                        return true
                    }
                    guard let outputImage = MaskRenderer.renderDetections(
                        sourceImage,
                        detections: boxes
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
                // 直传已系统性失败：立即中断，run 改走重编码重试一次。
                if audioPassthroughFailed {
                    throw AudioPassthroughFailure(
                        reason: audioFailureReason ?? "音频直传连续失败"
                    )
                }
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
        // 直传在最后的 drain 里才系统性失败：同样改走重编码重试。
        if audioPassthroughFailed {
            throw AudioPassthroughFailure(
                reason: audioFailureReason ?? "音频直传连续失败"
            )
        }
        // 源有音轨且音频已接入，但一个采样都没写进去：说明音频丢了，
        // 不交付无声视频。直传 0 采样时改走重编码重试一次；
        // 重编码也 0 采样（或本来走的就是重编码）才直接报错，
        // 并把诊断原因带进错误信息。
        if audioOutput != nil, appendedAudioSamples == 0 {
            let detail = "音频采样未能写入（已写入 0 个采样）"
                + (audioFailureReason.map { "：\($0)" } ?? "")
            if audioUsedPassthrough, !forceReencodeAudio {
                throw AudioPassthroughFailure(
                    reason: audioFailureReason ?? detail
                )
            }
            throw VideoProcessingError.audioFailed(detail)
        }

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
    ///
    /// 注意翻转：`CGContext(data:...)` 是底朝上的坐标系（原点在左下角），
    /// 直接画 CGImage 会上下颠倒。先 `translate + scale(1, -1)` 翻转，
    /// 再画图，输出才与原视频方向一致。旧实现没翻转，视频整段倒着。
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
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    // MARK: - 音频格式工具

    /// 音频接入：AAC 直传，否则解码成 PCM 再重编码为 AAC
    ///（与 Android `VideoCodecUtils.AudioTrackCopier` 一致）。
    /// 只把 reader 输出接进 reader；writer 输入只做 canAdd 校验后返回，
    /// 由调用方在探采样确认音轨有有效采样后、writer.startWriting 之前
    /// 再 writer.add。`forceReencode` 为 true 时跳过直传，直接走重编码
    ///（直传运行时失败后的重试用）。
    /// 返回 (reader 输出, writer 输入, 是否直传)；三者全空表示两路都接不上。
    private func makeAudioPair(
        track: AVAssetTrack,
        forceReencode: Bool,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) -> (output: AVAssetReaderTrackOutput?, input: AVAssetWriterInput?, passthrough: Bool) {
        if !forceReencode, isAACAudio(track: track) {
            // AAC 直传（outputSettings 为 nil 即不重编码）。
            let passthroughOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            passthroughOutput.alwaysCopiesSampleData = false
            let passthroughInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            passthroughInput.expectsMediaDataInRealTime = false
            if reader.canAdd(passthroughOutput), writer.canAdd(passthroughInput) {
                reader.add(passthroughOutput)
                return (passthroughOutput, passthroughInput, true)
            }
        }
        if let format = audioFormat(for: track) {
            // 非 AAC 或直传接不上：解码成 PCM 再重编码为 AAC。
            let pcmOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            pcmOutput.alwaysCopiesSampleData = false
            let aacInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channels,
                AVEncoderBitRateKey: 160000
            ])
            aacInput.expectsMediaDataInRealTime = false
            if reader.canAdd(pcmOutput), writer.canAdd(aacInput) {
                reader.add(pcmOutput)
                return (pcmOutput, aacInput, false)
            }
        }
        return (nil, nil, false)
    }

    /// 音轨是否为 AAC（可直传进 MP4）。与 Android
    /// `VideoCodecUtils.canPassthroughToMp4` 一致（只认 AAC）。
    private func isAACAudio(track: AVAssetTrack) -> Bool {
        guard let firstDescription = track.formatDescriptions.first else {
            return false
        }
        // 音轨的 formatDescriptions 一定是 CMAudioFormatDescription，
        // as? 会报“条件转换一定成功”，故先判空再无条件转换。
        let formatDescription = firstDescription as! CMAudioFormatDescription
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        return mediaSubType == kAudioFormatMPEG4AAC
            || mediaSubType == kAudioFormatMPEG4AAC_HE
            || mediaSubType == kAudioFormatMPEG4AAC_LD
            || mediaSubType == kAudioFormatMPEG4AAC_ELD
    }

    /// 音轨的采样率与声道数（供重编码为 AAC 时用）。
    private func audioFormat(for track: AVAssetTrack) -> (sampleRate: Double, channels: Int)? {
        guard let firstDescription = track.formatDescriptions.first else {
            return nil
        }
        let formatDescription = firstDescription as! CMAudioFormatDescription
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let sampleRate = asbd.pointee.mSampleRate
        let channels = Int(asbd.pointee.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else { return nil }
        return (sampleRate, channels)
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
