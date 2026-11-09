import CoreGraphics
import Foundation
import UIKit

/// Orchestrates one detection: preprocess -> TensorFlow Lite inference ->
/// post-process -> derive EYE_REGION detections from face detections.
///
/// Synchronous by design: callers invoke `detect` on a background thread.
/// This class never switches threads and never touches the UI. It is not
/// thread-safe for concurrent `detect` calls; serialize calls from one
/// background queue (the underlying TFLite prediction is serialized
/// separately inside `TFLiteModelProvider`).
public final class DetectionEngine: ObservableObject {

    public enum EngineError: Error, LocalizedError {
        case modelMissing
        case loadFailed(Error)
        case predictionFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "模型未加载：请先调用 load(profile:)，并确认 .tflite 模型文件已加入 App Bundle"
            case .loadFailed(let error):
                return "模型加载失败：\(error.localizedDescription)"
            case .predictionFailed(let error):
                return "检测失败：\(error.localizedDescription)"
            }
        }
    }

    @Published public private(set) var isLoaded = false
    @Published public private(set) var loadedProfile: LabelProfile?

    private var provider: TFLiteModelProvider?
    private let postProcessor = YOLOPostProcessor()
    private let faceEyeDetector = FaceEyeDetector()

    public init() {}

    /// Loads (or reloads) the model for a profile. Loading the already-loaded
    /// profile is a no-op. Throws `loadFailed` on any load error, including
    /// a missing model file.
    public func load(profile: LabelProfile) throws {
        if loadedProfile == profile, provider != nil {
            return
        }
        let newProvider = TFLiteModelProvider(profile: profile)
        do {
            try newProvider.load()
        } catch {
            throw EngineError.loadFailed(error)
        }
        provider = newProvider
        loadedProfile = profile
        isLoaded = true
    }

    /// Detects on a CGImage. Call on a background thread.
    public func detect(cgImage: CGImage) throws -> [Detection] {
        guard let provider = provider, let profile = loadedProfile else {
            throw EngineError.modelMissing
        }
        let preprocessed: ImagePreprocessor.PreprocessedImage
        do {
            preprocessed = try ImagePreprocessor.preprocess(cgImage: cgImage)
        } catch {
            throw EngineError.predictionFailed(error)
        }
        let output: (values: [Float], shape: [Int])
        do {
            output = try provider.predict(pixels: preprocessed.pixels, shape: preprocessed.shape)
        } catch {
            throw EngineError.predictionFailed(error)
        }
        var detections = postProcessor.process(
            flatOutput: output.values,
            shape: output.shape,
            profile: profile,
            originalWidth: preprocessed.originalWidth,
            originalHeight: preprocessed.originalHeight
        )
        do {
            detections = try appendingEyeRegions(
                to: detections,
                cgImage: cgImage,
                imageSize: CGSize(width: preprocessed.originalWidth, height: preprocessed.originalHeight)
            )
        } catch {
            // Eye derivation is best-effort: a Vision failure must not drop
            // the YOLO detections already produced.
        }
        // 诊断日志：每次检测打印前 5 个检出（label + score + box）与当前
        // 模型 profile、后端；下次再报“准确率低”时直接看日志，不用盲猜。
        let backend = provider.isUsingMetalDelegate ? "Metal" : "CPU"
        let topDetections = detections
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { detection in
                let box = detection.box
                return "\(detection.label):\(String(format: "%.3f", detection.score))" +
                    " [\(Int(box.minX)),\(Int(box.minY)),\(Int(box.width))x\(Int(box.height))]"
            }
            .joined(separator: ", ")
        NSLog("[DetectionEngine] 检测完成：profile=\(profile)，backend=\(backend)，检出 \(detections.count) 个，前 5：\(topDetections.isEmpty ? "无" : topDetections)")
        return detections
    }

    /// Detects on a UIImage. The image is normalized to `.up` orientation
    /// first (a `UIImage.cgImage` alone drops orientation). Call on a
    /// background thread.
    public func detect(uiImage: UIImage) throws -> [Detection] {
        guard let cgImage = normalizedCGImage(from: uiImage) else {
            throw EngineError.predictionFailed(
                NSError(
                    domain: "SafeVision.DetectionEngine",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "无法从 UIImage 获取像素数据"]
                )
            )
        }
        return try detect(cgImage: cgImage)
    }

    // MARK: - Eye regions

    /// Appends one EYE_REGION detection per face detection, mirroring
    /// Android `withDerivedEyeRegionDetections`:
    ///
    /// - If an EYE_REGION detection already exists, nothing is added.
    /// - Each face detection is matched to the Vision face with the highest
    ///   IoU (threshold 0.05, same as Android's landmark matching); the
    ///   matched Vision eye region is used.
    /// - With no Vision match, the fallback strip of the YOLO face box is
    ///   used, so a face detection still yields an eye region.
    /// - The EYE_REGION score is the score of its face detection.
    private func appendingEyeRegions(
        to detections: [Detection],
        cgImage: CGImage,
        imageSize: CGSize
    ) throws -> [Detection] {
        guard !detections.isEmpty else { return detections }
        if detections.contains(where: { DetectionConfig.isEyeRegionLabel($0.label) }) {
            return detections
        }
        let faceDetections = detections.filter { DetectionConfig.canDeriveEyeRegion($0.label) }
        guard !faceDetections.isEmpty else { return detections }

        let visionFaces = try faceEyeDetector.detectFaceEyeRegions(in: cgImage)
        var usedVisionFaces = Set<Int>()
        var result = detections
        for face in faceDetections {
            var bestIndex: Int?
            var bestIoU: Float = 0
            for (index, visionFace) in visionFaces.enumerated() {
                if usedVisionFaces.contains(index) { continue }
                let overlap = postProcessor.iou(face.box, visionFace.faceRect)
                if overlap > bestIoU {
                    bestIoU = overlap
                    bestIndex = index
                }
            }
            let eyeRect: CGRect?
            if let bestIndex = bestIndex, bestIoU >= 0.05 {
                usedVisionFaces.insert(bestIndex)
                eyeRect = visionFaces[bestIndex].eyeRect
            } else {
                eyeRect = faceEyeDetector.eyeRegion(
                    forFaceRect: face.box, leftEye: nil, rightEye: nil, imageSize: imageSize
                )
            }
            guard let eyeRect = eyeRect, eyeRect.width > 0, eyeRect.height > 0 else { continue }
            result.append(Detection(
                label: DetectionConfig.eyeRegionLabel,
                score: face.score,
                box: eyeRect
            ))
        }
        return result
    }

    // MARK: - Orientation

    /// Returns a `.up`-oriented CGImage for a UIImage, redrawing only when
    /// the orientation is not already `.up`.
    ///
    /// 渲染尺寸必须用显示尺寸（`image.size` × scale，即旋转/镜像后的
    /// 尺寸），不能用 raw 的 `cgImage.width/height`：90 度旋转的照片
    /// raw 尺寸是横向、显示尺寸是竖向，用 raw 尺寸渲染会把图压扁，
    /// 检测框坐标随之错位（表现为打码打偏）。
    private func normalizedCGImage(from image: UIImage) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }
        guard image.imageOrientation != .up else { return cgImage }
        // 显示尺寸（点）× scale = 显示像素尺寸；对 90 度旋转的照片，
        // 宽高已互换，与屏幕上看到的一致。
        let displayPixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        guard displayPixelSize.width > 0, displayPixelSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: displayPixelSize, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: displayPixelSize))
        }
        return normalized.cgImage
    }
}
