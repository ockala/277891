import CoreImage
import UIKit

/// 真实打码渲染（Core Graphics + Core Image 实现）。
///
/// 坐标约定：所有框均为原图像素坐标，左上角原点、y 向下，与
/// `Detection.box` 一致。`maskedCGImage` 是视频管线用的高性能路径，
/// 全程只操作 `CGImage`，不经过 `UIImage`。
///
/// 每个框先按 `scale` 以框中心缩放、再 clamp 到图内；框重叠时按数组
/// 顺序依次绘制。马赛克 / 高斯 / 素描的采样源均为原图区域（与 Android
/// `BlurEffects.drawMosaic/drawGaussian/drawSobelEdge` 一致：它们都以
/// source bitmap 的裁剪区域为输入，而不是已打码的合成图）。
public enum MaskRenderer {

    /// 高斯模糊半径（像素），与 Android 默认值 12 一致。
    public static let gaussianRadius: CGFloat = 12

    private static let ciContext = CIContext()

    // MARK: - 入口

    /// 对 `UIImage` 打码。结果为方向已归正（`.up`）的新图。
    /// `boxes` 为空时直接返回原图。
    public static func maskedImage(_ image: UIImage, boxes: [MaskedBox]) -> UIImage? {
        guard !boxes.isEmpty else { return image }
        guard let normalized = normalizedUpImage(image),
              let cgImage = normalized.cgImage,
              let masked = maskedCGImage(cgImage, boxes: boxes) else { return nil }
        return UIImage(cgImage: masked, scale: image.scale, orientation: .up)
    }

    /// 对 `CGImage` 打码（视频管线路径）。`boxes` 为空时返回原图。
    public static func maskedCGImage(_ image: CGImage, boxes: [MaskedBox]) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard !boxes.isEmpty else { return image }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }

        // CG 位图上下文默认左下角原点；翻转为左上角原点后，绘图坐标与
        // Detection.box 的像素坐标完全一致，且 backing store 的第 0 行
        // 就是图像顶行，像素读写无需再换算。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        for maskedBox in boxes {
            let rect = scaledClampedRect(maskedBox, in: bounds)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            switch maskedBox.effect {
            case .mosaic:
                drawMosaic(in: context, source: image, rect: rect)
            case .black:
                context.setFillColor(UIColor.black.cgColor)
                context.fill(rect)
            case .blur:
                drawBlur(in: context, source: image, rect: rect)
            case .sketch:
                drawSketch(in: context, source: image, rect: rect)
            case .sticker:
                drawSticker(in: context, source: image, rect: rect)
            }
        }
        return context.makeImage()
    }

    // MARK: - 框变换

    /// 框按 scale 以中心缩放（scale 钳制在 0.01...10，与 Android
    /// `BlurEffects.scaleRect` 一致），再与图像边界求交集。
    private static func scaledClampedRect(_ maskedBox: MaskedBox, in bounds: CGRect) -> CGRect {
        let scale = max(0.01, min(10, maskedBox.scale))
        let center = CGPoint(x: maskedBox.box.midX, y: maskedBox.box.midY)
        let scaled = CGRect(
            x: center.x - maskedBox.box.width * scale / 2,
            y: center.y - maskedBox.box.height * scale / 2,
            width: maskedBox.box.width * scale,
            height: maskedBox.box.height * scale
        )
        return scaled.intersection(bounds)
    }

    /// 把浮点框转成像素整数框（向下取整左上、向上取整右下），并 clamp 到图内。
    private static func integralRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let x0 = max(0, Int(floor(rect.minX)))
        let y0 = max(0, Int(floor(rect.minY)))
        let x1 = min(width, Int(ceil(rect.maxX)))
        let y1 = min(height, Int(ceil(rect.maxY)))
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    // MARK: - 像素读写

    /// RGBA8（R,G,B,A 顺序）像素块，第 0 行是区域顶行。
    private struct PixelBuffer {
        let width: Int
        let height: Int
        let pixels: [UInt8] // count == width * height * 4
    }

    /// 只提取 `image` 在 `rect` 内的像素（`rect` 须为整数像素框）。
    /// 用于马赛克 / 素描：只处理框内区域，不动全图。
    private static func extractPixels(from image: CGImage, rect: CGRect) -> PixelBuffer? {
        let x = Int(rect.minX)
        let y = Int(rect.minY)
        let width = Int(rect.width)
        let height = Int(rect.height)
        guard width > 0, height > 0,
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ),
              let data = context.data else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = [UInt8](UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        ))
        return PixelBuffer(width: width, height: height, pixels: bytes)
    }

    private static func cgImage(from pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - 马赛克

    /// 块大小按框尺寸自适应：`max(8, min(40, min(框宽, 框高) / 12))`。
    /// 每块取左上角像素颜色填充整块（与 Android
    /// `BlurEffects.createMosaicBitmap` 的取样方式一致），不透明。
    private static func drawMosaic(in context: CGContext, source: CGImage, rect: CGRect) {
        let pixelRect = integralRect(rect, width: source.width, height: source.height)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let buffer = extractPixels(from: source, rect: pixelRect) else { return }
        let blockSize = max(8, min(40, Int(min(pixelRect.width, pixelRect.height) / 12)))
        for blockY in stride(from: 0, to: buffer.height, by: blockSize) {
            for blockX in stride(from: 0, to: buffer.width, by: blockSize) {
                let offset = (blockY * buffer.width + blockX) * 4
                let red = CGFloat(buffer.pixels[offset]) / 255
                let green = CGFloat(buffer.pixels[offset + 1]) / 255
                let blue = CGFloat(buffer.pixels[offset + 2]) / 255
                context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
                let blockWidth = min(blockSize, buffer.width - blockX)
                let blockHeight = min(blockSize, buffer.height - blockY)
                context.fill(CGRect(
                    x: pixelRect.minX + CGFloat(blockX),
                    y: pixelRect.minY + CGFloat(blockY),
                    width: CGFloat(blockWidth),
                    height: CGFloat(blockHeight)
                ))
            }
        }
    }

    // MARK: - 高斯模糊

    /// 只模糊框内区域：裁剪出框区域 → `CIGaussianBlur`（半径 12）→
    /// 合成回原位置。不做全图模糊。`clampedToExtent()` 防止裁剪边缘
    /// 采样到透明黑边。
    private static func drawBlur(in context: CGContext, source: CGImage, rect: CGRect) {
        let pixelRect = integralRect(rect, width: source.width, height: source.height)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = source.cropping(to: pixelRect) else { return }
        let input = CIImage(cgImage: cropped).clampedToExtent()
        guard let filter = CIFilter(
            name: "CIGaussianBlur",
            parameters: [
                kCIInputImageKey: input,
                kCIInputRadiusKey: gaussianRadius
            ]
        ),
        let output = filter.outputImage else { return }
        let extent = CGRect(x: 0, y: 0, width: pixelRect.width, height: pixelRect.height)
        guard let blurred = ciContext.createCGImage(output, from: extent) else { return }
        context.draw(blurred, in: pixelRect)
    }

    // MARK: - 素描（Sobel）

    /// 照搬 Android `BlurEffects.createSobelBitmap` 的 Sobel 算法：
    /// 灰度 `0.299R + 0.587G + 0.114B`，3x3 Sobel 算子求梯度幅值，
    /// 按区域内最大幅值归一化到 0-255 输出灰度图。只处理框内区域。
    /// 区域完全平坦（最大幅值为 0）时保持原图不变（与 Android 返回
    /// null 的行为一致）。
    private static func drawSketch(in context: CGContext, source: CGImage, rect: CGRect) {
        let pixelRect = integralRect(rect, width: source.width, height: source.height)
        guard pixelRect.width > 1, pixelRect.height > 1,
              let buffer = extractPixels(from: source, rect: pixelRect) else { return }
        let width = buffer.width
        let height = buffer.height

        var gray = [Int](repeating: 0, count: width * height)
        for index in 0 ..< width * height {
            let offset = index * 4
            gray[index] = Int((0.299 * Double(buffer.pixels[offset])
                + 0.587 * Double(buffer.pixels[offset + 1])
                + 0.114 * Double(buffer.pixels[offset + 2])).rounded())
        }

        var magnitudes = [Float](repeating: 0, count: width * height)
        var maxMagnitude: Float = 0
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 {
                let topLeft = gray[(y - 1) * width + (x - 1)]
                let top = gray[(y - 1) * width + x]
                let topRight = gray[(y - 1) * width + (x + 1)]
                let left = gray[y * width + (x - 1)]
                let right = gray[y * width + (x + 1)]
                let bottomLeft = gray[(y + 1) * width + (x - 1)]
                let bottom = gray[(y + 1) * width + x]
                let bottomRight = gray[(y + 1) * width + (x + 1)]

                let gx = Float((topRight + 2 * right + bottomRight)
                    - (topLeft + 2 * left + bottomLeft))
                let gy = Float((bottomLeft + 2 * bottom + bottomRight)
                    - (topLeft + 2 * top + topRight))
                let magnitude = hypot(gx, gy)
                magnitudes[y * width + x] = magnitude
                if magnitude > maxMagnitude { maxMagnitude = magnitude }
            }
        }
        guard maxMagnitude > 0 else { return }

        let factor = 255.0 / maxMagnitude
        var output = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0 ..< width * height {
            let edge = min(255, max(0, Int((magnitudes[index] * factor).rounded())))
            let offset = index * 4
            output[offset] = UInt8(edge)
            output[offset + 1] = UInt8(edge)
            output[offset + 2] = UInt8(edge)
            output[offset + 3] = 255
        }
        guard let sketchImage = cgImage(from: output, width: width, height: height) else { return }
        context.draw(sketchImage, in: pixelRect)
    }

    // MARK: - 贴纸

    /// 照搬 Android `BlurEffects.drawSticker`（非 fitInsideRect 分支）：
    /// 目标边长 = 框的长边，缩放倍数 = 目标边长 / 贴纸短边，贴纸等比
    /// 缩放后居中绘制到框上。贴纸图缺失时回退为马赛克，避免敏感
    /// 内容裸露（贴纸文件由主包提供，见 `StickerLoader`）。
    private static func drawSticker(in context: CGContext, source: CGImage, rect: CGRect) {
        guard let sticker = StickerLoader.defaultSticker(),
              let stickerImage = sticker.cgImage else {
            drawMosaic(in: context, source: source, rect: rect)
            return
        }
        let targetSide = max(rect.width, rect.height)
        let stickerShortSide = min(CGFloat(stickerImage.width), CGFloat(stickerImage.height))
        guard stickerShortSide > 0 else {
            drawMosaic(in: context, source: source, rect: rect)
            return
        }
        let scale = targetSide / stickerShortSide
        let destWidth = CGFloat(stickerImage.width) * scale
        let destHeight = CGFloat(stickerImage.height) * scale
        let destRect = CGRect(
            x: rect.midX - destWidth / 2,
            y: rect.midY - destHeight / 2,
            width: destWidth,
            height: destHeight
        )
        context.draw(stickerImage, in: destRect)
    }

    // MARK: - 方向归正

    /// 把任意方向的 `UIImage` 画成方向为 `.up` 的新图（像素内容与
    /// 屏幕上看到的一致），使后续的像素坐标框能直接对应。
    private static func normalizedUpImage(_ image: UIImage) -> UIImage? {
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
