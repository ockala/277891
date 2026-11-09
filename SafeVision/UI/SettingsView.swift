import SwiftUI

/// 设置页：模型、标签设置、打码参数、预设、视频、外观、语言、关于。
struct SettingsView: View {
    @EnvironmentObject private var privacy: PrivacySettingsManager
    @EnvironmentObject private var appSettings: AppSettingsManager

    @State private var showingPresetNamePrompt = false
    @State private var newPresetName = ""
    @State private var showingResetConfirm = false
    @State private var showingLanguageRestartNote = false
    @State private var presetToDelete: PrivacyPreset?
    @State private var noticeMessage = ""

    private var labels: [String] {
        DetectionConfig.labels(for: appSettings.modelProfile)
    }

    private var lockedLabels: [String] {
        DetectionConfig.lockedLabels(for: appSettings.modelProfile)
    }

    private var currentPresetName: String {
        privacy.presets.first(where: { $0.id == privacy.activePresetID })?.name
            ?? localized("preset_none")
    }

    var body: some View {
        NavigationStack {
            Form {
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

                // MARK: - 标签设置
                Section(localizedKey("label_labels")) {
                    ForEach(labels, id: \.self) { label in
                        LabelSettingsRow(
                            label: label,
                            isLocked: lockedLabels.contains(label)
                        )
                    }
                }

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
                }

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
                                    privacy.applyPreset(preset)
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
                }

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

                // MARK: - 关于
                Section(localizedKey("label_about")) {
                    LabeledContent(localizedKey("label_version"), value: "2.1.12")
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
            .navigationTitle(localizedKey("tab_settings"))
            .alert(localizedKey("preset_name_prompt"),
                   isPresented: $showingPresetNamePrompt) {
                TextField(localizedKey("preset_name_placeholder"),
                          text: $newPresetName)
                Button(localizedKey("action_confirm")) {
                    let name = newPresetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    privacy.savePreset(name: name)
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
}

// MARK: - 单个标签的设置行

private struct LabelSettingsRow: View {
    @EnvironmentObject private var privacy: PrivacySettingsManager
    let label: String
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(DetectionConfig.displayName(for: label))
                    .font(.subheadline)
                Spacer()
                if isLocked {
                    Text(localizedKey("label_locked"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Toggle(localizedKey("label_enabled"), isOn: Binding(
                    get: { privacy.isEnabled(label) },
                    set: { privacy.labelEnabled[label] = $0 }
                ))
                .labelsHidden()
                .disabled(isLocked)
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
        }
        .padding(.vertical, 4)
    }
}
