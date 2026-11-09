import CoreImage
import UIKit

/// 真实打码渲染（Core Graphics + Core Image 实现）。
///
/// 坐标约定：所有框均为原图像素坐标，左上角原点、y 向下，与
/// `Detection.box` 一致。
///
/// 方向：合成统一用 `UIGraphicsImageRenderer`（UIKit 保证输出方向
/// 为 `.up`）。旧实现用裸 `CGContext` + 手动翻转 + `makeImage()`，
/// 实测输出整图上下颠倒（图片与视频两条管线都翻），因此改走
/// UIKit 渲染路径；`extractPixels`（只读像素取样）仍用裸上下文。
///
/// 效果与 Android `DetectionRenderEngine` / `BlurEffects` 对齐：
/// 马赛克块大小取当前设置的 `mosaicBlockSize`（预设值，如 ZISUE
/// 的 19），高斯半径取 `gaussianRadius`；描边为红色粗边（贴纸模式
/// 不画）；反向遮挡与全屏回退见 `renderDetections`。
public enum MaskRenderer {

    private static let ciContext = CIContext()

    // MARK: - 入口（低阶：直接给框）

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

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        let result = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            for maskedBox in boxes {
                let rect = scaledClampedRect(maskedBox, in: bounds)
                guard rect.width >= 1, rect.height >= 1 else { continue }
                drawMaskedBox(maskedBox, rect: rect, source: image, in: context)
            }
            drawOutlines(boxes: boxes, bounds: bounds, in: context)
        }
        return result.cgImage
    }

    // MARK: - 完整渲染（正常 / 反向 / 全屏回退）

    /// 按当前隐私设置对检测结果做完整渲染，对齐 Android
    /// `DetectionRenderEngine.applyDetections`：
    ///
    /// - 反向标签（`reverseLabels`）命中时：整图先按反向模式打码，
    ///   再把反向区域恢复为原图（只保留反向标签清晰），最后画正常框；
    ///   `reversePreRenderEnabled` 为 false 时顺序反过来（先画正常框，
    ///   再做反向遮挡）。
    /// - 配置了反向标签、且 `reverseLabelMissFullscreenEnabled` 开着、
    ///   但一张图里一个反向标签都没检测到时：整图打码（全屏回退）。
    /// - `accessibilityEmptyReverseFullscreenEnabled` 开着、且一张图
    ///   里没有任何检测结果时：整图打码。
    /// - 无检测且无需全屏回退时返回原图。
    ///
    /// `detections` 为原图像素坐标（左上角原点）。图片与视频两条
    /// 管线都应走这个入口（不要只调低阶的 `maskedImage(_:boxes:)`，
    /// 否则反向/全屏逻辑会被跳过）。
    public static func renderDetections(_ image: UIImage, detections: [Detection]) -> UIImage? {
        guard let normalized = normalizedUpImage(image),
              let cgImage = normalized.cgImage,
              let rendered = renderDetections(cgImage, detections: detections) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: .up)
    }

    public static func renderDetections(_ cgImage: CGImage, detections: [Detection]) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let settings = PrivacySettingsManager.shared
        let reverseLabels = settings.reverseLabels
        let hasReverseLabels = !reverseLabels.isEmpty
        let rawDetectionsPresent = !detections.isEmpty

        // 全屏回退：识别到内容但未命中任何反向标签。
        let missFallback = settings.reverseLabelMissFullscreenEnabled
            && hasReverseLabels && rawDetectionsPresent
            && !detections.contains(where: { reverseLabels.contains($0.label) })
        // 全屏回退：无任何内容（且配置了反向标签）。
        let emptyFallback = settings.accessibilityEmptyReverseFullscreenEnabled
            && hasReverseLabels && !rawDetectionsPresent
        if missFallback || emptyFallback {
            let fallbackLabel = reverseLabels.first
            let mode = settings.effect(for: fallbackLabel ?? "")
            let sticker = fallbackLabel.flatMap { settings.sticker(for: $0) }
                ?? settings.defaultStickerImage()
            return fullscreenMaskedCGImage(cgImage, effect: mode, sticker: sticker)
        }
        if detections.isEmpty {
            return cgImage
        }

        let reverseDetections = detections.filter { reverseLabels.contains($0.label) }
        let normalDetections = detections.filter { !reverseLabels.contains($0.label) }
        let normalBoxes = settings.maskedBoxes(for: normalDetections)

        guard !reverseDetections.isEmpty else {
            return maskedCGImage(cgImage, boxes: normalBoxes)
        }

        // 反向模式：多个反向框效果一致时用该效果，不一致时用默认效果
        //（与 Android `reverseModeMixed` 一致）。
        let reverseEffects = reverseDetections.map { settings.effect(for: $0.label) }
        let reverseMode: MaskEffect
        if let first = reverseEffects.first,
           reverseEffects.allSatisfy({ $0 == first }) {
            reverseMode = first
        } else {
            reverseMode = settings.defaultEffect
        }
        let reverseBoxes = settings.maskedBoxes(for: reverseDetections)
        // 反向贴纸：单个反向框时用该标签的贴纸，多个时用默认贴纸
        //（与 Android `applyReverseMask` 一致）。
        let reverseSticker: UIImage?
        if reverseBoxes.count == 1, let only = reverseBoxes.first {
            reverseSticker = only.sticker ?? settings.defaultStickerImage()
        } else {
            reverseSticker = settings.defaultStickerImage()
        }

        if settings.reversePreRenderEnabled {
            // 先反向遮挡，再画正常框。
            guard let reversed = reverseMaskedCGImage(
                cgImage, reverseBoxes: reverseBoxes, mode: reverseMode, sticker: reverseSticker
            ) else { return nil }
            return maskedCGImage(reversed, boxes: normalBoxes)
        } else {
            // 先画正常框，再做反向遮挡（反向区域从已画好正常框的图上恢复，
            // 与 Android 非预渲染路径一致）。
            let normalRendered = maskedCGImage(cgImage, boxes: normalBoxes) ?? cgImage
            return reverseMaskedCGImage(
                normalRendered, reverseBoxes: reverseBoxes, mode: reverseMode,
                sticker: reverseSticker, restoreSource: cgImage
            )
        }
    }

    /// 整图打码（全屏回退）。效果取反向标签的效果（无则默认效果）。
    public static func fullscreenMaskedCGImage(
        _ image: CGImage, effect: MaskEffect, sticker: UIImage?
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let box = MaskedBox(box: bounds, effect: effect, scale: 1.0, sticker: sticker)
        return maskedCGImage(image, boxes: [box])
    }

    /// 反向遮挡：整图按 `mode` 打码，再把 `reverseBoxes` 的区域恢复为
    /// 原图（只保留反向标签清晰）。`restoreSource` 为恢复时取像素的
    /// 原图（预渲染路径与当前图相同；非预渲染路径取打码前的原图）。
    public static func reverseMaskedCGImage(
        _ image: CGImage,
        reverseBoxes: [MaskedBox],
        mode: MaskEffect,
        sticker: UIImage?,
        restoreSource: CGImage? = nil
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let restore = restoreSource ?? image
        // 反向框先按 scale 缩放并 clamp，取有效框。
        let rects: [(box: MaskedBox, rect: CGRect)] = reverseBoxes.compactMap { maskedBox in
            let rect = scaledClampedRect(maskedBox, in: bounds)
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return (maskedBox, rect)
        }
        guard !rects.isEmpty else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        let result = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.interpolationQuality = .high
            // 1. 整图按反向模式打码（贴纸模式先铺原图再盖贴纸，
            //    与 Android `applyReverseMask` 一致；贴纸缺失回退马赛克）。
            if mode == .sticker {
                if let stickerImage = sticker ?? StickerLoader.defaultSticker() {
                    // 先铺原图再盖贴纸，半透明贴纸才能正确叠加
                    //（与 Android `applyReverseMask` 一致）。
                    context.draw(image, in: bounds)
                    drawSticker(in: context, source: image, rect: bounds, stickerOverride: stickerImage)
                } else {
                    let fullBox = MaskedBox(box: bounds, effect: .mosaic)
                    drawMaskedBox(fullBox, rect: bounds, source: image, in: context)
                }
            } else {
                let fullBox = MaskedBox(box: bounds, effect: mode)
                drawMaskedBox(fullBox, rect: bounds, source: image, in: context)
            }
            // 2. 把反向区域恢复为原图（圆形框按圆形恢复）。
            for (maskedBox, rect) in rects {
                if maskedBox.circular {
                    let circle = circumscribedCircleBounds(for: rect)
                    context.saveGState()
                    context.addEllipse(in: circle)
                    context.clip()
                    context.draw(restore, in: bounds)
                    context.restoreGState()
                } else {
                    context.draw(restore, in: rect)
                }
            }
            // 3. 反向区域的描边。
            drawOutlines(boxes: reverseBoxes, bounds: bounds, in: context)
        }
        return result.cgImage
    }

    // MARK: - 单框绘制

    /// 对一个框应用效果。圆形框时效果限制在外接圆内
    ///（Android `drawWithCircularClip`）。
    private static func drawMaskedBox(
        _ maskedBox: MaskedBox, rect: CGRect, source: CGImage, in context: CGContext
    ) {
        if maskedBox.circular {
            let circle = circumscribedCircleBounds(for: rect)
            context.saveGState()
            context.addEllipse(in: circle)
            context.clip()
            applyEffect(maskedBox, rect: circle, source: source, in: context)
            context.restoreGState()
        } else {
            applyEffect(maskedBox, rect: rect, source: source, in: context)
        }
    }

    private static func applyEffect(
        _ maskedBox: MaskedBox, rect: CGRect, source: CGImage, in context: CGContext
    ) {
        switch maskedBox.effect {
        case .mosaic:
            drawMosaic(in: context, source: source, rect: rect)
        case .black:
            context.setFillColor(UIColor.black.cgColor)
            context.fill(rect)
        case .blur:
            drawBlur(in: context, source: source, rect: rect)
        case .sketch:
            drawSketch(in: context, source: source, rect: rect)
        case .sticker:
            drawSticker(in: context, source: source, rect: rect,
                        stickerOverride: maskedBox.sticker)
        }
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

    /// 框的外接圆包围盒（圆心为框中心，半径为框对角线的一半），
    /// 与 Android `BlurEffects.circumscribedCircleBounds` 一致。
    private static func circumscribedCircleBounds(for rect: CGRect) -> CGRect {
        let radius = hypot(rect.width, rect.height) / 2
        return CGRect(x: rect.midX - radius, y: rect.midY - radius,
                      width: radius * 2, height: radius * 2)
    }

    // MARK: - 描边

    /// 描边线宽：`max(4, min(宽,高) * 0.04)`，与 Android
    /// `BlurEffects.outlineStrokeWidth` 一致。
    private static func outlineStrokeWidth(for rect: CGRect) -> CGFloat {
        return max(4, min(rect.width, rect.height) * 0.04)
    }

    /// 给需要描边的框画红色粗边（贴纸模式不画，与 Android 一致；
    /// 描边向内缩 stroke/2，线不超出框外）。
    private static func drawOutlines(boxes: [MaskedBox], bounds: CGRect, in context: CGContext) {
        for maskedBox in boxes {
            guard maskedBox.outline, maskedBox.effect != .sticker else { continue }
            let rect = scaledClampedRect(maskedBox, in: bounds)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let stroke = outlineStrokeWidth(for: rect)
            let inset = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
            guard inset.width > 0, inset.height > 0 else { continue }
            context.saveGState()
            context.setStrokeColor(UIColor.red.cgColor)
            context.setLineWidth(stroke)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            if maskedBox.circular {
                let circle = circumscribedCircleBounds(for: rect)
                let radius = max(0, hypot(circle.width, circle.height) / 2 - stroke / 2)
                context.addEllipse(in: CGRect(
                    x: circle.midX - radius, y: circle.midY - radius,
                    width: radius * 2, height: radius * 2))
                context.strokePath()
            } else {
                context.stroke(inset)
            }
            context.restoreGState()
        }
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

    /// 块大小取当前设置的 `mosaicBlockSize`（预设值，例如 ZISUE 的 19），
    /// 与 Android `drawMosaic(canvas, source, rect, getMosaicBlockSize())`
    /// 一致；旧实现按框尺寸算 `min(宽,高)/12` 且忽略设置，导致块大小
    /// 不对（小框上只有两三块、看起来像纯色块）。
    /// 每块取左上角像素颜色填充整块（与 Android
    /// `BlurEffects.createMosaicBitmap` 的取样方式一致），块大、格子清楚，
    /// 与预设视频里的效果一致。
    private static func drawMosaic(in context: CGContext, source: CGImage, rect: CGRect) {
        let pixelRect = integralRect(rect, width: source.width, height: source.height)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let buffer = extractPixels(from: source, rect: pixelRect) else { return }
        let blockSize = max(1, PrivacySettingsManager.shared.mosaicBlockSize)
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

    /// 只模糊框内区域：裁剪出框区域 → `CIGaussianBlur` → 合成回原位置。
    /// 半径取当前设置的 `gaussianRadius`（预设值，例如 ZISUE 的 47），
    /// 与 Android `drawGaussian(canvas, source, rect, getGaussianRadius())`
    /// 一致；旧实现写死 12，设置页的滑杆不起作用。
    private static func drawBlur(in context: CGContext, source: CGImage, rect: CGRect) {
        let pixelRect = integralRect(rect, width: source.width, height: source.height)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = source.cropping(to: pixelRect) else { return }
        let input = CIImage(cgImage: cropped).clampedToExtent()
        guard let filter = CIFilter(
            name: "CIGaussianBlur",
            parameters: [
                kCIInputImageKey: input,
                kCIInputRadiusKey: CGFloat(PrivacySettingsManager.shared.gaussianRadius)
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
    /// 缩放后居中绘制到框上。`stickerOverride` 为该标签指定的贴纸
    /// （预设 `labelStickerUris`），nil 时用默认贴纸；贴纸图缺失时
    /// 回退为马赛克，避免敏感内容裸露。
    private static func drawSticker(
        in context: CGContext, source: CGImage, rect: CGRect, stickerOverride: UIImage? = nil
    ) {
        guard let sticker = stickerOverride ?? StickerLoader.defaultSticker(),
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
