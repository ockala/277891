import CoreGraphics
import Foundation

/// A single YOLO detection, in original-image pixel coordinates.
public struct Detection: Identifiable, Equatable {
    public let id = UUID()
    public let label: String
    public let score: Float
    public let box: CGRect // 原图像素坐标
}

/// Which YOLO model produced the detections. There is no "mixed" profile on
/// iOS: one engine instance loads exactly one model at a time.
public enum LabelProfile: String, CaseIterable, Codable {
    case standard, anime
    public var displayName: String { self == .standard ? "标准模型" : "动漫模型" }
}
