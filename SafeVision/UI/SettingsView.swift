import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 设置页：模型、标签设置、打码参数、贴纸、描边、反向遮挡、预设、视频、外观、语言、关于。
struct SettingsView: View {
    @EnvironmentObject private var privacy: PrivacySettingsManager
    @EnvironmentObject private var appSettings: AppSettingsManager

    @State private var showingPresetNamePrompt = false
    @State private var newPresetName = ""
    @State private var showingResetConfirm = false
    @State private var showingLanguageRestartNote = false
    @State private var presetToDelete: PrivacyPreset?
    @State private var noticeMessage = ""
    @State private var showingPresetImporter = false
    @State private var showingOutlinePicker = false
    @State private var showingReversePicker = false
    @State private var stickerItem: PhotosPickerItem?

    private var labels: [String] {
        DetectionConfig.labels(for: appSettings.modelProfile)
    }

    private var currentPresetName: String {
        privacy.presets.first(where: { $0.id == privacy.activePresetID })?.name
            ?? localized("preset_none")
    }

    /// 当前默认贴纸的文件名（未单独设置时显示内置默认贴纸）。
    private var currentStickerName: String {
        if let uri = privacy.stickerUri {
            return (uri as NSString).lastPathComponent
        }
        return "Default-stickers.png"
    }

    /// 已选反向标签的显示名（未设置时显示提示）。
    private var reverseLabelsSummary: String {
        if privacy.reverseLabels.isEmpty {
            return localized("label_reverse_none")
        }
        return privacy.reverseLabels
            .map { DetectionConfig.displayName(for: $0) }
            .joined(separator: "、")
    }

    // MARK: - Body 拆分
    // body 曾因单个表达式过大导致类型检查超时；每个 Section
    // 拆成独立的计算属性，body 只做组合。
    private var modelSection: some View {
        // MARK: - 模型
        Section(localizedKey("label_model")) {
            Picker(localizedKey("label_model"),
                   selection: $appSettings.modelProfile) {
                ForEach(LabelProfile.allCases, id: \.self) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var labelsSection: some View {
        // MARK: - 标签设置
        Section(localizedKey("label_labels")) {
            ForEach(labels, id: \.self) { label in
                LabelSettingsRow(label: label)
            }
        }
    }

    private var maskParamsSection: some View {
        // MARK: - 打码参数
        Section(localizedKey("label_mask_params")) {
            Picker(localizedKey("label_default_effect"),
                   selection: $privacy.defaultEffect) {
                ForEach(MaskEffect.allCases, id: \.self) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            HStack {
                Text(localizedKey("label_mosaic_block_size"))
                Slider(value: Binding(
                    get: { Double(privacy.mosaicBlockSize) },
                    set: { privacy.mosaicBlockSize = Int($0) }
                ), in: 12...60, step: 1)
                Text("\(privacy.mosaicBlockSize)")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            HStack {
                Text(localizedKey("label_gaussian_radius"))
                Slider(value: Binding(
                    get: { Double(privacy.gaussianRadius) },
                    set: { privacy.gaussianRadius = Int($0) }
                ), in: 6...50, step: 1)
                Text("\(privacy.gaussianRadius)")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            HStack {
                Text(localizedKey("label_mask_scale"))
                Slider(value: Binding(
                    get: { Double(privacy.maskScale) },
                    set: { privacy.maskScale = CGFloat($0) }
                ), in: 0.1...3, step: 0.1)
                Text(String(format: "%.1fx", privacy.maskScale))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            Toggle(localizedKey("label_circular_mask"),
                   isOn: $privacy.circularMaskEnabled)
        }
    }

    private var stickerSection: some View {
        // MARK: - 贴纸
        Section(localizedKey("label_sticker")) {
            LabeledContent(localizedKey("label_current_sticker"),
                           value: currentStickerName)
            PhotosPicker(selection: $stickerItem, matching: .images) {
                Label(localizedKey("action_pick_custom_sticker"),
                      systemImage: "photo")
                    .foregroundColor(.red)
            }
            .onChange(of: stickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let relativePath = StickerLoader.saveCustomSticker(
                           data: data, fileName: "sticker.png") {
                        await MainActor.run {
                            privacy.stickerUri = relativePath
                        }
                    }
                }
            }
            Button(localizedKey("action_use_default_sticker")) {
                privacy.stickerUri = nil
            }
            .buttonStyle(.bordered)
        }
    }

    private var outlineSection: some View {
        // MARK: - 遮挡红边
        Section(localizedKey("label_outline")) {
            Toggle(localizedKey("label_outline_enabled"),
                   isOn: $privacy.maskOutlineEnabled)
            Button(localizedKey("action_outline_labels")) {
                showingOutlinePicker = true
            }
            .disabled(!privacy.maskOutlineEnabled)
        }
    }

    private var reverseSection: some View {
        // MARK: - 反向遮挡
        Section(localizedKey("label_reverse")) {
            Button(localizedKey("action_reverse_labels")) {
                showingReversePicker = true
            }
            Text(reverseLabelsSummary)
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle(localizedKey("label_reverse_pre_render"),
                   isOn: $privacy.reversePreRenderEnabled)
            Toggle(localizedKey("label_reverse_miss_fullscreen"),
                   isOn: $privacy.reverseLabelMissFullscreenEnabled)
            Toggle(localizedKey("label_empty_fullscreen"),
                   isOn: $privacy.accessibilityEmptyReverseFullscreenEnabled)
        }
    }

    private var presetsSection: some View {
        // MARK: - 预设
        Section(localizedKey("label_presets")) {
            LabeledContent(localizedKey("preset_current"),
                           value: currentPresetName)
            if privacy.presets.isEmpty {
                Text(localizedKey("preset_none"))
                    .foregroundColor(.secondary)
            } else {
                ForEach(privacy.presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            if preset.isBuiltIn {
                                Text(localizedKey("preset_builtin"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if preset.id == privacy.activePresetID {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                        Button(localizedKey("action_apply_preset")) {
                            privacy.applyPreset(preset, profile: appSettings.modelProfile)
                            noticeMessage = localizedFormat("preset_applied",
                                                            preset.name)
                        }
                        .buttonStyle(.bordered)
                        .disabled(preset.id == privacy.activePresetID)
                        Button(role: .destructive) {
                            presetToDelete = preset
                        } label: {
                            Text(localizedKey("action_delete"))
                        }
                        .buttonStyle(.bordered)
                        .disabled(preset.isBuiltIn)
                    }
                }
            }
            Button {
                showingPresetNamePrompt = true
            } label: {
                Label(localizedKey("action_save_preset"),
                      systemImage: "plus")
            }
            Button {
                showingPresetImporter = true
            } label: {
                Label(localizedKey("action_import_preset"),
                      systemImage: "square.and.arrow.down")
            }
        }
    }

    private var videoSection: some View {
        // MARK: - 视频
        Section(localizedKey("label_video_section")) {
            HStack {
                Text(localizedKey("label_video_stride"))
                Slider(value: Binding(
                    get: { Double(appSettings.videoDetectStride) },
                    set: { appSettings.videoDetectStride = Int($0) }
                ), in: 1...30, step: 1)
                Text("\(appSettings.videoDetectStride)")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private var appearanceSection: some View {
        // MARK: - 外观
        Section(localizedKey("label_appearance")) {
            Picker(localizedKey("label_appearance"),
                   selection: $appSettings.theme) {
                Text(localizedKey("theme_system")).tag(AppTheme.system)
                Text(localizedKey("theme_light")).tag(AppTheme.light)
                Text(localizedKey("theme_dark")).tag(AppTheme.dark)
            }
            .pickerStyle(.segmented)
        }
    }

    private var languageSection: some View {
        // MARK: - 语言
        Section(localizedKey("label_language")) {
            Picker(localizedKey("label_language"),
                   selection: $appSettings.language) {
                Text(localizedKey("language_system")).tag(AppLanguage.system)
                Text(localizedKey("language_zh_hans")).tag(AppLanguage.zhHans)
                Text(localizedKey("language_zh_hant")).tag(AppLanguage.zhHant)
                Text(localizedKey("language_en")).tag(AppLanguage.en)
                Text(localizedKey("language_ko")).tag(AppLanguage.ko)
            }
            .onChange(of: appSettings.language) { _, _ in
                showingLanguageRestartNote = true
            }
        }
    }

    private var aboutSection: some View {
        // MARK: - 关于
        Section(localizedKey("label_about")) {
            LabeledContent(localizedKey("label_version"), value: appVersionString)
            Text(localizedKey("label_about_text"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button(role: .destructive) {
                showingResetConfirm = true
            } label: {
                Text(localizedKey("action_reset_defaults"))
            }
        }
    }

    /// 安装包版本（短版本 + 构建号 + 修复轮次），用来确认手机上装的
    /// 是不是最新编出来的那一版：比如 R2 没出现就是装错了旧包。
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "2.1.12"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? shortVersion : "\(shortVersion) (\(build)) · R2"
    }

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                labelsSection
                maskParamsSection
                stickerSection
                outlineSection
                reverseSection
                presetsSection
                videoSection
                appearanceSection
                languageSection
                aboutSection
            }
            .navigationTitle(localizedKey("tab_settings"))
            .fileImporter(
                isPresented: $showingPresetImporter,
                allowedContentTypes: [UTType.zip],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importPreset(from: url)
                    }
                case .failure(let error):
                    noticeMessage = localizedFormat("preset_import_failed",
                                                    error.localizedDescription)
                }
            }
            .sheet(isPresented: $showingOutlinePicker) {
                LabelToggleSheet(
                    selected: $privacy.maskOutlineLabels,
                    titleKey: "action_outline_labels",
                    labels: labels
                )
            }
            .sheet(isPresented: $showingReversePicker) {
                LabelToggleSheet(
                    selected: $privacy.reverseLabels,
                    titleKey: "action_reverse_labels",
                    labels: labels
                )
            }
            .alert(localizedKey("preset_name_prompt"),
                   isPresented: $showingPresetNamePrompt) {
                TextField(localizedKey("preset_name_placeholder"),
                          text: $newPresetName)
                Button(localizedKey("action_confirm")) {
                    let name = newPresetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    privacy.savePreset(name: name, profile: appSettings.modelProfile)
                    noticeMessage = localizedFormat("preset_saved", name)
                    newPresetName = ""
                }
                Button(localizedKey("action_cancel"), role: .cancel) {
                    newPresetName = ""
                }
            }
            .alert(localizedKey("action_reset_defaults"),
                   isPresented: $showingResetConfirm) {
                Button(localizedKey("action_confirm"), role: .destructive) {
                    privacy.resetToDefaults()
                }
                Button(localizedKey("action_cancel"), role: .cancel) {}
            }
            .alert(localizedKey("common_notice"),
                   isPresented: $showingLanguageRestartNote) {
                Button(localizedKey("action_done"), role: .cancel) {}
            } message: {
                Text(localizedKey("label_language_restart_note"))
            }
            .alert(localizedKey("action_delete"),
                   isPresented: Binding(
                    get: { presetToDelete != nil },
                    set: { if !$0 { presetToDelete = nil } }
                   )) {
                Button(localizedKey("action_delete"), role: .destructive) {
                    if let preset = presetToDelete {
                        privacy.deletePreset(preset)
                        noticeMessage = localizedFormat("preset_deleted",
                                                        preset.name)
                    }
                    presetToDelete = nil
                }
                Button(localizedKey("action_cancel"), role: .cancel) {
                    presetToDelete = nil
                }
            } message: {
                if let preset = presetToDelete {
                    Text(localizedFormat("gallery_delete_message", preset.name))
                }
            }
            .alert(localizedKey("common_notice"),
                   isPresented: Binding(
                    get: { !noticeMessage.isEmpty },
                    set: { if !$0 { noticeMessage = "" } }
                   )) {
                Button(localizedKey("action_done"), role: .cancel) {}
            } message: {
                Text(noticeMessage)
            }
        }
    }

    // MARK: - 预设导入

    /// 从文件应用选 `.svpreset.zip`（或 `.zip`）导入预设。
    /// 用 NSFileCoordinator 读文件：第三方文件提供者（如“小米互联”）
    /// 的文件可能是远程的，直接 Data(contentsOf:) 会读失败，
    /// coordinator 会先把文件下载到本地再读。
    private func importPreset(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        var zipData: Data?
        var readError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [], error: &readError
        ) { coordinatedURL in
            zipData = try? Data(contentsOf: coordinatedURL)
        }
        guard let data = zipData else {
            noticeMessage = localized("preset_import_failed_read")
            return
        }
        let result = privacy.importPresetPackage(zipData: data)
        if let error = result.error {
            noticeMessage = localizedFormat("preset_import_failed", error)
        } else if result.imported.isEmpty {
            noticeMessage = localized("preset_import_none")
        } else {
            let imported = result.imported.joined(separator: "、")
            if result.skipped.isEmpty {
                noticeMessage = localizedFormat("preset_imported", imported)
            } else {
                noticeMessage = localizedFormat(
                    "preset_imported_skipped",
                    imported,
                    result.skipped.joined(separator: "、"))
            }
        }
    }
}

// MARK: - 单个标签的设置行

private struct LabelSettingsRow: View {
    @EnvironmentObject private var privacy: PrivacySettingsManager
    let label: String
    @State private var stickerItem: PhotosPickerItem?

    /// 该标签当前贴纸的文件名（未单独设置时显示默认贴纸）。
    private var stickerDisplayName: String {
        if let uri = privacy.labelStickerUris[label] {
            return (uri as NSString).lastPathComponent
        }
        if let uri = privacy.stickerUri {
            return (uri as NSString).lastPathComponent
        }
        return "Default-stickers.png"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(DetectionConfig.displayName(for: label))
                    .font(.subheadline)
                Spacer()
                // 锁定已取消：所有标签都可自由开关（见 DetectionConfig）。
                Toggle(localizedKey("label_enabled"), isOn: Binding(
                    get: { privacy.isEnabled(label) },
                    set: { privacy.labelEnabled[label] = $0 }
                ))
                .labelsHidden()
            }
            Picker(localizedKey("label_effect"), selection: Binding(
                get: { privacy.effect(for: label) },
                set: { privacy.labelEffects[label] = $0 }
            )) {
                ForEach(MaskEffect.allCases, id: \.self) { effect in
                    Text(effect.displayName).tag(effect)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Text(localizedKey("label_scale"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(value: Binding(
                    get: { Double(privacy.scale(for: label)) },
                    set: { privacy.labelScales[label] = CGFloat($0) }
                ), in: 0.1...3, step: 0.1)
                Text(String(format: "%.1fx", privacy.scale(for: label)))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            // 该标签效果为贴纸时，可单独选贴纸（与 Android 一致：
            // 点标签进设置里选该标签的贴纸）。
            if privacy.effect(for: label) == .sticker {
                HStack {
                    Text(localizedKey("label_current_sticker"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(stickerDisplayName)
                        .font(.caption)
                    Spacer()
                    PhotosPicker(selection: $stickerItem, matching: .images) {
                        Text(localizedKey("action_pick_custom_sticker"))
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .onChange(of: stickerItem) { _, newItem in
                        guard let newItem else { return }
                        Task {
                            if let data = try? await newItem.loadTransferable(type: Data.self),
                               let relativePath = StickerLoader.saveCustomSticker(
                                   data: data, fileName: "sticker.png") {
                                await MainActor.run {
                                    privacy.labelStickerUris[label] = relativePath
                                }
                            }
                        }
                    }
                    Button(localizedKey("action_use_default_sticker")) {
                        privacy.labelStickerUris.removeValue(forKey: label)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 标签多选表（描边部位 / 反向标签）

private struct LabelToggleSheet: View {
    @Binding var selected: [String]
    let titleKey: String
    let labels: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(labels, id: \.self) { label in
                    Toggle(DetectionConfig.displayName(for: label), isOn: Binding(
                        get: { selected.contains(label) },
                        set: { isOn in
                            if isOn {
                                if !selected.contains(label) { selected.append(label) }
                            } else {
                                selected.removeAll { $0 == label }
                            }
                        }
                    ))
                }
            }
            .navigationTitle(localizedKey(titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localizedKey("action_done")) { dismiss() }
                }
            }
        }
    }
}
