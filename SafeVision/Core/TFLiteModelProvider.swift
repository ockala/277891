import Foundation
import TensorFlowLite

/// Runs the original `.tflite` models directly with TensorFlow Lite Swift.
///
/// Core ML conversion was abandoned (coremltools 9 dropped TFLite support and
/// tflite2onnx fails on both models), so iOS runs the untouched models:
///
/// - standard: `Models/SafeVisionStandard.tflite` (nude26_best_float16)
/// - anime:    `Models/SafeVisionAnime.tflite`    (anime_320n_float16)
///
/// Both models take a FLOAT32 NHWC `[1, 320, 320, 3]` RGB tensor in `[0, 1]`
/// (see `ImagePreprocessor`) and return a single FLOAT32 output tensor:
///
/// - standard: `[1, 300, 6]` end-to-end rows `[x1, y1, x2, y2, score, classId]`
/// - anime:    `[1, 14, 2100]` legacy YOLO `[cx, cy, w, h, 10 class scores]`
///
/// The Metal delegate (`TensorFlowLiteSwift/Metal`) is preferred; if creating
/// the Metal interpreter fails, or if a Metal `invoke()` fails, the provider
/// transparently rebuilds a CPU interpreter and retries once. Failures are
/// reported as thrown errors, never crashes. `Interpreter` is not thread
/// safe, so all access is serialized with an `NSLock`.
public final class TFLiteModelProvider {

    public enum ProviderError: Error, LocalizedError {
        /// The `.tflite` file is not in the app bundle (not added to the
        /// target's Copy Bundle Resources, or renamed).
        case modelNotFound(resourceName: String)
        /// `load()` was never called, or a previous load failed.
        case notLoaded(resourceName: String)
        /// The interpreter could not be created (Metal and CPU both failed).
        case loadFailed(underlying: Error)
        /// The pixels passed to `predict` do not match the model's input.
        case invalidInput(message: String)
        /// The model's output is not the expected FLOAT32 tensor.
        case invalidOutput(message: String)
        /// Inference failed on both the Metal delegate and the CPU fallback.
        case predictionFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let resourceName):
                return "模型文件缺失：\(resourceName).tflite 不在 App Bundle 中，请确认已加入 target 的 Copy Bundle Resources"
            case .notLoaded(let resourceName):
                return "模型未加载：\(resourceName).tflite，请先调用 load()"
            case .loadFailed(let error):
                return "模型加载失败：\(error.localizedDescription)"
            case .invalidInput(let message):
                return "输入无效：\(message)"
            case .invalidOutput(let message):
                return "模型输出无效：\(message)"
            case .predictionFailed(let error):
                return "推理失败：\(error.localizedDescription)"
            }
        }
    }

    /// Expected input tensor shape for both models.
    public static let inputShape = [1, 320, 320, 3]
    /// Expected input element count: `320 * 320 * 3`.
    public static let inputElementCount = 320 * 320 * 3

    private let profile: LabelProfile
    private let resourceName: String

    private var interpreter: Interpreter?
    /// Retained for as long as the interpreter uses it; dropping the
    /// delegate while the interpreter is alive is undefined behaviour.
    private var metalDelegate: MetalDelegate?
    private var usingMetalDelegate = false
    private let lock = NSLock()

    /// Whether the active interpreter runs on the Metal delegate.
    public var isUsingMetalDelegate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingMetalDelegate
    }

    public init(profile: LabelProfile) {
        self.profile = profile
        switch profile {
        case .standard:
            self.resourceName = "SafeVisionStandard"
        case .anime:
            self.resourceName = "SafeVisionAnime"
        }
    }

    /// Loads the model for this provider's profile. Loading twice is a
    /// no-op. Throws `ProviderError.modelNotFound` if the `.tflite` file is
    /// missing from the bundle, `ProviderError.loadFailed` if neither the
    /// Metal nor the CPU interpreter can be created.
    public func load() throws {
        lock.lock()
        defer { lock.unlock() }
        if interpreter != nil { return }

        guard let modelURL = Self.modelURL(for: resourceName) else {
            throw ProviderError.modelNotFound(resourceName: resourceName)
        }
        do {
            try createInterpreter(modelPath: modelURL.path, useMetal: true)
        } catch {
            NSLog("[TFLiteModelProvider] Metal delegate 初始化失败，回退 CPU：\(error.localizedDescription)")
            do {
                try createInterpreter(modelPath: modelURL.path, useMetal: false)
            } catch {
                interpreter = nil
                metalDelegate = nil
                usingMetalDelegate = false
                throw ProviderError.loadFailed(underlying: error)
            }
        }
    }

    /// Runs one inference.
    ///
    /// - Parameters:
    ///   - pixels: FLOAT32 NHWC RGB pixels in `[0, 1]`, `320 * 320 * 3` values.
    ///   - shape: input shape, expected `[1, 320, 320, 3]`.
    /// - Returns: the flattened FLOAT32 output and its shape with the batch
    ///   dimension removed (`[300, 6]` standard, `[14, 2100]` anime).
    public func predict(pixels: [Float], shape: [Int]) throws -> (values: [Float], shape: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        guard let activeInterpreter = interpreter else {
            throw ProviderError.notLoaded(resourceName: resourceName)
        }
        guard shape == Self.inputShape else {
            throw ProviderError.invalidInput(
                message: "输入形状应为 \(Self.inputShape)，实际为 \(shape)"
            )
        }
        guard pixels.count == Self.inputElementCount else {
            throw ProviderError.invalidInput(
                message: "输入元素数应为 \(Self.inputElementCount)，实际为 \(pixels.count)"
            )
        }

        let inputData = pixels.withUnsafeBytes { Data($0) }
        do {
            try activeInterpreter.copy(inputData, toInputAt: 0)
            try activeInterpreter.invoke()
        } catch {
            if usingMetalDelegate {
                // Metal failed at runtime (e.g. an op the delegate cannot
                // run): rebuild on CPU and retry once with the same input.
                NSLog("[TFLiteModelProvider] Metal 推理失败，回退 CPU 重试：\(error.localizedDescription)")
                guard let modelURL = Self.modelURL(for: resourceName) else {
                    throw ProviderError.modelNotFound(resourceName: resourceName)
                }
                do {
                    try createInterpreter(modelPath: modelURL.path, useMetal: false)
                    guard let cpuInterpreter = interpreter else {
                        throw ProviderError.notLoaded(resourceName: resourceName)
                    }
                    try cpuInterpreter.copy(inputData, toInputAt: 0)
                    try cpuInterpreter.invoke()
                } catch {
                    throw ProviderError.predictionFailed(underlying: error)
                }
            } else {
                throw ProviderError.predictionFailed(underlying: error)
            }
        }

        guard let currentInterpreter = interpreter else {
            throw ProviderError.notLoaded(resourceName: resourceName)
        }
        let outputTensor: Tensor
        do {
            outputTensor = try currentInterpreter.output(at: 0)
        } catch {
            throw ProviderError.invalidOutput(message: "无法读取输出 tensor：\(error.localizedDescription)")
        }
        guard outputTensor.dataType == .float32 else {
            throw ProviderError.invalidOutput(message: "输出类型应为 float32，实际为 \(outputTensor.dataType)")
        }
        let values: [Float] = outputTensor.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        var outputShape = outputTensor.shape.dimensions
        // Drop the batch dimension: [1, 300, 6] -> [300, 6],
        // [1, 14, 2100] -> [14, 2100].
        if outputShape.count == 3 {
            outputShape.removeFirst()
        }
        guard outputShape.count == 2 else {
            throw ProviderError.invalidOutput(message: "输出形状应为二维，实际为 \(outputTensor.shape.dimensions)")
        }
        guard values.count == outputShape[0] * outputShape[1] else {
            throw ProviderError.invalidOutput(
                message: "输出元素数 \(values.count) 与形状 \(outputShape) 不符"
            )
        }
        return (values: values, shape: outputShape)
    }

    // MARK: - Interpreter setup

    /// Creates the interpreter (Metal delegate or CPU) and allocates its
    /// tensors. Validates that the declared input is a FLOAT32 tensor with
    /// the expected element count. On any failure the previous interpreter
    /// (if any) is left untouched by the caller.
    private func createInterpreter(modelPath: String, useMetal: Bool) throws {
        var delegates: [Delegate]?
        var metal: MetalDelegate?
        if useMetal {
            metal = MetalDelegate()
            delegates = [metal!]
        }
        let newInterpreter = try Interpreter(modelPath: modelPath, delegates: delegates)
        try newInterpreter.allocateTensors()

        let inputTensor = try newInterpreter.input(at: 0)
        guard inputTensor.dataType == .float32 else {
            throw ProviderError.invalidInput(message: "模型输入类型应为 float32，实际为 \(inputTensor.dataType)")
        }
        let inputCount = inputTensor.shape.dimensions.reduce(1, *)
        guard inputCount == Self.inputElementCount else {
            throw ProviderError.invalidInput(
                message: "模型输入元素数应为 \(Self.inputElementCount)，实际为 \(inputCount)（形状 \(inputTensor.shape.dimensions)）"
            )
        }

        interpreter = newInterpreter
        metalDelegate = metal
        usingMetalDelegate = useMetal
    }

    // MARK: - Bundle lookup

    /// Locates `<resourceName>.tflite` in the app bundle. The Xcode project
    /// may add the `Models` folder as a folder reference (file lives under a
    /// `Models/` subdirectory in the bundle) or as a group (file at the
    /// bundle root); both layouts are tried, main bundle first.
    private static func modelURL(for resourceName: String) -> URL? {
        let mainBundle = Bundle.main
        if let url = mainBundle.url(forResource: resourceName, withExtension: "tflite", subdirectory: "Models") {
            return url
        }
        if let url = mainBundle.url(forResource: resourceName, withExtension: "tflite") {
            return url
        }
        let providerBundle = Bundle(for: TFLiteModelProvider.self)
        if providerBundle != mainBundle {
            if let url = providerBundle.url(forResource: resourceName, withExtension: "tflite", subdirectory: "Models") {
                return url
            }
            if let url = providerBundle.url(forResource: resourceName, withExtension: "tflite") {
                return url
            }
        }
        return nil
    }
}
