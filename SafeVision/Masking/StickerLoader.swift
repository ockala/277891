import ImageIO
import UIKit

/// 贴纸图加载（带内存缓存）。
///
/// 贴纸文件 `Default-stickers.png` 由主包放在 Bundle 的 Resources 里
/// （从 Android assets 复制而来）。文件缺失时返回 `nil`，不崩溃；
/// 调用方（`MaskRenderer`）会在贴纸缺失时回退为马赛克。
///
/// 导入的贴纸（`.svpreset.zip` 里的 `stickers/`，以及用户自选的
/// 自定义贴纸）存在 Application Support 下，按相对路径引用：
/// - 导入预设的贴纸：`ImportedStickers/<预设名>/<文件名>`
/// - 用户自选的贴纸：`CustomStickers/<uuid>_<文件名>`
/// 贴纸按文件内容解码（不看扩展名）：`.svpreset` 包里有名为 `.png`
/// 实际是 WebP 的文件（RIFF/WEBP），`UIImage(data:)` / ImageIO
/// 按内容识别，iOS 14+ 可解 WebP。
public enum StickerLoader {

    private static let cache = NSCache<NSString, UIImage>()
    private static let defaultStickerName = "Default-stickers"

    /// 默认贴纸图。文件缺失时返回 `nil`。
    public static func defaultSticker() -> UIImage? {
        return stickerImage(named: defaultStickerName)
    }

    /// 按名加载贴纸图。`named` 可带或不带扩展名（例如
    /// `"Default-stickers"` 或 `"Default-stickers.png"`）；先查
    /// Asset Catalog（`UIImage(named:)`），再按 Bundle 文件查。
    /// 文件缺失时返回 `nil`。
    public static func stickerImage(named name: String) -> UIImage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var image: UIImage? = UIImage(named: trimmed)
        if image == nil {
            let base = (trimmed as NSString).deletingPathExtension
            let ext = (trimmed as NSString).pathExtension
            let extensions = ext.isEmpty ? ["png"] : [ext]
            for candidateExt in extensions {
                if let url = Bundle.main.url(forResource: base, withExtension: candidateExt) {
                    image = UIImage(contentsOfFile: url.path)
                    break
                }
            }
        }
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    /// 清空贴纸缓存（例如内存紧张或贴纸文件被替换后）。
    public static func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - 按内容解码

    /// 按文件内容解码图片（不看扩展名）。先试 `UIImage(data:)`，
    /// 再试 ImageIO（iOS 14+ 可解 WebP）。都失败返回 nil。
    public static func decodeImageData(_ data: Data) -> UIImage? {
        if data.isEmpty { return nil }
        if let image = UIImage(data: data) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 快速判断数据是否是一张可解码的图片（不解出全图，只看文件头
    /// 与 ImageIO 能否识别）。
    public static func isDecodableImageData(_ data: Data) -> Bool {
        return decodeImageData(data) != nil
    }

    // MARK: - 导入 / 自选贴纸的存储

    /// Application Support 目录（贴纸的根目录）。
    public static var applicationSupportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// 导入预设的贴纸根目录：`Application Support/ImportedStickers`。
    private static var importedStickersDirectory: URL? {
        guard let base = applicationSupportDirectory else { return nil }
        return base.appendingPathComponent("ImportedStickers", isDirectory: true)
    }

    /// 用户自选贴纸的目录：`Application Support/CustomStickers`。
    private static var customStickersDirectory: URL? {
        guard let base = applicationSupportDirectory else { return nil }
        return base.appendingPathComponent("CustomStickers", isDirectory: true)
    }

    /// 去掉路径分隔符与 `..`，保证文件名/预设名不能逃出贴纸目录。
    public static func sanitizedFileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "sticker" }
        return cleaned
    }

    /// 保存从 `.svpreset.zip` 解包出来的贴纸。返回相对路径
    /// `ImportedStickers/<预设名>/<文件名>`（供预设的 stickerUri /
    /// labelStickerUris 引用）；保存失败返回 nil。
    @discardableResult
    public static func saveImportedSticker(
        presetName: String, fileName: String, data: Data
    ) -> String? {
        guard let directory = importedStickersDirectory else { return nil }
        let presetDirectory = directory.appendingPathComponent(
            sanitizedFileName(presetName), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: presetDirectory, withIntermediateDirectories: true)
            let safeName = sanitizedFileName(fileName)
            let url = presetDirectory.appendingPathComponent(safeName)
            try data.write(to: url, options: .atomic)
            return "ImportedStickers/\(sanitizedFileName(presetName))/\(safeName)"
        } catch {
            return nil
        }
    }

    /// 保存用户自选的自定义贴纸。返回相对路径
    /// `CustomStickers/<uuid>_<文件名>`；保存失败返回 nil。
    @discardableResult
    public static func saveCustomSticker(data: Data, fileName: String) -> String? {
        guard let directory = customStickersDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let safeName = "\(UUID().uuidString)_\(sanitizedFileName(fileName))"
            let url = directory.appendingPathComponent(safeName)
            try data.write(to: url, options: .atomic)
            return "CustomStickers/\(safeName)"
        } catch {
            return nil
        }
    }

    /// 按相对路径（`ImportedStickers/...` 或 `CustomStickers/...`）
    /// 加载贴纸图。按内容解码（见 `decodeImageData`）；文件缺失或
    /// 解码失败返回 nil。
    public static func stickerImage(relativePath: String) -> UIImage? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(".."),
              let base = applicationSupportDirectory else { return nil }
        let key = trimmed as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = base.appendingPathComponent(trimmed)
        guard let data = try? Data(contentsOf: url),
              let image = decodeImageData(data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 解析一个贴纸引用：`nil` / 空表示默认贴纸；`ImportedStickers/...`
    /// 或 `CustomStickers/...` 为相对路径；`internal:stickers/...`
    /// 为 `.svpreset` 包内引用（未导入时无法解析，返回 nil）。
    /// 返回 nil 时调用方应回退为默认贴纸或马赛克。
    public static func stickerImage(forURI uri: String?) -> UIImage? {
        guard let uri = uri?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uri.isEmpty, uri != "null" else {
            return defaultSticker()
        }
        if uri.hasPrefix("ImportedStickers/") || uri.hasPrefix("CustomStickers/") {
            return stickerImage(relativePath: uri)
        }
        if uri.hasPrefix("internal:") {
            // 包内引用只有导入时才有意义，运行时解析不到，返回 nil。
            return nil
        }
        if uri.hasPrefix("file://"), let url = URL(string: uri) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decodeImageData(data)
        }
        return nil
    }
}
