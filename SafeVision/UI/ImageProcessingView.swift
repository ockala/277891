import PhotosUI
import SwiftUI
import UIKit

/// 图片处理页：选图 / 拍照 -> 检测 -> 点选检测框改效果 -> 应用打码 -> 保存。
struct ImageProcessingView: View {
    @EnvironmentObject private var privacy: PrivacySettingsManager
    @EnvironmentObject private var appSettings: AppSettingsManager
    @StateObject private var engine = DetectionEngine()

    @State private var photoItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var detections: [Detection] = []
    @State private var maskedImage: UIImage?
    @State private var selectedDetection: Detection?
    @State private var isDetecting = false
    @State private var isMasking = false
    @State private var isSaving = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var showingCamera = false

    private var displayedImage: UIImage? { maskedImage ?? selectedImage }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // MARK: - 选择图片
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(localizedKey("action_select_image"), systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                showingCamera = true
                            } else {
                                errorMessage = localized("error_camera_unavailable")
                            }
                        } label: {
                            Label(localizedKey("action_take_photo"), systemImage: "camera")
                        }
                        .buttonStyle(.bordered)
                    }
                    .onChange(of: photoItem) { _, newValue in
                        Task { await loadPhotoItem(newValue) }
                    }

                    // MARK: - 图片 + 检测框
                    if let image = selectedImage {
                        GeometryReader { geometry in
                            ZStack {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geometry.size.width,
                                           height: geometry.size.height)
                                DetectionOverlayView(
                                    imageSize: image.size,
                                    displaySize: geometry.size,
                                    detections: detections,
                                    selectedID: selectedDetection?.id,
                                    onSelect: { selectedDetection = $0 }
                                )
                            }
                        }
                        .frame(height: 360)
                        .background(Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        if !detections.isEmpty {
                            Text(localizedKey("label_tap_box_hint"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }

                        // MARK: - 检测 / 打码
                        HStack(spacing: 12) {
                            Button {
                                startDetection()
                            } label: {
                                if isDetecting {
                                    ProgressView()
                                } else {
                                    Label(localizedKey("action_start_detection"),
                                          systemImage: "viewfinder")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isDetecting || isMasking)

                            Button {
                                applyMask()
                            } label: {
                                if isMasking {
                                    ProgressView()
                                } else {
                                    Label(localizedKey("action_apply_mask"),
                                          systemImage: "eye.slash")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDetecting || isMasking || detections.isEmpty)
                        }

                        // MARK: - 打码结果
                        if let masked = maskedImage {
                            Text(localizedKey("status_mask_applied"))
                                .font(.headline)
                            Image(uiImage: masked)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // MARK: - 保存
                        HStack(spacing: 12) {
                            Button {
                                saveToPhotos()
                            } label: {
                                Label(localizedKey("action_save_to_photos"),
                                      systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving || displayedImage == nil)

                            Button {
                                saveToAppFolder()
                            } label: {
                                Label(localizedKey("action_save_to_app"),
                                      systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving || displayedImage == nil)
                        }
                    } else {
                        ContentUnavailableView(
                            localizedKey("status_select_image_hint"),
                            systemImage: "photo",
                            description: Text(localizedKey("status_image_ready"))
                        )
                        .frame(height: 280)
                    }

                    // MARK: - 状态 / 错误
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
                .padding()
            }
            .navigationTitle(localizedKey("tab_image"))
            .sheet(item: $selectedDetection) { detection in
                DetectionEffectSheet(detection: detection)
                    .environmentObject(privacy)
            }
            .sheet(isPresented: $showingCamera) {
                CameraPickerView(image: $selectedImage, onPicked: resetResults)
            }
            .task {
                ensureModelLoaded()
            }
            .onChange(of: appSettings.modelProfile) { _, _ in
                detections = []
                maskedImage = nil
                ensureModelLoaded()
            }
        }
    }

    // MARK: - 选图

    private func loadPhotoItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                await MainActor.run {
                    errorMessage = localizedFormat("error_load_image_failed",
                                                   localized("error_unknown"))
                }
                return
            }
            await MainActor.run {
                selectedImage = image
                resetResults()
                statusMessage = localized("status_image_ready")
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = localizedFormat("error_load_image_failed",
                                               error.localizedDescription)
            }
        }
    }

    private func resetResults() {
        detections = []
        maskedImage = nil
        selectedDetection = nil
        statusMessage = ""
        errorMessage = nil
    }

    // MARK: - 模型加载（后台线程，失败只显示中文提示，不崩溃）

    // 注意：不要用 `engine.isLoaded` 做 early-return——`DetectionEngine.load`
    // 内部已有“同一 profile 不重复加载”的 no-op 保护；这里每次都调 load，
    // 设置里切换模型（标准↔动漫）才能立即生效，否则会一直沿用第一次加载的模型。
    private func ensureModelLoaded() {
        let profile = appSettings.modelProfile
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            do {
                try engine.load(profile: profile)
            } catch {
                DispatchQueue.main.async {
                    errorMessage = message(for: error)
                }
            }
        }
    }

    // MARK: - 检测（后台线程）

    private func startDetection() {
        guard let image = selectedImage else {
            errorMessage = localized("status_no_image_selected")
            return
        }
        errorMessage = nil
        statusMessage = localized("status_detecting")
        isDetecting = true
        let profile = appSettings.modelProfile
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            do {
                // 每次都调 load（同一 profile 时内部 no-op），切模型立即生效。
                try engine.load(profile: profile)
                let results = try engine.detect(uiImage: image)
                DispatchQueue.main.async {
                    isDetecting = false
                    detections = results
                    maskedImage = nil
                    selectedDetection = nil
                    if results.isEmpty {
                        statusMessage = localized("status_no_detection")
                    } else {
                        statusMessage = localizedFormat("status_detection_done",
                                                        results.count)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isDetecting = false
                    errorMessage = message(for: error)
                    statusMessage = ""
                }
            }
        }
    }

    // MARK: - 打码（后台线程）

    /// 走 `renderDetections`（不是低阶的 `maskedImage`），让图片也应用
    /// 反向遮挡与全屏回退（与视频管线一致）。
    private func applyMask() {
        guard let image = selectedImage else { return }
        // 无检测结果且不需要全屏回退时，没有可打码的框。
        let needsFullscreen = privacy.accessibilityEmptyReverseFullscreenEnabled
            && !privacy.reverseLabels.isEmpty && detections.isEmpty
        guard !detections.isEmpty || needsFullscreen else {
            statusMessage = localized("label_no_mask_boxes")
            return
        }
        errorMessage = nil
        isMasking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MaskRenderer.renderDetections(image, detections: detections)
            DispatchQueue.main.async {
                isMasking = false
                if let result {
                    maskedImage = result
                    statusMessage = localized("status_mask_applied")
                } else {
                    errorMessage = localized("error_unknown")
                }
            }
        }
    }

    // MARK: - 保存

    private func saveToPhotos() {
        guard let image = displayedImage else { return }
        isSaving = true
        requestPhotoLibraryAddAccess { granted in
            DispatchQueue.main.async {
                guard granted else {
                    isSaving = false
                    errorMessage = localizedFormat(
                        "status_save_failed", localized("error_photo_access_denied"))
                    return
                }
                MediaSaveHelper.saveImageToPhotos(image) { success, error in
                    DispatchQueue.main.async {
                        isSaving = false
                        if success {
                            statusMessage = localized("status_saved_to_photos")
                            errorMessage = nil
                        } else {
                            errorMessage = localizedFormat(
                                "status_save_failed",
                                error?.localizedDescription ?? localized("error_unknown"))
                        }
                    }
                }
            }
        }
    }

    private func saveToAppFolder() {
        guard let image = displayedImage else { return }
        isSaving = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fileName = "SafeVision-\(Int(Date().timeIntervalSince1970)).jpg"
            let url = MediaSaveHelper.saveImageToAppFolder(image, fileName: fileName)
            DispatchQueue.main.async {
                isSaving = false
                if let url {
                    statusMessage = localizedFormat("status_saved_to_app",
                                                    url.lastPathComponent)
                    errorMessage = nil
                } else {
                    errorMessage = localizedFormat("status_save_failed",
                                                   localized("error_unknown"))
                }
            }
        }
    }

    // MARK: - 错误文案

    private func message(for error: Error) -> String {
        if let engineError = error as? DetectionEngine.EngineError {
            switch engineError {
            case .modelMissing:
                return localized("status_model_missing")
            case .loadFailed(let underlying):
                return localizedFormat("status_model_load_failed",
                                       underlying.localizedDescription)
            case .predictionFailed(let underlying):
                return localizedFormat("status_detection_failed",
                                       underlying.localizedDescription)
            }
        }
        return localizedFormat("status_detection_failed", error.localizedDescription)
    }
}

// MARK: - 点选检测框后的效果编辑

private struct DetectionEffectSheet: View {
    @EnvironmentObject private var privacy: PrivacySettingsManager
    @Environment(\.dismiss) private var dismiss
    let detection: Detection
    @State private var stickerItem: PhotosPickerItem?

    /// 该标签当前贴纸的文件名（未单独设置时显示默认贴纸）。
    private var stickerDisplayName: String {
        if let uri = privacy.labelStickerUris[detection.label] {
            return (uri as NSString).lastPathComponent
        }
        if let uri = privacy.stickerUri {
            return (uri as NSString).lastPathComponent
        }
        return "Default-stickers.png"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(localizedKey("label_selected_label")) {
                    LabeledContent(localizedKey("label_selected_label"),
                                   value: DetectionConfig.displayName(for: detection.label))
                    LabeledContent(localizedKey("label_confidence"),
                                   value: String(format: "%.2f", detection.score))
                    Toggle(localizedKey("label_enabled"), isOn: Binding(
                        get: { privacy.isEnabled(detection.label) },
                        set: { privacy.labelEnabled[detection.label] = $0 }
                    ))
                    // 锁定已取消：所有标签都可自由开关（见 DetectionConfig）。
                }
                Section(localizedKey("label_effect")) {
                    Picker(localizedKey("label_effect"), selection: Binding(
                        get: { privacy.effect(for: detection.label) },
                        set: { privacy.labelEffects[detection.label] = $0 }
                    )) {
                        ForEach(MaskEffect.allCases, id: \.self) { effect in
                            Text(effect.displayName).tag(effect)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text(localizedKey("label_scale"))
                        Slider(value: Binding(
                            get: { Double(privacy.scale(for: detection.label)) },
                            set: { privacy.labelScales[detection.label] = CGFloat($0) }
                        ), in: 0.1...3, step: 0.1)
                        Text(String(format: "%.1fx", privacy.scale(for: detection.label)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                // 该标签效果为贴纸时，可单独选贴纸（与设置页的每标签贴纸入口一致）。
                if privacy.effect(for: detection.label) == .sticker {
                    Section(localizedKey("label_sticker")) {
                        LabeledContent(localizedKey("label_current_sticker"),
                                       value: stickerDisplayName)
                        PhotosPicker(selection: $stickerItem, matching: .images) {
                            Label(localizedKey("action_pick_custom_sticker"),
                                  systemImage: "photo")
                        }
                        .onChange(of: stickerItem) { _, newItem in
                            guard let newItem else { return }
                            Task {
                                if let data = try? await newItem.loadTransferable(type: Data.self),
                                   let relativePath = StickerLoader.saveCustomSticker(
                                       data: data, fileName: "sticker.png") {
                                    await MainActor.run {
                                        privacy.labelStickerUris[detection.label] = relativePath
                                    }
                                }
                            }
                        }
                        Button(localizedKey("action_use_default_sticker")) {
                            privacy.labelStickerUris.removeValue(forKey: detection.label)
                        }
                    }
                }
            }
            .navigationTitle(DetectionConfig.displayName(for: detection.label))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localizedKey("action_done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - 相机（UIImagePickerController 包装）

private struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    var onPicked: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView

        init(parent: CameraPickerView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let picked = info[.originalImage] as? UIImage {
                parent.image = picked
                parent.onPicked()
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
