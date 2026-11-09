import Photos
import UIKit

/// 处理结果媒体保存：相册（Photos）与 App 内输出目录。
///
/// 相册保存只做保存逻辑，不处理授权——调用方须先取得相册写入权限
///（`PHPhotoLibrary.requestAuthorization(for: .addOnly)`）。
/// App 内输出目录为 `Documents/SafeVision/`，不存在时自动创建。
public enum MediaSaveHelper {

    private static let folderName = "SafeVision"
    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "mp4", "mov", "m4v"
    ]

    /// App 内输出目录（`Documents/SafeVision/`），不存在就创建。
    /// 目录创建失败时仍返回该 URL（后续写操作会返回失败）。
    public static var outputDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        let directory = documents.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: - 保存到相册

    /// 保存图片到相册。`completion` 在任意队列回调。
    public static func saveImageToPhotos(
        _ image: UIImage,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }, completionHandler: completion)
    }

    /// 保存视频到相册。`completion` 在任意队列回调。
    public static func saveVideoToPhotos(
        _ url: URL,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }, completionHandler: completion)
    }

    // MARK: - 保存到 App 内输出目录

    /// 保存图片到 `Documents/SafeVision/`（JPEG，质量 0.92；JPEG 编码
    /// 失败时改存 PNG）。`fileName` 无扩展名时补 `.jpg`；同名文件
    /// 已存在时自动加 `-1`、`-2`… 后缀，不覆盖旧文件。
    /// 成功返回实际保存路径，失败返回 `nil`。
    public static func saveImageToAppFolder(_ image: UIImage, fileName: String) -> URL? {
        let name = fileNameWithExtension(fileName, defaultExtension: "jpg")
        let url = uniqueURL(in: outputDirectory, fileName: name)
        let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData()
        guard let data else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 复制视频文件到 `Documents/SafeVision/`。同名文件已存在时自动
    /// 加 `-1`、`-2`… 后缀，不覆盖旧文件。成功返回实际保存路径，
    /// 失败返回 `nil`。
    public static func saveVideoToAppFolder(_ url: URL, fileName: String) -> URL? {
        let name = fileNameWithExtension(fileName, defaultExtension: "mp4")
        let destination = uniqueURL(in: outputDirectory, fileName: name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// 输出目录里的图片 + 视频，按修改时间倒序（最新的在前）。
    /// 目录不存在或读取失败时返回空数组。
    public static func listSavedMedia() -> [URL] {
        let directory = outputDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                modificationDate(of: lhs) > modificationDate(of: rhs)
            }
    }

    /// 删除输出目录里的一个文件。失败时静默忽略。
    public static func deleteSavedMedia(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 内部工具

    private static func modificationDate(of url: URL) -> Date {
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap { $0.contentModificationDate } ?? .distantPast
    }

    private static func fileNameWithExtension(_ fileName: String, defaultExtension: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed as NSString).pathExtension.isEmpty {
            return "\(trimmed).\(defaultExtension)"
        }
        return trimmed
    }

    /// 目录内不重名的目标路径：已存在时在扩展名前加 `-1`、`-2`…。
    private static func uniqueURL(in directory: URL, fileName: String) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
