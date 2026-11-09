import Photos
import SwiftUI

/// 本地化字符串读取（传统 .strings 文件，见 Resources/*.lproj/Localizable.strings）。
func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 请求相册“仅添加”写入权限（MediaSaveHelper 不处理授权，调用方须先取得）。
/// 已授权/受限时直接回调 true；否则弹出系统授权框后回调结果。
func requestPhotoLibraryAddAccess(completion: @escaping (Bool) -> Void) {
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if status == .authorized || status == .limited {
        completion(true)
        return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
        completion(newStatus == .authorized || newStatus == .limited)
    }
}

/// 返回 LocalizedStringKey 的本地化字符串，用于 SwiftUI 视图构造器
///（navigationTitle / alert / Section / Picker 等只接受 LocalizedStringKey 的位置）。
func localizedKey(_ key: String) -> LocalizedStringKey {
    LocalizedStringKey(key)
}

/// 带格式化参数的本地化字符串。
func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: .current, arguments: args)
}

@main
struct SafeVisionApp: App {
    @StateObject private var privacySettings = PrivacySettingsManager.shared
    @StateObject private var appSettings = AppSettingsManager.shared

    private var preferredColorScheme: ColorScheme? {
        switch appSettings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(privacySettings)
                .environmentObject(appSettings)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
