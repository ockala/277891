import Combine
import CoreGraphics
import Foundation

/// 一组隐私设置快照（预设）。`labelEffects` 存 `MaskEffect.rawValue`，
/// 缺失的标签在应用时回退到预设的 `defaultEffect`。
public struct PrivacyPreset: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var labelEffects: [String: String] // label -> MaskEffect.rawValue
    public var labelEnabled: [String: Bool]
    public var labelScales: [String: Double]
    public var defaultEffect: String
    public var isBuiltIn: Bool

    /// 内置默认预设的固定 ID（跨启动稳定，持久化后仍能认出它）。
    public static let builtInID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let builtInName = "默认"

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
/// 锁定标签（FEMALE_GENITALIA_EXPOSED、FEMALE_BREAST_EXPOSED、Boob、
/// Pussy）永远启用：写入 `false` 会被自动纠回 `true`。
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
    }

    @Published public var labelEffects: [String: MaskEffect] {
        didSet { persistLabelEffects() }
    }

    @Published public var labelEnabled: [String: Bool] {
        didSet {
            // 锁定标签永远启用：被关掉时纠回 true（第二次 didSet 时
            // 已无改动，不会递归）。
            var fixed = labelEnabled
            for label in DetectionConfig.lockedLabels { fixed[label] = true }
            if fixed != labelEnabled {
                labelEnabled = fixed
                return
            }
            persistLabelEnabled()
        }
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
        for label in DetectionConfig.lockedLabels { enabled[label] = true }
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

    /// 标签是否启用遮挡；锁定标签永远返回 `true`。
    public func isEnabled(_ label: String) -> Bool {
        if DetectionConfig.lockedLabels.contains(label) { return true }
        return labelEnabled[label] ?? true
    }

    /// 标签的遮罩缩放倍数（0.1...3，未设置时 1.0）。
    public func scale(for label: String) -> CGFloat {
        let raw = labelScales[label] ?? 1.0
        return min(Self.maskScaleRange.upperBound, max(Self.maskScaleRange.lowerBound, raw))
    }

    /// 把检测结果转成待渲染的打码框：只保留启用的标签，
    /// 锁定标签永远启用。
    public func maskedBoxes(for detections: [Detection]) -> [MaskedBox] {
        return detections
            .filter { isEnabled($0.label) }
            .map { MaskedBox(box: $0.box, effect: effect(for: $0.label), scale: scale(for: $0.label)) }
    }

    // MARK: - 预设

    /// 把当前设置存为新预设并设为活动预设。同名用户预设会被覆盖；
    /// 内置预设（"默认"）不许覆盖，调用会被忽略。
    public func savePreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if presets.contains(where: { $0.name == trimmed && $0.isBuiltIn }) { return }
        let preset = PrivacyPreset(
            id: UUID(),
            name: trimmed,
            labelEffects: labelEffects.mapValues { $0.rawValue },
            labelEnabled: labelEnabled,
            labelScales: labelScales.mapValues { Double($0) },
            defaultEffect: defaultEffect.rawValue,
            isBuiltIn: false
        )
        if let index = presets.firstIndex(where: { $0.name == trimmed && !$0.isBuiltIn }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        activePresetID = preset.id
    }

    /// 应用预设：恢复其中保存的默认效果、各标签效果 / 开关 / 缩放，
    /// 并把它设为活动预设。预设里缺失的标签回退到预设的默认效果。
    public func applyPreset(_ preset: PrivacyPreset) {
        defaultEffect = MaskEffect(rawValue: preset.defaultEffect) ?? .mosaic
        labelEffects = preset.labelEffects.compactMapValues { MaskEffect(rawValue: $0) }
        labelEnabled = preset.labelEnabled
        labelScales = preset.labelScales.mapValues { CGFloat($0) }
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

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Keys.presets)
        }
    }
}
