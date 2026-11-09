import CoreGraphics
import Foundation

/// YOLO post-processing, ported from Android `YoloOnnxRunner`.
///
/// Input is the model's flat Float output with the batch dimension already
/// removed, plus its shape. Both output layouts are supported — the layout is
/// decided from the shape, never assumed. The two real model outputs are:
///
/// - End-to-end `[N, 6]` (standard model, `[300, 6]`): row-major, each row
///   is `[x1, y1, x2, y2, score, classId]`, score >= 0.2, same-class dedup
///   at IoU > 0.9. Flat index: `flat[i * 6 + j]`.
/// - Legacy `[attrs, N]` with `attrs == 4 + labelCount` (anime model,
///   `[14, 2100]`): column-major, each column is
///   `[cx, cy, w, h, classScores...]`, argmax class, score >= 0.2,
///   NMS at IoU 0.45 (cross-class, as in Android). Flat index:
///   `flat[j * N + i]` is attribute `j` of box `i`.
///
/// Any other shape returns an empty array (never a crash).
///
/// Box coordinates are normalized to the letterbox square
/// (`squareSize = max(originalWidth, originalHeight)`); they are restored by
/// `coord * squareSize` and clamped to the original image bounds.
/// Degenerate boxes (width or height <= 0 after clamping) are dropped.
public struct YOLOPostProcessor {

    public init() {}

    /// Post-process one model output.
    ///
    /// - Parameters:
    ///   - flatOutput: row-major flat Float array of the model output.
    ///   - shape: output shape with the batch dimension already removed,
    ///     e.g. `[300, 6]` or `[14, 2100]`.
    ///   - profile: label profile used to map class ids to labels.
    ///   - originalWidth: original image width in pixels.
    ///   - originalHeight: original image height in pixels.
    /// - Returns: detections in original-image pixel coordinates.
    public func process(
        flatOutput: [Float],
        shape: [Int],
        profile: LabelProfile,
        originalWidth: Int,
        originalHeight: Int
    ) -> [Detection] {
        guard shape.count == 2, shape[0] > 0, shape[1] > 0 else { return [] }
        let rows = shape[0]
        let cols = shape[1]
        guard flatOutput.count == rows * cols else { return [] }
        guard originalWidth > 0, originalHeight > 0 else { return [] }

        let labels = DetectionConfig.outputLabels(for: profile)
        let squareSize = Float(max(originalWidth, originalHeight))

        if cols == 6 {
            // End-to-end, row-major [N, 6]: row i is
            // [x1, y1, x2, y2, score, classId] at flat[i * 6 + j].
            return processEndToEnd(
                flatOutput: flatOutput, count: rows, labels: labels,
                originalWidth: originalWidth, originalHeight: originalHeight,
                squareSize: squareSize
            )
        } else if rows == 4 + labels.count {
            // Legacy, column-major [attrs, N]: attribute j of box i lives
            // at flat[j * N + i]; column i is [cx, cy, w, h, classScores...].
            return processLegacy(
                flatOutput: flatOutput, attrs: rows, count: cols, labels: labels,
                originalWidth: originalWidth, originalHeight: originalHeight,
                squareSize: squareSize
            )
        } else {
            // Unknown layout (e.g. a transposed [6, N]); nothing to return.
            return []
        }
    }

    // MARK: - End-to-end [N, 6]

    private func processEndToEnd(
        flatOutput: [Float],
        count: Int,
        labels: [String],
        originalWidth: Int,
        originalHeight: Int,
        squareSize: Float
    ) -> [Detection] {
        // Row-major: row i, element j lives at flatOutput[i * 6 + j].
        var detections: [Detection] = []
        for i in 0..<count {
            let base = i * 6
            let score = flatOutput[base + 4]
            guard score.isFinite, score >= DetectionConfig.scoreThreshold else { continue }
            let classIdFloat = flatOutput[base + 5]
            guard classIdFloat.isFinite, classIdFloat >= 0 else { continue }
            let classId = Int(classIdFloat)
            guard labels.indices.contains(classId) else { continue }
            let box = restoreBox(
                left: flatOutput[base + 0],
                top: flatOutput[base + 1],
                right: flatOutput[base + 2],
                bottom: flatOutput[base + 3],
                originalWidth: originalWidth,
                originalHeight: originalHeight,
                squareSize: squareSize
            )
            guard let box = box else { continue }
            detections.append(Detection(label: labels[classId], score: score, box: box))
        }
        return deduplicateHighOverlap(detections)
    }

    /// Same-class dedup at IoU > 0.9, highest score first (Android
    /// `deduplicateHighOverlapEndToEndDetections`).
    private func deduplicateHighOverlap(_ detections: [Detection]) -> [Detection] {
        guard detections.count >= 2 else { return detections }
        var selected: [Detection] = []
        for candidate in detections.sorted(by: { $0.score > $1.score }) {
            var keep = true
            for existing in selected {
                if candidate.label != existing.label { continue }
                if iou(candidate.box, existing.box) > DetectionConfig.endToEndDuplicateIoUThreshold {
                    keep = false
                    break
                }
            }
            if keep { selected.append(candidate) }
        }
        return selected
    }

    // MARK: - Legacy [attrs, N]

    private func processLegacy(
        flatOutput: [Float],
        attrs: Int,
        count: Int,
        labels: [String],
        originalWidth: Int,
        originalHeight: Int,
        squareSize: Float
    ) -> [Detection] {
        // Column-major: attribute a, column i lives at flatOutput[a * count + i].
        // Column i is [cx, cy, w, h, classScores...].
        struct Candidate {
            let score: Float
            let classId: Int
            let box: CGRect
        }
        var candidates: [Candidate] = []
        for i in 0..<count {
            // Argmax over class scores; Android only accepts scores >= 0.
            var maxScore = -Float.infinity
            var classId = -1
            for j in 4..<attrs {
                let score = flatOutput[j * count + i]
                if score.isFinite, score >= 0, score > maxScore {
                    maxScore = score
                    classId = j - 4
                }
            }
            guard classId >= 0, labels.indices.contains(classId) else { continue }
            guard maxScore >= DetectionConfig.scoreThreshold else { continue }
            let cx = flatOutput[0 * count + i]
            let cy = flatOutput[1 * count + i]
            let w = flatOutput[2 * count + i]
            let h = flatOutput[3 * count + i]
            let box = restoreBox(
                left: cx - w / 2, top: cy - h / 2,
                right: cx + w / 2, bottom: cy + h / 2,
                originalWidth: originalWidth,
                originalHeight: originalHeight,
                squareSize: squareSize
            )
            guard let box = box else { continue }
            candidates.append(Candidate(score: maxScore, classId: classId, box: box))
        }

        // NMS at IoU 0.45, highest score first. Android's legacy NMS
        // suppresses across classes (it does not check classId here).
        let sorted = candidates.sorted(by: { $0.score > $1.score })
        var selected: [Candidate] = []
        for candidate in sorted {
            var keep = true
            for existing in selected {
                if iou(candidate.box, existing.box) > DetectionConfig.nmsThreshold {
                    keep = false
                    break
                }
            }
            if keep { selected.append(candidate) }
        }
        return selected.map { Detection(label: labels[$0.classId], score: $0.score, box: $0.box) }
    }

    // MARK: - Geometry

    /// Restores a normalized box (relative to the letterbox square) to
    /// original-image pixel coordinates. Returns nil for non-finite input or
    /// a degenerate box (Android `YoloImageGeometry.restoreBox`).
    private func restoreBox(
        left: Float, top: Float, right: Float, bottom: Float,
        originalWidth: Int, originalHeight: Int, squareSize: Float
    ) -> CGRect? {
        guard left.isFinite, top.isFinite, right.isFinite, bottom.isFinite else { return nil }
        let x1 = min(max(left * squareSize, 0), Float(originalWidth))
        let y1 = min(max(top * squareSize, 0), Float(originalHeight))
        let x2 = min(max(right * squareSize, 0), Float(originalWidth))
        let y2 = min(max(bottom * squareSize, 0), Float(originalHeight))
        guard x2 > x1, y2 > y1 else { return nil }
        return CGRect(x: CGFloat(x1), y: CGFloat(y1), width: CGFloat(x2 - x1), height: CGFloat(y2 - y1))
    }

    /// Intersection-over-union of two pixel-coordinate rects.
    public func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let interLeft = max(a.minX, b.minX)
        let interTop = max(a.minY, b.minY)
        let interRight = min(a.maxX, b.maxX)
        let interBottom = min(a.maxY, b.maxY)
        let interWidth = max(0, interRight - interLeft)
        let interHeight = max(0, interBottom - interTop)
        let interArea = interWidth * interHeight
        guard interArea > 0 else { return 0 }
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return Float(interArea / unionArea)
    }
}
