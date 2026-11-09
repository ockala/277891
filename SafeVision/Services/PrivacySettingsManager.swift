import Combine
import CoreGraphics
import Foundation
import UIKit

/// 一组隐私设置快照（预设）。`labelEffects` 存 `MaskEffect.rawValue`，
/// 缺失的标签在应用时回退到预设的 `defaultEffect`。
///
/// **结构说明**：Android 的 `PrivacyPreset` 是按模型分档的（标准 +
/// 动漫两套 `PresetLabelState`，再加标准/动漫的 `blurMode`、
/// `stickerUri`、`maskScale`）。iOS 的标签名在两个模型下不重叠
/// （标准模型用 `FEMALE_BREAST_EXPOSED` 等英文大写名，动漫模型用
/// `Boob` / `Pussy` 等），所以标签维度的设置（打哪些标签、每标签
/// 效果、每标签贴纸、每标签缩放、反向标签、描边标签）用一张以标签名
/// 为键的平表就能同时装下两个模型；只有三个全局量按模型分档存
/// （`defaultEffect` / `animeDefaultEffect`、`maskScale` /
/// `animeMaskScale`、`stickerUri` / `animeStickerUri`）。
///
/// 字段默认值与 Android `PrivacySettingsManager` 一致：
/// mosaic 12...60 默认 20，gaussian 6...50 默认 12，mask scale
/// 0.1...3 默认 1.0，reversePreRender 默认 true。
public struct PrivacyPreset: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var labelEffects: [String: String] // label -> MaskEffect.rawValue
    public var labelEnabled: [String: Bool]
    public var labelScales: [String: Double]
    public var defaultEffect: String
    public var isBuiltIn: Bool

    /// 动漫模型的默认遮挡效果。nil 时用 `defaultEffect`。
    public var animeDefaultEffect: String?

    // MARK: - 全局遮挡参数（对应 Android PrivacyPreset 的同名字段）

    /// 是否画圆形遮挡（Android `circularMaskEnabled`）。
    public var circularMaskEnabled: Bool
    /// 是否画红色描边（Android `maskOutlineEnabled`；贴纸模式不描边）。
    public var maskOutlineEnabled: Bool
    /// 马赛克块大小（Android 12...60，默认 20；ZISUE 预设为 19）。
    public var mosaicBlockSize: Int
    /// 高斯模糊半径（Android 6...50，默认 12；ZISUE 预设为 47）。
    public var gaussianRadius: Int
    /// 遮挡放大倍率（Android 0.1...3，默认 1.0）。
    public var maskScale: Double
    /// 动漫模型的遮挡放大倍率。nil 时用 `maskScale`。
    public var animeMaskScale: Double?
    /// 默认贴纸引用。nil 时用内置默认贴纸。`internal:stickers/...`
    /// 为 `.svpreset` 包内引用，导入后会改写为
    /// `ImportedStickers/<预设名>/<文件名>`。
    public var stickerUri: String?
    /// 动漫模型的默认贴纸引用。nil 时用 `stickerUri`。
    public var animeStickerUri: String?
    /// 每标签的贴纸引用（Android `labelStickerUris`）。
    public var labelStickerUris: [String: String]
    /// 反向标签（Android `reverseLabels`）：检测到时只保留这些标签
    /// 的区域清晰，其余全部打码。
    public var reverseLabels: [String]
    /// 需要描边的标签（Android `maskOutlineLabels`；空数组表示全部描边）。
    public var maskOutlineLabels: [String]
    /// 反向优先渲染（Android `reversePreRenderEnabled`，默认 true）：
    /// 命中反向遮挡时先渲染反向遮挡，再渲染贴纸和其它效果。
    public var reversePreRenderEnabled: Bool
    /// 反向未命中回退全屏遮挡（Android `reverseLabelMissFullscreenEnabled`，
    /// 默认 false）：配置了反向标签但一张图里一个都没检测到时整图打码。
    public var reverseLabelMissFullscreenEnabled: Bool
    /// 空识别回退全屏遮挡（Android
    /// `accessibilityEmptyReverseFullscreenEnabled`，默认 false）：
    /// 屏幕识别无任何内容时整图打码。
    public var accessibilityEmptyReverseFullscreenEnabled: Bool

    /// 内置默认预设的固定 ID（跨启动稳定，持久化后仍能认出它）。
    public static let builtInID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let builtInName = "默认"

    public init(
        id: UUID = UUID(),
        name: String,
        labelEffects: [String: String] = [:],
        labelEnabled: [String: Bool] = [:],
        labelScales: [String: Double] = [:],
        defaultEffect: String = MaskEffect.mosaic.rawValue,
        isBuiltIn: Bool = false,
        animeDefaultEffect: String? = nil,
        circularMaskEnabled: Bool = false,
        maskOutlineEnabled: Bool = false,
        mosaicBlockSize: Int = 20,
        gaussianRadius: Int = 12,
        maskScale: Double = 1.0,
        animeMaskScale: Double? = nil,
        stickerUri: String? = nil,
        animeStickerUri: String? = nil,
        labelStickerUris: [String: String] = [:],
        reverseLabels: [String] = [],
        maskOutlineLabels: [String] = [],
        reversePreRenderEnabled: Bool = true,
        reverseLabelMissFullscreenEnabled: Bool = false,
        accessibilityEmptyReverseFullscreenEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.labelEffects = labelEffects
        self.labelEnabled = labelEnabled
        self.labelScales = labelScales
        self.defaultEffect = defaultEffect
        self.isBuiltIn = isBuiltIn
        self.animeDefaultEffect = animeDefaultEffect
        self.circularMaskEnabled = circularMaskEnabled
        self.maskOutlineEnabled = maskOutlineEnabled
        self.mosaicBlockSize = mosaicBlockSize
        self.gaussianRadius = gaussianRadius
        self.maskScale = maskScale
        self.animeMaskScale = animeMaskScale
        self.stickerUri = stickerUri
        self.animeStickerUri = animeStickerUri
        self.labelStickerUris = labelStickerUris
        self.reverseLabels = reverseLabels
        self.maskOutlineLabels = maskOutlineLabels
        self.reversePreRenderEnabled = reversePreRenderEnabled
        self.reverseLabelMissFullscreenEnabled = reverseLabelMissFullscreenEnabled
        self.accessibilityEmptyReverseFullscreenEnabled = accessibilityEmptyReverseFullscreenEnabled
    }

    /// 旧版保存的预设没有新字段：用 `decodeIfPresent` + 默认值，
    /// 保证旧预设仍能解码。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        labelEffects = try container.decodeIfPresent([String: String].self, forKey: .labelEffects) ?? [:]
        labelEnabled = try container.decodeIfPresent([String: Bool].self, forKey: .labelEnabled) ?? [:]
        labelScales = try container.decodeIfPresent([String: Double].self, forKey: .labelScales) ?? [:]
        defaultEffect = try container.decodeIfPresent(String.self, forKey: .defaultEffect)
            ?? MaskEffect.mosaic.rawValue
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        animeDefaultEffect = try container.decodeIfPresent(String.self, forKey: .animeDefaultEffect)
        circularMaskEnabled = try container.decodeIfPresent(Bool.self, forKey: .circularMaskEnabled) ?? false
        maskOutlineEnabled = try container.decodeIfPresent(Bool.self, forKey: .maskOutlineEnabled) ?? false
        mosaicBlockSize = try container.decodeIfPresent(Int.self, forKey: .mosaicBlockSize) ?? 20
        gaussianRadius = try container.decodeIfPresent(Int.self, forKey: .gaussianRadius) ?? 12
        maskScale = try container.decodeIfPresent(Double.self, forKey: .maskScale) ?? 1.0
        animeMaskScale = try container.decodeIfPresent(Double.self, forKey: .animeMaskScale)
        stickerUri = try container.decodeIfPresent(String.self, forKey: .stickerUri)
        animeStickerUri = try container.decodeIfPresent(String.self, forKey: .animeStickerUri)
        labelStickerUris = try container.decodeIfPresent([String: String].self, forKey: .labelStickerUris) ?? [:]
        reverseLabels = try container.decodeIfPresent([String].self, forKey: .reverseLabels) ?? []
        maskOutlineLabels = try container.decodeIfPresent([String].self, forKey: .maskOutlineLabels) ?? []
        reversePreRenderEnabled = try container.decodeIfPresent(Bool.self, forKey: .reversePreRenderEnabled) ?? true
        reverseLabelMissFullscreenEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .reverseLabelMissFullscreenEnabled) ?? false
        accessibilityEmptyReverseFullscreenEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .accessibilityEmptyReverseFullscreenEnabled) ?? false
    }

    /// 内置默认预设：默认效果马赛克，所有标签启用，缩放 1.0，不可删除。
    public static func builtIn() -> PrivacyPreset {
        var enabled: [String: Bool] = [:]
        var scales: [String: Double] = [:]
        for label in DetectionConfig.allLabels {
            enabled[label] = true
            scales[label] = 1.0
        }
        return PrivacyPreset(
            id: builtInID,
            name: builtInName,
            labelEffects: [:],
            labelEnabled: enabled,
            labelScales: scales,
            defaultEffect: MaskEffect.mosaic.rawValue,
            isBuiltIn: true
        )
    }
}

/// 隐私设置（UserDefaults 持久化，ObservableObject）。
///
/// 对应 Android `PrivacySettingsManager`：效果模式、每标签开关 / 效果 /
///
/// 缩放、马赛克块大小、高斯半径、预设。范围与默认值与 Android 一致：
/// 马赛克块大小 12...60（默认 20）、高斯半径 6...50（默认 12）、
/// 遮罩缩放 0.1...3（默认 1.0）。
///
/// 注意：旧版对 `FEMALE_GENITALIA_EXPOSED` /
/// `FEMALE_BREAST_EXPOSED`（标准）和 `Boob` / `Pussy`（动漫）
/// 做了强制锁定（`DetectionConfig.lockedLabels`），开关关不掉。
/// 已按用户要求去掉锁定：所有标签都可自由开关，默认仍为打码，
/// 用户自己关了才是她自己的选择。
public final class PrivacySettingsManager: ObservableObject {

    public static let shared = PrivacySettingsManager()

    public static let mosaicBlockSizeRange = 12...60
    public static let gaussianRadiusRange = 6...50
    public static let maskScaleRange: ClosedRange<CGFloat> = 0.1...3.0

    private enum Keys {
        static let labelEffects = "com.safevision.privacy.labelEffects"
        static let labelEnabled = "com.safevision.privacy.labelEnabled"
        static let labelScales = "com.safevision.privacy.labelScales"
        static let defaultEffect = "com.safevision.privacy.defaultEffect"
        static let mosaicBlockSize = "com.safevision.privacy.mosaicBlockSize"
        static let gaussianRadius = "com.safevision.privacy.gaussianRadius"
        static let presets = "com.safevision.privacy.presets"
        static let activePresetID = "com.safevision.privacy.activePresetID"
        static let circularMaskEnabled = "com.safevision.privacy.circularMaskEnabled"
        static let maskOutlineEnabled = "com.safevision.privacy.maskOutlineEnabled"
        static let maskScale = "com.safevision.privacy.maskScale"
        static let stickerUri = "com.safevision.privacy.stickerUri"
        static let labelStickerUris = "com.safevision.privacy.labelStickerUris"
        static let reverseLabels = "com.safevision.privacy.reverseLabels"
        static let maskOutlineLabels = "com.safevision.privacy.maskOutlineLabels"
        static let reversePreRenderEnabled = "com.safevision.privacy.reversePreRenderEnabled"
        static let reverseLabelMissFullscreenEnabled = "com.safevision.privacy.reverseLabelMissFullscreenEnabled"
        static let accessibilityEmptyReverseFullscreenEnabled = "com.safevision.privacy.accessibilityEmptyReverseFullscreenEnabled"
    }

    @Published public var labelEffects: [String: MaskEffect] {
        didSet { persistLabelEffects() }
    }

    @Published public var labelEnabled: [String: Bool] {
        didSet { persistLabelEnabled() }
    }

    @Published public var labelScales: [String: CGFloat] {
        didSet {
            let clamped = labelScales.mapValues {
                min(Self.maskScaleRange.upperBound, max(Self.maskScaleRange.lowerBound, $0))
            }
            if clamped != labelScales {
                labelScales = clamped
                return
            }
            persistLabelScales()
        }
    }

    @Published public var defaultEffect: MaskEffect {
        didSet {
            UserDefaults.standard.set(defaultEffect.rawValue, forKey: Keys.defaultEffect)
        }
    }

    /// 马赛克块大小，12...60，默认 20。
    @Published public var mosaicBlockSize: Int {
        didSet {
            let clamped = min(
                Self.mosaicBlockSizeRange.upperBound,
                max(Self.mosaicBlockSizeRange.lowerBound, mosaicBlockSize)
            )
            if clamped != mosaicBlockSize {
                mosaicBlockSize = clamped
                return
            }
            UserDefaults.standard.set(mosaicBlockSize, forKey: Keys.mosaicBlockSize)
        }
    }

    /// 高斯模糊半径，6...50，默认 12。
    @Published public var gaussianRadius: Int {
        didSet {
            let clamped = min(
                Self.gaussianRadiusRange.upperBound,
                max(Self.gaussianRadiusRange.lowerBound, gaussianRadius)
            )
            if clamped != gaussianRadius {
                gaussianRadius = clamped
                return
            }
            UserDefaults.standard.set(gaussianRadius, forKey: Keys.gaussianRadius)
        }
    }

    /// 是否画圆形遮挡（Android `circularMaskEnabled`）。
    @Published public var circularMaskEnabled: Bool = false {
        didSet { UserDefaults.standard.set(circularMaskEnabled, forKey: Keys.circularMaskEnabled) }
    }

    /// 是否画红色描边（Android `maskOutlineEnabled`；贴纸模式不描边）。
    @Published public var maskOutlineEnabled: Bool = false {
        didSet { UserDefaults.standard.set(maskOutlineEnabled, forKey: Keys.maskOutlineEnabled) }
    }

    /// 遮挡放大倍率（Android 0.1...3，默认 1.0）。缺省的标签用这个。
    @Published public var maskScale: CGFloat = 1.0 {
        didSet {
            let clamped = min(
                Self.maskScaleRange.upperBound, max(Self.maskScaleRange.lowerBound, maskScale))
            if clamped != maskScale {
                maskScale = clamped
                return
            }
            UserDefaults.standard.set(Double(maskScale), forKey: Keys.maskScale)
        }
    }

    /// 默认贴纸引用。nil 时用内置默认贴纸。
    @Published public var stickerUri: String? = nil {
        didSet {
            if let uri = stickerUri {
                UserDefaults.standard.set(uri, forKey: Keys.stickerUri)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.stickerUri)
            }
        }
    }

    /// 每标签的贴纸引用（Android `labelStickerUris`）。
    @Published public var labelStickerUris: [String: String] = [:] {
        didSet { persistLabelStickerUris() }
    }

    /// 反向标签（Android `reverseLabels`）：检测到时只保留这些标签
    /// 的区域清晰，其余全部打码。
    @Published public var reverseLabels: [String] = [] {
        didSet { persistReverseLabels() }
    }

    /// 需要描边的标签（Android `maskOutlineLabels`；空数组表示全部描边）。
    @Published public var maskOutlineLabels: [String] = [] {
        didSet { persistMaskOutlineLabels() }
    }

    /// 反向优先渲染（Android `reversePreRenderEnabled`，默认 true）。
    @Published public var reversePreRenderEnabled: Bool = true {
        didSet { UserDefaults.standard.set(reversePreRenderEnabled, forKey: Keys.reversePreRenderEnabled) }
    }

    /// 反向未命中回退全屏遮挡（Android `reverseLabelMissFullscreenEnabled`）。
    @Published public var reverseLabelMissFullscreenEnabled: Bool = false {
        didSet { UserDefaults.standard.set(reverseLabelMissFullscreenEnabled, forKey: Keys.reverseLabelMissFullscreenEnabled) }
    }

    /// 空识别回退全屏遮挡（Android `accessibilityEmptyReverseFullscreenEnabled`）。
    @Published public var accessibilityEmptyReverseFullscreenEnabled: Bool = false {
        didSet { UserDefaults.standard.set(accessibilityEmptyReverseFullscreenEnabled, forKey: Keys.accessibilityEmptyReverseFullscreenEnabled) }
    }

    @Published public var presets: [PrivacyPreset] {
        didSet {
            // 内置预设必须始终存在（防止外部直接改数组把它删掉）。
            if !presets.contains(where: { $0.isBuiltIn }) {
                presets.insert(PrivacyPreset.builtIn(), at: 0)
                return
            }
            persistPresets()
        }
    }

    @Published public var activePresetID: UUID? {
        didSet {
            let defaults = UserDefaults.standard
            if let id = activePresetID {
                defaults.set(id.uuidString, forKey: Keys.activePresetID)
            } else {
                defaults.removeObject(forKey: Keys.activePresetID)
            }
        }
    }

    public init() {
        let defaults = UserDefaults.standard

        if let rawValue = defaults.string(forKey: Keys.defaultEffect),
           let effect = MaskEffect(rawValue: rawValue) {
            self.defaultEffect = effect
        } else {
            self.defaultEffect = .mosaic
        }

        if let data = defaults.data(forKey: Keys.labelEffects),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            self.labelEffects = raw.compactMapValues { MaskEffect(rawValue: $0) }
        } else {
            self.labelEffects = [:]
        }

        var enabled: [String: Bool] = [:]
        if let data = defaults.data(forKey: Keys.labelEnabled),
           let stored = try? JSONDecoder().decode([String: Bool].self, from: data) {
            enabled = stored
        }
        for label in DetectionConfig.allLabels where enabled[label] == nil {
            enabled[label] = true
        }
        self.labelEnabled = enabled

        if let data = defaults.data(forKey: Keys.labelScales),
           let stored = try? JSONDecoder().decode([String: Double].self, from: data) {
            self.labelScales = stored.mapValues { CGFloat($0) }
        } else {
            self.labelScales = [:]
        }

        let storedBlockSize = defaults.object(forKey: Keys.mosaicBlockSize) as? Int
        self.mosaicBlockSize = min(
            Self.mosaicBlockSizeRange.upperBound,
            max(Self.mosaicBlockSizeRange.lowerBound, storedBlockSize ?? 20)
        )

        let storedRadius = defaults.object(forKey: Keys.gaussianRadius) as? Int
        self.gaussianRadius = min(
            Self.gaussianRadiusRange.upperBound,
            max(Self.gaussianRadiusRange.lowerBound, storedRadius ?? 12)
        )

        self.circularMaskEnabled = defaults.bool(forKey: Keys.circularMaskEnabled)
        self.maskOutlineEnabled = defaults.bool(forKey: Keys.maskOutlineEnabled)
        if let storedScale = defaults.object(forKey: Keys.maskScale) as? Double {
            self.maskScale = min(
                Self.maskScaleRange.upperBound,
                max(Self.maskScaleRange.lowerBound, CGFloat(storedScale)))
        } else {
            self.maskScale = 1.0
        }
        self.stickerUri = defaults.string(forKey: Keys.stickerUri)
        if let data = defaults.data(forKey: Keys.labelStickerUris),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            self.labelStickerUris = stored
        } else {
            self.labelStickerUris = [:]
        }
        if let data = defaults.data(forKey: Keys.reverseLabels),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            self.reverseLabels = stored
        } else {
            self.reverseLabels = []
        }
        if let data = defaults.data(forKey: Keys.maskOutlineLabels),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            self.maskOutlineLabels = stored
        } else {
            self.maskOutlineLabels = []
        }
        self.reversePreRenderEnabled = defaults.object(forKey: Keys.reversePreRenderEnabled) as? Bool ?? true
        self.reverseLabelMissFullscreenEnabled = defaults.bool(forKey: Keys.reverseLabelMissFullscreenEnabled)
        self.accessibilityEmptyReverseFullscreenEnabled = defaults.bool(forKey: Keys.accessibilityEmptyReverseFullscreenEnabled)

        if let data = defaults.data(forKey: Keys.presets),
           let stored = try? JSONDecoder().decode([PrivacyPreset].self, from: data),
           !stored.isEmpty {
            self.presets = stored
        } else {
            self.presets = [PrivacyPreset.builtIn()]
        }
        if !self.presets.contains(where: { $0.isBuiltIn }) {
            self.presets.insert(PrivacyPreset.builtIn(), at: 0)
        }

        if let idString = defaults.string(forKey: Keys.activePresetID),
           let id = UUID(uuidString: idString),
           self.presets.contains(where: { $0.id == id }) {
            self.activePresetID = id
        } else {
            self.activePresetID = PrivacyPreset.builtInID
        }
    }

    // MARK: - 查询

    /// 标签的打码效果；未单独设置时用默认效果。
    public func effect(for label: String) -> MaskEffect {
        return labelEffects[label] ?? defaultEffect
    }

    /// 标签是否启用遮挡（锁定已取消：所有标签都可自由开关）。
    public func isEnabled(_ label: String) -> Bool {
        return labelEnabled[label] ?? true
    }

    /// 标签的遮罩缩放倍数（0.1...3，未设置时用全局 `maskScale`）。
    public func scale(for label: String) -> CGFloat {
        let raw = labelScales[label] ?? maskScale
        return min(Self.maskScaleRange.upperBound, max(Self.maskScaleRange.lowerBound, raw))
    }

    /// 该标签是否反向标签。
    public func isReverseLabel(_ label: String) -> Bool {
        return reverseLabels.contains(label)
    }

    /// 该标签是否需要描边。描边总开关关着时一律不描；描边标签列表
    /// 为空时表示全部描边（与 Android `maskOutlineLabels` 为空时的
    /// 默认行为一致）。
    public func shouldOutline(_ label: String) -> Bool {
        guard maskOutlineEnabled else { return false }
        if maskOutlineLabels.isEmpty { return true }
        return maskOutlineLabels.contains(label)
    }

    /// 默认贴纸图（按 `stickerUri` 解析；nil 时用内置默认贴纸）。
    public func defaultStickerImage() -> UIImage? {
        return StickerLoader.stickerImage(forURI: stickerUri)
    }

    /// 该标签的贴纸图：标签贴纸（`labelStickerUris`）优先，否则默认贴纸。
    /// 标签贴纸引用缺失/解码失败时回退为默认贴纸。
    public func sticker(for label: String) -> UIImage? {
        if let uri = labelStickerUris[label],
           let image = StickerLoader.stickerImage(forURI: uri) {
            return image
        }
        return defaultStickerImage()
    }

    /// 把检测结果转成待渲染的打码框：只保留启用的标签。
    /// 框上附带描边、圆形、贴纸信息，供 `MaskRenderer` 直接使用。
    public func maskedBoxes(for detections: [Detection]) -> [MaskedBox] {
        // 先显式过滤掉未启用的标签，再逐个转成打码框（不用 compactMap +
        // return nil：多返回分支下编译器会把闭包返回类型推断为非可选
        // 的 MaskedBox，导致 return nil 报错）。
        return detections
            .filter { isEnabled($0.label) }
            .map { detection in
                let effect = effect(for: detection.label)
                let isEye = DetectionConfig.isEyeRegionLabel(detection.label)
                return MaskedBox(
                    box: detection.box,
                    effect: effect,
                    scale: scale(for: detection.label),
                    outline: shouldOutline(detection.label),
                    circular: circularMaskEnabled && !isEye,
                    sticker: effect == .sticker ? sticker(for: detection.label) : nil
                )
            }
    }

    // MARK: - 预设

    /// 把当前设置存为新预设并设为活动预设。同名用户预设会被覆盖；
    /// 内置预设（"默认"）不许覆盖，调用会被忽略。
    /// `profile` 决定当前值写入预设的哪一档（标准 / 动漫的默认效果、
    /// 缩放倍率、默认贴纸）；覆盖同名预设时另一档的值从旧预设保留，
    /// 新建时两档都写当前值，保证预设在两个模型下都能用。
    public func savePreset(name: String, profile: LabelProfile = .standard) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if presets.contains(where: { $0.name == trimmed && $0.isBuiltIn }) { return }
        if let index = presets.firstIndex(where: { $0.name == trimmed && !$0.isBuiltIn }) {
            var preset = presets[index]
            updatePreset(&preset, fromCurrentSettings: profile)
            presets[index] = preset
            activePresetID = preset.id
            return
        }
        var preset = PrivacyPreset(id: UUID(), name: trimmed, isBuiltIn: false)
        updatePreset(&preset, fromCurrentSettings: profile)
        // 新建时两档都写当前值。
        if profile == .standard {
            preset.animeDefaultEffect = preset.defaultEffect
            preset.animeMaskScale = preset.maskScale
            preset.animeStickerUri = preset.stickerUri
        } else {
            preset.defaultEffect = preset.animeDefaultEffect ?? preset.defaultEffect
            preset.maskScale = preset.animeMaskScale ?? preset.maskScale
            preset.stickerUri = preset.animeStickerUri ?? preset.stickerUri
        }
        presets.append(preset)
        activePresetID = preset.id
    }

    private func updatePreset(_ preset: inout PrivacyPreset, fromCurrentSettings profile: LabelProfile) {
        preset.labelEffects = labelEffects.mapValues { $0.rawValue }
        preset.labelEnabled = labelEnabled
        preset.labelScales = labelScales.mapValues { Double($0) }
        preset.circularMaskEnabled = circularMaskEnabled
        preset.maskOutlineEnabled = maskOutlineEnabled
        preset.mosaicBlockSize = mosaicBlockSize
        preset.gaussianRadius = gaussianRadius
        preset.labelStickerUris = labelStickerUris
        preset.reverseLabels = reverseLabels
        preset.maskOutlineLabels = maskOutlineLabels
        preset.reversePreRenderEnabled = reversePreRenderEnabled
        preset.reverseLabelMissFullscreenEnabled = reverseLabelMissFullscreenEnabled
        preset.accessibilityEmptyReverseFullscreenEnabled = accessibilityEmptyReverseFullscreenEnabled
        if profile == .anime {
            preset.animeDefaultEffect = defaultEffect.rawValue
            preset.animeMaskScale = Double(maskScale)
            preset.animeStickerUri = stickerUri
        } else {
            preset.defaultEffect = defaultEffect.rawValue
            preset.maskScale = Double(maskScale)
            preset.stickerUri = stickerUri
        }
    }

    /// 应用预设：恢复其中保存的默认效果、各标签效果 / 开关 / 缩放、
    /// 描边、反向标签、贴纸等，并把它设为活动预设。预设里缺失的标签
    /// 回退到预设的默认效果。`profile` 决定用预设里哪档全局值
    /// （标准 / 动漫的默认效果、缩放倍率、默认贴纸）。
    public func applyPreset(_ preset: PrivacyPreset, profile: LabelProfile = .standard) {
        if profile == .anime, let animeEffect = preset.animeDefaultEffect,
           let effect = MaskEffect(rawValue: animeEffect) {
            defaultEffect = effect
        } else {
            defaultEffect = MaskEffect(rawValue: preset.defaultEffect) ?? .mosaic
        }
        labelEffects = preset.labelEffects.compactMapValues { MaskEffect(rawValue: $0) }
        labelEnabled = preset.labelEnabled
        labelScales = preset.labelScales.mapValues { CGFloat($0) }
        circularMaskEnabled = preset.circularMaskEnabled
        maskOutlineEnabled = preset.maskOutlineEnabled
        mosaicBlockSize = preset.mosaicBlockSize
        gaussianRadius = preset.gaussianRadius
        if profile == .anime, let animeScale = preset.animeMaskScale {
            maskScale = CGFloat(animeScale)
        } else {
            maskScale = CGFloat(preset.maskScale)
        }
        if profile == .anime, let animeSticker = preset.animeStickerUri {
            stickerUri = animeSticker
        } else {
            stickerUri = preset.stickerUri
        }
        labelStickerUris = preset.labelStickerUris
        reverseLabels = preset.reverseLabels
        maskOutlineLabels = preset.maskOutlineLabels
        reversePreRenderEnabled = preset.reversePreRenderEnabled
        reverseLabelMissFullscreenEnabled = preset.reverseLabelMissFullscreenEnabled
        accessibilityEmptyReverseFullscreenEnabled = preset.accessibilityEmptyReverseFullscreenEnabled
        activePresetID = preset.id
    }

    /// 删除预设。内置预设不许删，调用会被忽略。删掉的是活动预设时，
    /// 活动预设回到内置默认预设。
    public func deletePreset(_ preset: PrivacyPreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id {
            activePresetID = PrivacyPreset.builtInID
        }
    }

    /// 恢复出厂默认：默认效果马赛克、所有标签启用、缩放 1.0、
    /// 马赛克块大小 20、高斯半径 12，活动预设回到内置默认预设。
    /// 用户自建预设保留，不会被删除。
    public func resetToDefaults() {
        defaultEffect = .mosaic
        labelEffects = [:]
        var enabled: [String: Bool] = [:]
        for label in DetectionConfig.allLabels { enabled[label] = true }
        labelEnabled = enabled
        labelScales = [:]
        mosaicBlockSize = 20
        gaussianRadius = 12
        circularMaskEnabled = false
        maskOutlineEnabled = false
        maskScale = 1.0
        stickerUri = nil
        labelStickerUris = [:]
        reverseLabels = []
        maskOutlineLabels = []
        reversePreRenderEnabled = true
        reverseLabelMissFullscreenEnabled = false
        accessibilityEmptyReverseFullscreenEnabled = false
        activePresetID = PrivacyPreset.builtInID
    }

    // MARK: - 持久化

    private func persistLabelEffects() {
        let raw = labelEffects.mapValues { $0.rawValue }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Keys.labelEffects)
        }
    }

    private func persistLabelEnabled() {
        if let data = try? JSONEncoder().encode(labelEnabled) {
            UserDefaults.standard.set(data, forKey: Keys.labelEnabled)
        }
    }

    private func persistLabelScales() {
        let raw = labelScales.mapValues { Double($0) }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Keys.labelScales)
        }
    }

    private func persistLabelStickerUris() {
        if let data = try? JSONEncoder().encode(labelStickerUris) {
            UserDefaults.standard.set(data, forKey: Keys.labelStickerUris)
        }
    }

    private func persistReverseLabels() {
        if let data = try? JSONEncoder().encode(reverseLabels) {
            UserDefaults.standard.set(data, forKey: Keys.reverseLabels)
        }
    }

    private func persistMaskOutlineLabels() {
        if let data = try? JSONEncoder().encode(maskOutlineLabels) {
            UserDefaults.standard.set(data, forKey: Keys.maskOutlineLabels)
        }
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Keys.presets)
        }
    }
}

// MARK: - .svpreset 导入

/// `.svpreset.zip`（Android 原版预设导出格式）导入结果。
public struct PresetImportResult {
    public var imported: [String] = []
    public var skipped: [String] = []
    public var error: String?
}

/// Android `.svpreset` 包的 manifest 结构。
private struct PresetPackageManifest: Decodable {
    var packageType: String?
    var packageVersion: Int?
    var order: [String]?
    var data: [String: PresetManifestData]?
}

/// Android `PresetLabelState`（分档格式里的一档：标准或动漫）。
private struct PresetManifestLabelState: Decodable {
    var blockedLabels: [String]?
    var labelStickerUris: [String: String]?
    var labelMaskScales: [String: Double]?
    var labelEffectOverrides: [String: Int]?
    var reverseLabels: [String]?
    var maskOutlineLabels: [String]?
}

/// Android `.svpreset` 包里一个预设的 manifest 内容（平铺格式，
/// 或带 `profileLabelStates` 的分档格式）。
private struct PresetManifestData: Decodable {
    var blurMode: Int?
    var animeBlurMode: Int?
    var circularMaskEnabled: Bool?
    var maskOutlineEnabled: Bool?
    var mosaicBlockSize: Int?
    var gaussianRadius: Int?
    var maskScale: Double?
    var animeMaskScale: Double?
    var stickerUri: String?
    var animeStickerUri: String?
    var labelStickerUris: [String: String]?
    var labelMaskScales: [String: Double]?
    var blockedLabels: [String]?
    var labelEffectOverrides: [String: Int]?
    var reverseLabels: [String]?
    var eyeModeLabels: [String]?
    var maskOutlineLabels: [String]?
    var reversePreRenderEnabled: Bool?
    var reverseLabelMissFullscreenEnabled: Bool?
    var accessibilityEmptyReverseFullscreenEnabled: Bool?
    var profileLabelStates: [String: PresetManifestLabelState]?
}

extension PrivacySettingsManager {

    /// 导入一个 `.svpreset.zip`（Android 原版预设导出格式）：
    /// zip 内含 `manifest.json` + `stickers/` 文件夹。
    /// manifest 结构：`{"packageType": "safe_vision_privacy_preset",
    /// "packageVersion": 1, "order": [名字...], "data": {名字: 预设内容}}`。
    /// 按 `order` 的顺序导入全部预设（同名覆盖；名为内置预设名
    /// "默认" 的跳过），贴纸解包到
    /// `ImportedStickers/<预设名>/<文件名>` 并改写引用。
    /// 导入成功后自动应用第一个导入的预设（否则用户导入后看不到
    /// 效果、会以为没导进去）。
    /// 贴纸文件按内容解码（不看扩展名，WebP 也可以）。
    public func importPresetPackage(zipData: Data) -> PresetImportResult {
        guard let archive = ZipArchive(data: zipData) else {
            return PresetImportResult(error: NSLocalizedString(
                "preset.import.invalidZip", comment: "无效的预设包"))
        }
        guard let manifestData = archive.data(forEntryNamed: "manifest.json") else {
            return PresetImportResult(error: NSLocalizedString(
                "preset.import.noManifest", comment: "预设包里没有 manifest.json"))
        }
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(PresetPackageManifest.self, from: manifestData) else {
            return PresetImportResult(error: NSLocalizedString(
                "preset.import.invalidManifest", comment: "manifest.json 解析失败"))
        }
        guard manifest.packageType == "safe_vision_privacy_preset" else {
            return PresetImportResult(error: NSLocalizedString(
                "preset.import.wrongType", comment: "不是 Safe Vision 预设包"))
        }
        let names = manifest.order ?? Array((manifest.data ?? [:]).keys)
        var result = PresetImportResult()
        for name in names {
            guard let presetData = manifest.data?[name] else {
                result.skipped.append(name)
                continue
            }
            if name == PrivacyPreset.builtInName {
                result.skipped.append(name)
                continue
            }
            // blurMode 不在 0...5 时整个预设无效（与 Android
            // `parsePreset` 一致），计入 skipped，不解包贴纸。
            if let blurMode = presetData.blurMode, !(0...5).contains(blurMode) {
                result.skipped.append(name)
                continue
            }
            // 解包贴纸并改写 internal: 引用。
            let resolved = resolveStickerURIs(in: presetData, presetName: name, archive: archive)
            let preset = PrivacyPreset(fromManifest: resolved, name: name)
            if let index = presets.firstIndex(where: { $0.name == name && !$0.isBuiltIn }) {
                presets[index] = preset
            } else {
                presets.append(preset)
            }
            result.imported.append(name)
        }
        // 导入成功后自动应用第一个导入的预设：否则设置页的值还是旧的，
        // 用户会以为没导进去。
        if let firstName = result.imported.first,
           let preset = presets.first(where: { $0.name == firstName && !$0.isBuiltIn }) {
            applyPreset(preset)
        }
        return result
    }

    /// 把 manifest 里的 `internal:stickers/...` 引用解包成文件，
    /// 存到 `ImportedStickers/<预设名>/<文件名>`，并改写为相对路径。
    /// 贴纸解包失败时清除该引用（调用方回退为默认贴纸/马赛克）。
    /// 贴纸按原样保存（不按扩展名判断格式，WebP 也可以），
    /// 解码失败时渲染层回退为马赛克。
    private func resolveStickerURIs(
        in manifest: PresetManifestData, presetName: String, archive: ZipArchive
    ) -> PresetManifestData {
        var resolved = manifest
        var cache: [String: String] = [:] // zip 条目名 -> 相对路径
        func resolve(_ uri: String?) -> String? {
            // 空或字面量 "null" 都按无贴纸处理（与 Android parsePreset 一致）。
            guard let uri = uri, !uri.isEmpty, uri != "null" else { return nil }
            guard uri.hasPrefix("internal:") else { return uri }
            let entryName = String(uri.dropFirst("internal:".count))
            if let cached = cache[entryName] { return cached }
            guard let data = archive.data(forEntryNamed: entryName),
                  !data.isEmpty else { return nil }
            let fileName = (entryName as NSString).lastPathComponent
            guard let relativePath = StickerLoader.saveImportedSticker(
                presetName: presetName, fileName: fileName, data: data) else {
                return nil
            }
            cache[entryName] = relativePath
            return relativePath
        }
        resolved.stickerUri = resolve(manifest.stickerUri)
        resolved.animeStickerUri = resolve(manifest.animeStickerUri)
        if var stickers = manifest.labelStickerUris {
            for (label, uri) in stickers {
                if let resolvedURI = resolve(uri) {
                    stickers[label] = resolvedURI
                } else {
                    stickers.removeValue(forKey: label)
                }
            }
            resolved.labelStickerUris = stickers
        }
        if var states = manifest.profileLabelStates {
            for key in states.keys {
                if var state = states[key] {
                    if var stickers = state.labelStickerUris {
                        for (label, uri) in stickers {
                            if let resolvedURI = resolve(uri) {
                                stickers[label] = resolvedURI
                            } else {
                                stickers.removeValue(forKey: label)
                            }
                        }
                        state.labelStickerUris = stickers
                    }
                    states[key] = state
                }
            }
            resolved.profileLabelStates = states
        }
        return resolved
    }
}

extension PrivacyPreset {

    /// 从 manifest 内容构建预设。支持两种格式（与 Android
    /// `PrivacySettingsManager.parsePreset` 一致）：
    /// - 分档格式（`profileLabelStates`）：标准 + 动漫两套，按标签名
    ///   合并（两模型标签名不重叠）；分档里空的贴纸引用从顶层
    ///   `labelStickerUris` 补。
    /// - 平铺格式：顶层字段直接用；`eyeModeLabels` 非空时 EYE_REGION
    ///   加入 blockedLabels（Android 旧版行为）。
    /// mode 5（眼睛模式）无 iOS 对应效果，回退为默认效果（不写覆盖）。
    /// 注意：平铺格式的 `blockedLabels` 只列出要打码的标签；未列出的
    /// 标签在 iOS 里默认也是打码（`labelEnabled` 缺省为 true），
    /// 这里不写 false——例如 ZISUE 只列了动漫标签，标准标签仍保持
    /// 默认打码，避免预设在标准模型下完全不打码。
    fileprivate init(fromManifest manifest: PresetManifestData, name: String) {
        let defaultEffect = MaskEffect.fromAndroidBlurMode(manifest.blurMode ?? 0) ?? .mosaic
        let animeDefaultEffect = manifest.animeBlurMode.flatMap { MaskEffect.fromAndroidBlurMode($0) }
        // 数值字段钳制到 Android 的合法范围（与 `parsePreset` 的 coerceIn 一致）。
        let mosaicBlockSize = min(60, max(12, manifest.mosaicBlockSize ?? 20))
        let gaussianRadius = min(50, max(6, manifest.gaussianRadius ?? 12))
        let maskScale = min(3.0, max(0.1, manifest.maskScale ?? 1.0))
        var labelEffects: [String: String] = [:]
        var labelEnabled: [String: Bool] = [:]
        var labelScales: [String: Double] = [:]
        var labelStickerUris: [String: String] = [:]
        var reverseLabels: [String] = []
        var maskOutlineLabels: [String] = []
        if let states = manifest.profileLabelStates, !states.isEmpty {
            for profileKey in ["standard", "anime"] {
                guard let state = states[profileKey] else { continue }
                applyManifestLabelState(
                    state, labelEffects: &labelEffects, labelEnabled: &labelEnabled,
                    labelScales: &labelScales, labelStickerUris: &labelStickerUris,
                    reverseLabels: &reverseLabels, maskOutlineLabels: &maskOutlineLabels)
            }
            if let topLevel = manifest.labelStickerUris {
                for (label, uri) in topLevel where labelStickerUris[label] == nil {
                    labelStickerUris[label] = uri
                }
            }
        } else {
            let state = PresetManifestLabelState(
                blockedLabels: manifest.blockedLabels,
                labelStickerUris: manifest.labelStickerUris,
                labelMaskScales: manifest.labelMaskScales,
                labelEffectOverrides: manifest.labelEffectOverrides,
                reverseLabels: manifest.reverseLabels,
                maskOutlineLabels: manifest.maskOutlineLabels)
            applyManifestLabelState(
                state, labelEffects: &labelEffects, labelEnabled: &labelEnabled,
                labelScales: &labelScales, labelStickerUris: &labelStickerUris,
                reverseLabels: &reverseLabels, maskOutlineLabels: &maskOutlineLabels)
            if let eyeLabels = manifest.eyeModeLabels, !eyeLabels.isEmpty {
                labelEnabled[DetectionConfig.eyeRegionLabel] = true
            }
        }
        self.init(
            id: UUID(),
            name: name,
            labelEffects: labelEffects,
            labelEnabled: labelEnabled,
            labelScales: labelScales,
            defaultEffect: defaultEffect.rawValue,
            isBuiltIn: false,
            animeDefaultEffect: animeDefaultEffect?.rawValue,
            circularMaskEnabled: manifest.circularMaskEnabled ?? false,
            maskOutlineEnabled: manifest.maskOutlineEnabled ?? false,
            mosaicBlockSize: mosaicBlockSize,
            gaussianRadius: gaussianRadius,
            maskScale: maskScale,
            animeMaskScale: manifest.animeMaskScale,
            stickerUri: manifest.stickerUri,
            animeStickerUri: manifest.animeStickerUri,
            labelStickerUris: labelStickerUris,
            reverseLabels: reverseLabels,
            maskOutlineLabels: maskOutlineLabels,
            reversePreRenderEnabled: manifest.reversePreRenderEnabled ?? true,
            reverseLabelMissFullscreenEnabled: manifest.reverseLabelMissFullscreenEnabled ?? false,
            accessibilityEmptyReverseFullscreenEnabled: manifest.accessibilityEmptyReverseFullscreenEnabled ?? false
        )
    }
}

/// 把一个 `PresetManifestLabelState`（一档）合并进平表。
/// `blockedLabels` 只列出要打码的标签（写 true）；未列出的标签
/// 不写（iOS 缺省为打码）。`labelEffectOverrides` 里 mode 5（眼睛模式）
/// 无 iOS 对应效果，不写覆盖（回退为默认效果）。
private func applyManifestLabelState(
    _ state: PresetManifestLabelState,
    labelEffects: inout [String: String],
    labelEnabled: inout [String: Bool],
    labelScales: inout [String: Double],
    labelStickerUris: inout [String: String],
    reverseLabels: inout [String],
    maskOutlineLabels: inout [String]
) {
    if let blocked = state.blockedLabels {
        for label in blocked { labelEnabled[label] = true }
    }
    if let overrides = state.labelEffectOverrides {
        for (label, mode) in overrides {
            if let effect = MaskEffect.fromAndroidBlurMode(mode) {
                labelEffects[label] = effect.rawValue
            }
        }
    }
    if let scales = state.labelMaskScales {
        for (label, scale) in scales { labelScales[label] = scale }
    }
    if let stickers = state.labelStickerUris {
        for (label, uri) in stickers { labelStickerUris[label] = uri }
    }
    if let reverse = state.reverseLabels {
        for label in reverse where !reverseLabels.contains(label) {
            reverseLabels.append(label)
        }
    }
    if let outlines = state.maskOutlineLabels {
        for label in outlines where !maskOutlineLabels.contains(label) {
            maskOutlineLabels.append(label)
        }
    }
}

// MARK: - ZIP 读取（.svpreset 包）

/// 最小 ZIP 读取器：解析中央目录（EOCD），支持 stored（method 0）
/// 与 deflate（method 8）两种压缩方式。只读 `manifest.json` 与
/// `stickers/` 下的文件。拒绝 `..` 路径；单文件与总大小有上限。
/// （Foundation 没有内置 ZIP API，因此这里手写最小实现。）
private struct ZipArchive {
    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    /// 单个解压后文件的大小上限（32 MB）。
    private static let maxEntrySize = 32 * 1024 * 1024

    init?(data: Data) {
        // 找 EOCD（从文件尾向前搜，最多 64KB 注释区）。
        let eocdSignature: UInt32 = 0x06054b50
        let minEOCDSize = 22
        guard data.count >= minEOCDSize else { return nil }
        var eocdOffset: Int? = nil
        let searchStart = max(0, data.count - minEOCDSize - 65535)
        var i = data.count - minEOCDSize
        while i >= searchStart {
            if ZipArchive.readUInt32(data, at: i) == eocdSignature {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { return nil }
        // 中央目录的条目数与偏移。
        guard let totalEntries = ZipArchive.readUInt16(data, at: eocd + 10),
              let cdOffset = ZipArchive.readUInt32(data, at: eocd + 16) else { return nil }
        var offset = Int(cdOffset)
        var parsed: [String: Entry] = [:]
        for _ in 0 ..< Int(totalEntries) {
            guard ZipArchive.readUInt32(data, at: offset) == 0x02014b50,
                  let method = ZipArchive.readUInt16(data, at: offset + 10),
                  let compressedSize = ZipArchive.readUInt32(data, at: offset + 20),
                  let uncompressedSize = ZipArchive.readUInt32(data, at: offset + 24),
                  let nameLength = ZipArchive.readUInt16(data, at: offset + 28),
                  let extraLength = ZipArchive.readUInt16(data, at: offset + 30),
                  let commentLength = ZipArchive.readUInt16(data, at: offset + 32),
                  let localHeaderOffset = ZipArchive.readUInt32(data, at: offset + 42) else { return nil }
            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else { return nil }
            // 拒绝逃逸路径。
            if name.contains("..") || name.hasPrefix("/") { return nil }
            parsed[name] = Entry(
                name: name,
                method: method,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset))
            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }
        self.data = data
        self.entries = parsed
    }

    /// 按名取一个条目的解压后内容；不存在 / 不支持的压缩方式 / 超限返回 nil。
    func data(forEntryNamed name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        guard entry.uncompressedSize <= Self.maxEntrySize else { return nil }
        // 读本地文件头，定位压缩数据。
        let localOffset = entry.localHeaderOffset
        guard ZipArchive.readUInt32(data, at: localOffset) == 0x04034b50,
              let nameLength = ZipArchive.readUInt16(data, at: localOffset + 26),
              let extraLength = ZipArchive.readUInt16(data, at: localOffset + 28) else { return nil }
        let dataStart = localOffset + 30 + Int(nameLength) + Int(extraLength)
        let dataEnd = dataStart + entry.compressedSize
        guard dataStart <= data.count, dataEnd <= data.count else { return nil }
        let compressed = data[dataStart..<dataEnd]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            return ZipArchive.inflateRawDeflate(Data(compressed), expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    // MARK: - 小端整数读取

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - deflate 解压

    /// 解压 raw deflate 数据。ZIP 的 method 8 是裸 deflate 流（无 zlib
    /// 头、无 Adler32），`Compression` 框架只提供 zlib 流接口——之前用
    /// “补 zlib 头 + 假 Adler32” 的 trick 赌解码器报错时输出还在，实测
    /// 会丢掉全部输出（manifest.json 解不出来就报“预设包里没有
    /// manifest.json”）。现在改走系统 libz（`ZipInflate.c`，
    /// `inflateInit2(&strm, -15)`），真正的 raw-deflate 解压。
    private static func inflateRawDeflate(_ raw: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        guard expectedSize > 0, !raw.isEmpty else { return nil }
        var outLength = 0
        return raw.withUnsafeBytes { inputBuffer -> Data? in
            guard let base = inputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let outPtr = SVZipInflateRawDeflate(base, raw.count, expectedSize, &outLength) else {
                return nil
            }
            defer { free(outPtr) }
            guard outLength == expectedSize else { return nil }
            return Data(bytes: outPtr, count: outLength)
        }
    }
}
