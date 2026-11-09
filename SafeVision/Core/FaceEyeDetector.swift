import CoreGraphics
import Foundation
import Vision

/// Derives eye regions from faces with Apple Vision face landmarks.
///
/// Replaces Android's ONNX face-landmark models (`FaceLandmarkOnnxRunner`,
/// `EyeRegionHelper` + `BlurEffects.eyeBarFromEyes` / `cropToEyeStrip`):
/// no ONNX face model is used on iOS.
///
/// Geometry (Android-faithful, in original-image pixel coordinates):
/// - With landmarks: a bar along the line through both eye centers, length =
///   face width (or eye distance x 1.15 if that is larger), thickness = 40%
///   of face height, axis-aligned bounding box of the rotated bar, clamped
///   to the image.
/// - Without usable landmarks: the upper strip of the face box, from 10% to
///   50% of face height (Android `cropToEyeStrip`), full face width.
public final class FaceEyeDetector {

    /// One Vision face together with the eye region derived from it.
    public struct FaceEyeRegion {
        /// Face bounding box, original-image pixel coordinates.
        public let faceRect: CGRect
        /// Eye region, original-image pixel coordinates.
        public let eyeRect: CGRect
    }

    public init() {}

    /// Detects faces and returns the eye region of each face.
    public func eyeRegions(in cgImage: CGImage) throws -> [CGRect] {
        return try detectFaceEyeRegions(in: cgImage).map { $0.eyeRect }
    }

    /// Detects faces and returns each face box together with its eye region,
    /// so callers can match Vision faces against YOLO face detections.
    public func detectFaceEyeRegions(in cgImage: CGImage) throws -> [FaceEyeRegion] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observations = request.results as? [VNFaceObservation] else { return [] }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        var results: [FaceEyeRegion] = []
        for observation in observations {
            let faceRect = pixelRect(from: observation.boundingBox, imageSize: imageSize)
            guard faceRect.width > 0, faceRect.height > 0 else { continue }
            let leftEye = centroid(of: observation.landmarks?.leftEye, in: observation.boundingBox, imageSize: imageSize)
            let rightEye = centroid(of: observation.landmarks?.rightEye, in: observation.boundingBox, imageSize: imageSize)
            guard let eyeRect = eyeRegion(
                forFaceRect: faceRect, leftEye: leftEye, rightEye: rightEye, imageSize: imageSize
            ) else { continue }
            results.append(FaceEyeRegion(faceRect: faceRect, eyeRect: eyeRect))
        }
        return results
    }

    /// Derives the eye region for one face box.
    ///
    /// - Parameters:
    ///   - faceRect: face bounding box, original-image pixel coordinates.
    ///   - leftEye: left eye center in the same pixel coordinates, or nil.
    ///   - rightEye: right eye center in the same pixel coordinates, or nil.
    ///   - imageSize: original image size, for clamping.
    /// - Returns: the eye region, or nil if the face box is degenerate.
    public func eyeRegion(
        forFaceRect faceRect: CGRect,
        leftEye: CGPoint?,
        rightEye: CGPoint?,
        imageSize: CGSize
    ) -> CGRect? {
        let face = clamp(faceRect, to: imageSize)
        guard face.width > 0, face.height > 0 else { return nil }
        if let leftEye = leftEye, let rightEye = rightEye {
            if let bar = eyeBarFromEyes(faceRect: face, leftEye: leftEye, rightEye: rightEye, imageSize: imageSize) {
                return bar
            }
        }
        // Fallback: upper strip of the face box, matching Android
        // `BlurEffects.cropToEyeStrip`: center at 30% of face height,
        // height 40% of face height (i.e. 10%-50%), full face width.
        let strip = CGRect(
            x: face.minX,
            y: face.minY + face.height * 0.1,
            width: face.width,
            height: face.height * 0.4
        )
        let clamped = clamp(strip, to: imageSize)
        guard clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }

    // MARK: - Landmark geometry

    /// Android `BlurEffects.eyeBarFromEyes`: a bar centered on the eye
    /// midpoint, rotated along the eye axis, returned as its axis-aligned
    /// bounding box. Thickness is the base eye-strip height (40% of face
    /// height); length is the face width, extended to eye distance x 1.15
    /// when the eyes are wider than the face box.
    private func eyeBarFromEyes(
        faceRect: CGRect,
        leftEye: CGPoint,
        rightEye: CGPoint,
        imageSize: CGSize
    ) -> CGRect? {
        let lx = min(max(leftEye.x, faceRect.minX), faceRect.maxX)
        let rx = min(max(rightEye.x, faceRect.minX), faceRect.maxX)
        let ly = min(max(leftEye.y, faceRect.minY), faceRect.maxY)
        let ry = min(max(rightEye.y, faceRect.minY), faceRect.maxY)

        let eyeDx = rx - lx
        let eyeDy = ry - ly
        let eyeDistance = max(hypot(eyeDx, eyeDy), 1)
        let angle = atan2(eyeDy, eyeDx)

        let barThickness = max(faceRect.height * 0.4, 1)
        var barLength = max(faceRect.width, 1)
        if barLength < eyeDistance {
            barLength = eyeDistance * 1.15
        }

        // Unit vector along the eyes (u) and its normal (n), in pixel
        // coordinates (y grows downwards, same convention as Android).
        let ux = cos(angle)
        let uy = sin(angle)
        let nx = -uy
        let ny = ux
        let centerX = (lx + rx) / 2
        let centerY = (ly + ry) / 2
        let halfL = barLength / 2
        let halfT = barThickness / 2
        let corners = [
            CGPoint(x: centerX - ux * halfL + nx * halfT, y: centerY - uy * halfL + ny * halfT),
            CGPoint(x: centerX + ux * halfL + nx * halfT, y: centerY + uy * halfL + ny * halfT),
            CGPoint(x: centerX + ux * halfL - nx * halfT, y: centerY + uy * halfL - ny * halfT),
            CGPoint(x: centerX - ux * halfL - nx * halfT, y: centerY - uy * halfL - ny * halfT)
        ]
        let minX = corners.map { $0.x }.min() ?? 0
        let maxX = corners.map { $0.x }.max() ?? 0
        let minY = corners.map { $0.y }.min() ?? 0
        let maxY = corners.map { $0.y }.max() ?? 0
        let bounds = clamp(
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            to: imageSize
        )
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    // MARK: - Vision coordinate conversion

    /// Vision normalized rects have a bottom-left origin; converts to pixel
    /// coordinates with a top-left origin.
    private func pixelRect(from normalized: CGRect, imageSize: CGSize) -> CGRect {
        return CGRect(
            x: normalized.minX * imageSize.width,
            y: (1 - normalized.maxY) * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
    }

    /// Centroid of a landmark region, in original-image pixel coordinates.
    /// `VNFaceLandmarkRegion2D` points are normalized to the face bounding
    /// box with a bottom-left origin.
    private func centroid(
        of region: VNFaceLandmarkRegion2D?,
        in faceBox: CGRect,
        imageSize: CGSize
    ) -> CGPoint? {
        guard let region = region, !region.normalizedPoints.isEmpty else { return nil }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in region.normalizedPoints {
            sumX += point.x
            sumY += point.y
        }
        let count = CGFloat(region.normalizedPoints.count)
        let imageX = faceBox.minX + (sumX / count) * faceBox.width
        let imageY = faceBox.minY + (sumY / count) * faceBox.height
        return CGPoint(x: imageX * imageSize.width, y: (1 - imageY) * imageSize.height)
    }

    private func clamp(_ rect: CGRect, to imageSize: CGSize) -> CGRect {
        let x1 = min(max(rect.minX, 0), imageSize.width)
        let y1 = min(max(rect.minY, 0), imageSize.height)
        let x2 = min(max(rect.maxX, x1), imageSize.width)
        let y2 = min(max(rect.maxY, y1), imageSize.height)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
