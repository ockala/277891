import CoreGraphics
import Foundation

/// 打码效果。对应 Android `PrivacySettingsManager` 的遮挡模式编号
/// （0 马赛克、1 纯黑、2 高斯、3 贴纸、4 素描），iOS 版去掉 Android
/// 专属的 5 号眼睛模式（眼睛遮挡由 EYE_REGION 标签 + 任一效果实现）。
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
}

/// 一个待打码的检测框。`box` 为原图像素坐标（左上角原点），
/// `scale` 为遮罩缩放倍数（以框中心缩放，见 `MaskRenderer`）。
public struct MaskedBox {
    public let box: CGRect
    public let effect: MaskEffect
    public let scale: CGFloat

    public init(box: CGRect, effect: MaskEffect, scale: CGFloat = 1.0) {
        self.box = box
        self.effect = effect
        self.scale = scale
    }
}
