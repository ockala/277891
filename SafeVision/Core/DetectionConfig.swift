import Foundation

/// Detection labels, thresholds and display names.
///
/// Direct port of Android `DetectionConfig.kt` (2026-11-09). The model-output
/// label orders below must not be reordered: they are the class-id order the
/// models were trained/exported with. `displayOrder(for:)` is the separate
/// UI order; do not use it to interpret model output.
public enum DetectionConfig {

    public static let eyeRegionLabel = "EYE_REGION"

    public static let scoreThreshold: Float = 0.2
    public static let nmsThreshold: Float = 0.45
    public static let endToEndDuplicateIoUThreshold: Float = 0.9

    /// Standard model output labels, in fixed model-output order.
    public static let standardOutputLabels: [String] = [
        "FEMALE_GENITALIA_COVERED",
        "FACE_FEMALE",
        "BUTTOCKS_EXPOSED",
        "FEMALE_BREAST_EXPOSED",
        "FEMALE_GENITALIA_EXPOSED",
        "MALE_BREAST_EXPOSED",
        "ANUS_EXPOSED",
        "FEET_EXPOSED",
        "BELLY_COVERED",
        "FEET_COVERED",
        "ARMPITS_COVERED",
        "ARMPITS_EXPOSED",
        "FACE_MALE",
        "BELLY_EXPOSED",
        "MALE_GENITALIA_EXPOSED",
        "ANUS_COVERED",
        "FEMALE_BREAST_COVERED",
        "BUTTOCKS_COVERED"
    ]

    /// Anime model output labels, in fixed model-output order.
    public static let animeOutputLabels: [String] = [
        "Animal",
        "Anus",
        "Ass",
        "Balls",
        "Boob",
        "Dick",
        "Face",
        "Feet",
        "Nipple",
        "Pussy"
    ]

    /// Standard labels ordered for UI display: body parts top-to-bottom,
    /// female group first, then shared parts, then male group; exposed
    /// variants before covered ones.
    public static let standardDisplayOrder: [String] = [
        "FACE_FEMALE",
        "FEMALE_BREAST_EXPOSED",
        "FEMALE_BREAST_COVERED",
        "FEMALE_GENITALIA_EXPOSED",
        "FEMALE_GENITALIA_COVERED",
        "ARMPITS_EXPOSED",
        "ARMPITS_COVERED",
        "BELLY_EXPOSED",
        "BELLY_COVERED",
        "BUTTOCKS_EXPOSED",
        "BUTTOCKS_COVERED",
        "ANUS_EXPOSED",
        "ANUS_COVERED",
        "FEET_EXPOSED",
        "FEET_COVERED",
        "FACE_MALE",
        "MALE_BREAST_EXPOSED",
        "MALE_GENITALIA_EXPOSED"
    ]

    /// Anime labels ordered for UI display: body parts top-to-bottom;
    /// Animal is not a body part and stays last.
    public static let animeDisplayOrder: [String] = [
        "Face",
        "Boob",
        "Nipple",
        "Pussy",
        "Dick",
        "Balls",
        "Ass",
        "Anus",
        "Feet",
        "Animal"
    ]

    /// All supported labels (display order: eyes first, then standard labels
    /// top-to-bottom, then anime labels top-to-bottom).
    public static let allLabels: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for label in [eyeRegionLabel] + standardDisplayOrder + animeDisplayOrder {
            if seen.insert(label).inserted { result.append(label) }
        }
        return result
    }()

    /// 曾用于强制锁定部分标签（不可关闭）。已按用户要求取消锁定：
    /// 所有标签都可自由开关，默认仍为开启（打码）。
    /// 保留该注释以说明锁定机制已被整体移除。
    public static let lockedLabels: [String] = []

    public static let displayNames: [String: String] = [
        "FEMALE_GENITALIA_COVERED": "女性私处（遮挡）",
        "FACE_FEMALE": "女性面部",
        "BUTTOCKS_EXPOSED": "臀部（暴露）",
        "FEMALE_BREAST_EXPOSED": "女性胸部（暴露）",
        "FEMALE_GENITALIA_EXPOSED": "女性私处（暴露）",
        "MALE_BREAST_EXPOSED": "男性胸部（暴露）",
        "ANUS_EXPOSED": "肛门（暴露）",
        "FEET_EXPOSED": "脚部（暴露）",
        "BELLY_COVERED": "腹部（遮挡）",
        "FEET_COVERED": "脚部（遮挡）",
        "ARMPITS_COVERED": "腋下（遮挡）",
        "ARMPITS_EXPOSED": "腋下（暴露）",
        "FACE_MALE": "男性面部",
        "BELLY_EXPOSED": "腹部（暴露）",
        "MALE_GENITALIA_EXPOSED": "男性私处（暴露）",
        "ANUS_COVERED": "肛门（遮挡）",
        "FEMALE_BREAST_COVERED": "女性胸部（遮挡）",
        "BUTTOCKS_COVERED": "臀部（遮挡）",
        "Animal": "动物",
        "Anus": "肛门",
        "Ass": "臀部",
        "Balls": "睾丸",
        "Boob": "胸部",
        "Dick": "阴茎",
        "Face": "面部",
        "Feet": "脚部",
        "Nipple": "乳头",
        "Pussy": "阴部",
        "EYE_REGION": "眼睛"
    ]

    public static let standardFaceLabels: Set<String> = ["FACE_FEMALE", "FACE_MALE"]
    public static let animeFaceLabels: Set<String> = ["Face"]
    public static let faceLabels: Set<String> = standardFaceLabels.union(animeFaceLabels)

    // MARK: - Lookups

    /// Model-output labels for a profile, in class-id order. Use this (never
    /// the display order) to interpret model output.
    public static func outputLabels(for profile: LabelProfile) -> [String] {
        switch profile {
        case .standard: return standardOutputLabels
        case .anime: return animeOutputLabels
        }
    }

    /// Labels for a profile in UI display order, with EYE_REGION inserted
    /// before the first face label (mirrors Android `getLabels`).
    public static func labels(for profile: LabelProfile) -> [String] {
        switch profile {
        case .standard: return insertingEyeRegion(into: standardDisplayOrder)
        case .anime: return insertingEyeRegion(into: animeDisplayOrder)
        }
    }

    private static func insertingEyeRegion(into labels: [String]) -> [String] {
        if let index = labels.firstIndex(where: { faceLabels.contains($0) }) {
            var result = labels
            result.insert(eyeRegionLabel, at: index)
            return result
        }
        return labels + [eyeRegionLabel]
    }

    public static func displayName(for label: String) -> String {
        return displayNames[label] ?? label
    }

    /// 锁定标签已取消（见 `lockedLabels`）：所有标签均可自由开关，
    /// 该函数保留为空实现以便旧调用处无需改动。
    public static func lockedLabels(for profile: LabelProfile) -> [String] {
        return []
    }

    public static func isEyeRegionLabel(_ label: String) -> Bool {
        return label == eyeRegionLabel
    }

    /// Whether a face detection with this label can derive an EYE_REGION
    /// detection (any FACE_FEMALE / FACE_MALE / Face label).
    public static func canDeriveEyeRegion(_ label: String) -> Bool {
        return faceLabels.contains(label)
    }
}
