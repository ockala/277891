import CoreGraphics
import Foundation

/// Preprocessing, ported from Android `YoloOnnxRunner.preprocess` +
/// `YoloTensorInput`.
///
/// Letterbox: `scale = 320 / max(w, h)`, the image is placed at the TOP-LEFT
/// of a 320x320 square with black padding on the right/bottom. Output is a
/// FLOAT32 NHWC RGB tensor in [0, 1], row-major `[y][x][channel]`
/// (`320 * 320 * 3` floats).
public enum ImagePreprocessor {

    public static let inputSize = 320

    public struct PreprocessedImage {
        /// RGB floats in [0, 1], NHWC order, `inputSize * inputSize * 3` values.
        public let pixels: [Float]
        /// Original image size in pixels.
        public let originalWidth: Int
        public let originalHeight: Int
        /// Letterbox square edge: `max(originalWidth, originalHeight)`.
        /// Post-processing restores boxes with `coord * squareSize`.
        public let squareSize: Int
        /// Shape to feed the model, before the provider adapts it to the
        /// model's own declared input shape.
        public let shape: [Int] = [1, inputSize, inputSize, 3]
    }

    public enum PreprocessError: Error, LocalizedError {
        case emptyImage
        case contextCreationFailed
        case pixelReadFailed

        public var errorDescription: String? {
            switch self {
            case .emptyImage: return "预处理失败：图片宽高为 0"
            case .contextCreationFailed: return "预处理失败：无法创建 320x320 位图上下文"
            case .pixelReadFailed: return "预处理失败：无法读取位图像素"
            }
        }
    }

    /// Letterboxes a CGImage to 320x320 and returns normalized NHWC RGB floats.
    ///
    /// The bitmap context is created with a top-left origin (via a vertical
    /// flip before drawing) so output row 0 is the top row of the source
    /// image, matching Android `Bitmap` / `Canvas` semantics.
    public static func preprocess(cgImage: CGImage) throws -> PreprocessedImage {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw PreprocessError.emptyImage }

        let squareSize = max(width, height)
        let scale = CGFloat(inputSize) / CGFloat(squareSize)
        let scaledWidth = CGFloat(width) * scale
        let scaledHeight = CGFloat(height) * scale

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PreprocessError.contextCreationFailed
        }
        let bytesPerRow = inputSize * 4
        guard let context = CGContext(
            data: nil,
            width: inputSize,
            height: inputSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw PreprocessError.contextCreationFailed
        }

        // Black padding (right/bottom): the fresh context starts zeroed,
        // which is opaque black under premultipliedLast; fill explicitly so
        // the padding does not depend on that.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: inputSize, height: inputSize))

        // CGBitmapContext has a bottom-left origin; flip so the drawn image
        // is upright and output row 0 corresponds to the image top.
        context.translateBy(x: 0, y: CGFloat(inputSize))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .default
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))

        guard let data = context.data else { throw PreprocessError.pixelReadFailed }
        let bytes = data.bindMemory(to: UInt8.self, capacity: inputSize * inputSize * 4)

        // Byte order is RGBA (32Big + premultipliedLast). RGB channels are
        // adjacent per pixel, i.e. NHWC; divide by 255 like Android.
        var pixels: [Float] = []
        pixels.reserveCapacity(inputSize * inputSize * 3)
        for i in 0..<(inputSize * inputSize) {
            let base = i * 4
            pixels.append(Float(bytes[base]) / 255)
            pixels.append(Float(bytes[base + 1]) / 255)
            pixels.append(Float(bytes[base + 2]) / 255)
        }

        return PreprocessedImage(
            pixels: pixels,
            originalWidth: width,
            originalHeight: height,
            squareSize: squareSize
        )
    }
}
