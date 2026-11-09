import UIKit

/// 贴纸图加载（带内存缓存）。
///
/// 贴纸文件 `Default-stickers.png` 由主包放在 Bundle 的 Resources 里
/// （从 Android assets 复制而来）。文件缺失时返回 `nil`，不崩溃；
/// 调用方（`MaskRenderer`）会在贴纸缺失时回退为马赛克。
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
}
