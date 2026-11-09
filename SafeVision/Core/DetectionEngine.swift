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
    private func normalizedCGImage(from image: UIImage) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }
        guard image.imageOrientation != .up else { return cgImage }
        // Render at pixel size (not point size) so @2x/@3x images are not
        // downsampled; scale 1 makes renderer points equal pixels.
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        return normalized.cgImage
    }
}
