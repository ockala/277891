import Combine
import Foundation

/// App 主题。
public enum AppTheme: String, CaseIterable, Codable {
    case system
    case light
    case dark
}

/// App 语言。`system` 为跟随系统。
public enum AppLanguage: String, CaseIterable, Codable {
    case system
    case zhHans
    case zhHant
    case en
    case ko

    /// 对应的 `AppleLanguages` 代码；`system` 返回 `nil`
    /// （表示移除该键、跟随系统语言）。
    public var appleLanguageCode: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ko: return "ko"
        }
    }
}

/// 通用 App 设置（UserDefaults 持久化，ObservableObject）。
/// 对应 Android `AppSettingsManager` 的模型变体 / 主题 / 语言 /
///
/// 视频检测步长。语言切换通过 `applyLanguage()` 写 `AppleLanguages`，
/// iOS 在启动时读取该键，因此改语言后需重启 App 才生效。
public final class AppSettingsManager: ObservableObject {

    public static let shared = AppSettingsManager()

    public static let videoDetectStrideRange = 1...30

    private enum Keys {
        static let modelProfile = "com.safevision.app.modelProfile"
        static let theme = "com.safevision.app.theme"
        static let language = "com.safevision.app.language"
        static let videoDetectStride = "com.safevision.app.videoDetectStride"
    }

    /// 检测模型：标准模型 / 动漫模型（`LabelProfile` 定义在
    /// `Core/Detection.swift`）。
    @Published public var modelProfile: LabelProfile {
        didSet {
            UserDefaults.standard.set(modelProfile.rawValue, forKey: Keys.modelProfile)
        }
    }

    @Published public var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
        }
    }

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            applyLanguage()
        }
    }

    /// 视频每 N 帧检测一次，默认 5，范围 1...30。
    @Published public var videoDetectStride: Int {
        didSet {
            let clamped = min(
                Self.videoDetectStrideRange.upperBound,
                max(Self.videoDetectStrideRange.lowerBound, videoDetectStride)
            )
            if clamped != videoDetectStride {
                videoDetectStride = clamped
                return
            }
            UserDefaults.standard.set(videoDetectStride, forKey: Keys.videoDetectStride)
        }
    }

    public init() {
        let defaults = UserDefaults.standard

        if let rawValue = defaults.string(forKey: Keys.modelProfile),
           let profile = LabelProfile(rawValue: rawValue) {
            self.modelProfile = profile
        } else {
            self.modelProfile = .standard
        }

        if let rawValue = defaults.string(forKey: Keys.theme),
           let theme = AppTheme(rawValue: rawValue) {
            self.theme = theme
        } else {
            self.theme = .system
        }

        if let rawValue = defaults.string(forKey: Keys.language),
           let language = AppLanguage(rawValue: rawValue) {
            self.language = language
        } else {
            self.language = .system
        }

        let storedStride = defaults.object(forKey: Keys.videoDetectStride) as? Int
        self.videoDetectStride = min(
            Self.videoDetectStrideRange.upperBound,
            max(Self.videoDetectStrideRange.lowerBound, storedStride ?? 5)
        )
    }

    /// 把当前语言写入 `AppleLanguages`（跟随系统时移除该键）。
    /// iOS 只在 App 启动时读取 `AppleLanguages`，所以改语言后
    /// 需要重启 App 才生效；调用方应在设置页提示用户重启。
    public func applyLanguage() {
        let defaults = UserDefaults.standard
        if let code = language.appleLanguageCode {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}
