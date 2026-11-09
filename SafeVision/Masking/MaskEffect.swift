import CoreGraphics
import Foundation
import UIKit

/// 打码效果。对应 Android `PrivacySettingsManager` 的遮挡模式编号
/// （0 马赛克、1 纯黑、2 高斯、3 贴纸、4 素描），iOS 版去掉 Android
/// 专属的 5 号眼睛模式（眼睛遮挡由 EYE_REGION 标签 + 任一效果实现；
/// 预设里 mode 5 会按 Android `resolveRenderMode` 回退为默认效果）。
public enum MaskEffect: String, CaseIterable, Codable {
    case mosaic
    case black
    case blur
    case sketch
    case sticker

    public var displayName: String {
        switch self {
        case .mosaic: return "马赛克"
        case .black: return "纯黑块"
        case .blur: return "高斯模糊"
        case .sketch: return "素描"
        case .sticker: return "贴纸"
        }
    }

    /// Android 遮挡模式编号（`PrivacySettingsManager.BLUR_MODE_*`）。
    public var androidBlurMode: Int {
        switch self {
        case .mosaic: return 0
        case .black: return 1
        case .blur: return 2
        case .sticker: return 3
        case .sketch: return 4
        }
    }

    /// Android 遮挡模式编号 -> iOS 效果。5 号眼睛模式没有 iOS 对应
    /// 效果，返回 nil，调用方按 Android `resolveRenderMode` 回退为
    /// 预设默认效果（默认效果也是 5 时再回退为马赛克）。
    public static func fromAndroidBlurMode(_ mode: Int) -> MaskEffect? {
        switch mode {
        case 0: return .mosaic
        case 1: return .black
        case 2: return .blur
        case 3: return .sticker
        case 4: return .sketch
        default: return nil
        }
    }
}

/// 一个待打码的检测框。`box` 为原图像素坐标（左上角原点），
/// `scale` 为遮罩缩放倍数（以框中心缩放，见 `MaskRenderer`）。
public struct MaskedBox {
    public let box: CGRect
    public let effect: MaskEffect
    public let scale: CGFloat
    /// 该框是否画红色描边（Android `maskOutlineLabels`，贴纸模式不画）。
    public let outline: Bool
    /// 该框是否用圆形遮罩（Android `circularMaskEnabled`，眼睛条不用）。
    public let circular: Bool
    /// 该框用的贴纸图（nil 时用默认贴纸；贴纸缺失时回退为马赛克）。
    public let sticker: UIImage?

    public init(
        box: CGRect,
        effect: MaskEffect,
        scale: CGFloat = 1.0,
        outline: Bool = false,
        circular: Bool = false,
        sticker: UIImage? = nil
    ) {
        self.box = box
        self.effect = effect
        self.scale = scale
        self.outline = outline
        self.circular = circular
        self.sticker = sticker
    }
}
