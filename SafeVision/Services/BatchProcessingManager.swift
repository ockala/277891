import Combine
import Foundation
import UIKit

public enum BatchStatus {
    case pending
    case processing
    case done
    case failed
}

public struct BatchItem: Identifiable {
    public let id = UUID()
    public let sourceURL: URL
    public var status: BatchStatus
    public var outputURL: URL?
    public var detectionCount: Int
    public var errorMessage: String?

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
        self.status = .pending
        self.outputURL = nil
        self.detectionCount = 0
        self.errorMessage = nil
    }
}

/// 批量处理中单张图的失败原因。
public enum BatchProcessingError: Error, LocalizedError {
    case unreadableImage
    case maskingFailed
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "无法读取图片"
        case .maskingFailed:
            return "打码失败"
        case .saveFailed:
            return "保存失败"
        }
    }
}

/// 一次批量运行的取消状态（每次 `processAll` 新建一个实例）。
private final class BatchProcessingRunState {
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

/// 批量图片处理：后台串行处理每张图。
///
/// 对应 Android `BatchProcessingManager`（单线程顺序分支）：读
/// UIImage → `DetectionEngine.detect(uiImage:)` → 按
/// `PrivacySettingsManager.shared.maskedBoxes` 转成打码框 →
/// `MaskRenderer.maskedImage` → `MediaSaveHelper.saveImageToAppFolder`
/// 保存到 App 内输出目录（`Documents/SafeVision/`）。
///
/// 无检测结果的图片也保存原图到输出目录并标记 `detectionCount = 0`；
/// 失败项记 `errorMessage` 后继续下一项，不中断整批。`detectionCount`
/// 记的是原始检测数（含被用户关闭而不打码的标签），与 Android
/// `hasDetections` 的口径一致。
///
/// 全程在一条后台串行队列上跑；`@Published` 状态一律发到主线程。
/// `DetectionEngine` 不是线程安全的，并发调用会出问题，因此这里刻意
/// 串行（Android 多图时用双线程，iOS 版先保正确、后谈提速）。
public final class BatchProcessingManager: ObservableObject {

    @Published public var items: [BatchItem] = []
    @Published public var isProcessing: Bool = false
    @Published public var progress: Double = 0 // 0...1，按完成数 / 总数

    private let workQueue = DispatchQueue(
        label: "com.safevision.BatchProcessingManager",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var currentRunState: BatchProcessingRunState?
    /// 每次 `processAll` / `removeAll` 换新令牌，过期运行的进度与
    /// 逐项更新会被丢弃，不会覆盖新运行的状态。
    private var currentRunToken = UUID()

    public init() {}

    // MARK: - 对外接口

    public func addImages(_ urls: [URL]) {
        onMain {
            let newItems = urls.map { BatchItem(sourceURL: $0) }
            self.items.append(contentsOf: newItems)
        }
    }

    public func processAll(profile: LabelProfile) {
        let snapshot: [BatchItem]? = onMain {
            guard !self.isProcessing else { return nil }
            var pending = self.items.filter {
                $0.status == .pending || $0.status == .failed
            }
            guard !pending.isEmpty else { return nil }
            // 失败项重试：先回到 pending，错误信息清空。
            for item in pending where item.status == .failed {
                if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[index].status = .pending
                    self.items[index].errorMessage = nil
                }
            }
            pending = self.items.filter { $0.status == .pending }
            self.isProcessing = true
            self.progress = 0
            return pending
        }
        guard let snapshot else { return }
        let runState = BatchProcessingRunState()
        let token = UUID()
        stateLock.lock()
        currentRunState = runState
        currentRunToken = token
        stateLock.unlock()
        workQueue.async {
            self.runBatch(snapshot, profile: profile, runState: runState, token: token)
        }
    }

    public func cancel() {
        stateLock.lock()
        let state = currentRunState
        stateLock.unlock()
        state?.cancel()
    }

    public func removeAll() {
        cancel()
        stateLock.lock()
        currentRunToken = UUID()
        stateLock.unlock()
        onMain {
            self.items.removeAll()
            self.progress = 0
        }
    }

    public func removeItem(_ item: BatchItem) {
        onMain {
            self.items.removeAll { $0.id == item.id }
        }
    }

    // MARK: - 一批运行

    private func runBatch(
        _ snapshot: [BatchItem],
        profile: LabelProfile,
        runState: BatchProcessingRunState,
        token: UUID
    ) {
        let engine = DetectionEngine()
        do {
            try engine.load(profile: profile)
        } catch {
            // 模型加载失败：整批无法检测，全部标为失败。
            for item in snapshot {
                updateItem(id: item.id, token: token) {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
            finishRun()
            return
        }

        let total = snapshot.count
        var completed = 0
        for item in snapshot {
            if runState.isCancelled { break }
            let shouldContinue = autoreleasepool { () -> Bool in
                self.processItem(item, engine: engine, runState: runState, token: token)
            }
            completed += 1
            publishProgress(Double(completed) / Double(total), token: token)
            if !shouldContinue { break }
        }
        finishRun()
    }

    private func finishRun() {
        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = false
        }
    }

    /// 处理一张图。返回 false 表示中途被取消，调用方应停止继续处理。
    private func processItem(
        _ item: BatchItem,
        engine: DetectionEngine,
        runState: BatchProcessingRunState,
        token: UUID
    ) -> Bool {
        updateItem(id: item.id, token: token) {
            $0.status = .processing
            $0.errorMessage = nil
        }
        do {
            let image = try loadImage(from: item.sourceURL)
            // detect(uiImage:) 内部先把方向归正为 .up，再检测，
            // 框坐标与打码坐标一致。
            let detections = try engine.detect(uiImage: image)
            if runState.isCancelled {
                updateItem(id: item.id, token: token) { $0.status = .pending }
                return false
            }
            let outputImage: UIImage
            if detections.isEmpty {
                // 无检测结果：保存原图，detectionCount = 0。
                outputImage = image
            } else {
                let boxes = PrivacySettingsManager.shared.maskedBoxes(for: detections)
                guard let masked = MaskRenderer.maskedImage(image, boxes: boxes) else {
                    // 打码失败不保存原图：避免敏感内容未经处理就落盘。
                    throw BatchProcessingError.maskingFailed
                }
                outputImage = masked
            }
            if runState.isCancelled {
                updateItem(id: item.id, token: token) { $0.status = .pending }
                return false
            }
            guard let outputURL = MediaSaveHelper.saveImageToAppFolder(
                outputImage,
                fileName: item.sourceURL.lastPathComponent
            ) else {
                throw BatchProcessingError.saveFailed
            }
            updateItem(id: item.id, token: token) {
                $0.status = .done
                $0.outputURL = outputURL
                $0.detectionCount = detections.count
            }
        } catch {
            updateItem(id: item.id, token: token) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
        }
        return true
    }

    // MARK: - 图片读取

    private func loadImage(from url: URL) throws -> UIImage {
        // 相册 / 文件选择器给的 URL 可能是安全域 URL。
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data) else {
            throw BatchProcessingError.unreadableImage
        }
        return image
    }

    // MARK: - 状态发布（主线程，过期运行的更新会被丢弃）

    private func updateItem(
        id: UUID,
        token: UUID,
        _ mutate: @escaping (inout BatchItem) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentToken(token),
                  let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            mutate(&self.items[index])
        }
    }

    private func publishProgress(_ value: Double, token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentToken(token) else { return }
            self.progress = value
        }
    }

    private func isCurrentToken(_ token: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return token == currentRunToken
    }

    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }
}
