import SwiftUI
import WebKit

struct ContentView: View {
    var body: some View {
        TabView {
            ImageProcessingView()
                .tabItem {
                    Label(localizedKey("tab_image"), systemImage: "photo")
                }
            VideoProcessingView()
                .tabItem {
                    Label(localizedKey("tab_video"), systemImage: "film")
                }
            BatchView()
                .tabItem {
                    Label(localizedKey("tab_batch"), systemImage: "square.stack.3d.up")
                }
            GalleryView()
                .tabItem {
                    Label(localizedKey("tab_gallery"), systemImage: "photo.on.rectangle")
                }
            BrowserView()
                .tabItem {
                    Label(localizedKey("tab_browser"), systemImage: "globe")
                }
            SettingsView()
                .tabItem {
                    Label(localizedKey("tab_settings"), systemImage: "gearshape")
                }
        }
    }
}

// MARK: - 内置浏览器（v1）
//
// iOS 做不了实时全屏监控（第三方应用无法监听其它应用的屏幕），
// 因此用应用内浏览器代替：在 Safe Vision 里上网时，页面里的图片
// 会被检测并打码（与图片处理同一套逻辑：反向遮挡、全屏回退、
// 预设效果都生效）。
//
// v1 范围：
// - 地址栏、前进/后退/刷新、内容过滤开关、已打码图片计数。
// - 页面加载完成时收集 `<img>` 并打码；`MutationObserver` 监听
//   动态新增的图片（滚动加载、懒加载），防抖 1 秒后重新扫描。
// - 只处理主框架内的 `<img>`（iframe 内的图片暂不处理）；
//   页面里的 `<video>` 不处理（v1 不支持）。
// - 图片下载单张上限 8MB，超时 20 秒；检测失败或无检测结果时
//   保留原图（不替换）。
// - 关闭内容过滤会刷新页面恢复原图。
struct BrowserView: View {
    @State private var urlText = ""
    @State private var filterEnabled = true
    @State private var maskedCount = 0
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var loadErrorMessage = ""
    @FocusState private var urlFieldFocused: Bool
    @State private var webView: WKWebView

    init() {
        _webView = State(initialValue: WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()))
    }

    private var statusText: String {
        if !loadErrorMessage.isEmpty {
            return loadErrorMessage
        }
        if maskedCount > 0 {
            return localizedFormat("browser_masked_count", maskedCount)
        }
        if isLoading {
            return localized("browser_loading")
        }
        return localized("browser_hint")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { webView.goBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canGoBack)
                    Button { webView.goForward() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canGoForward)
                    Button { webView.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    TextField(localized("browser_url_placeholder"), text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($urlFieldFocused)
                        .onSubmit { navigate() }
                    Button(localized("browser_go")) { navigate() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                HStack {
                    Toggle(localizedKey("browser_filter"), isOn: $filterEnabled)
                    Spacer()
                    if isLoading {
                        ProgressView()
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(loadErrorMessage.isEmpty ? .secondary : .red)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                Divider()
                BrowserWebView(
                    webView: webView,
                    filterEnabled: $filterEnabled,
                    maskedCount: $maskedCount,
                    isLoading: $isLoading,
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward,
                    urlText: $urlText,
                    loadErrorMessage: $loadErrorMessage
                )
                // WKWebView（UIScrollView 子类）没有内在尺寸，不给
                // frame 会在 VStack 里被压成 0 高、整页只剩白底，
                // 看起来像“假浏览器”：必须占满剩余空间。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(localizedKey("tab_browser"))
            .navigationBarTitleDisplayMode(.inline)
            // 首次打开浏览器时加载一个默认起始页：之前一进来就是白板，
            // 用户以为浏览器是假的。
            .onAppear {
                if webView.url == nil {
                    urlText = "https://www.bing.com"
                    navigate()
                }
            }
        }
    }

    private func navigate() {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text) else {
            loadErrorMessage = localized("browser_invalid_url")
            return
        }
        // 点“前往”立刻给反馈：先收键盘、亮起“加载中”，再真正加载。
        // 之前这里只调 webView.load，加载失败时代理静默吞掉错误，
        // 状态栏一直停在“输入网址开始浏览”，看起来像点了没反应。
        urlFieldFocused = false
        loadErrorMessage = ""
        maskedCount = 0
        isLoading = true
        urlText = text
        webView.load(URLRequest(url: url))
    }
}

// MARK: - WKWebView 封装

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    @Binding var filterEnabled: Bool
    @Binding var maskedCount: Int
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var urlText: String
    @Binding var loadErrorMessage: String

    /// 单张图片下载上限（8MB）。
    static let maxImageBytes = 8 * 1024 * 1024

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        let controller = webView.configuration.userContentController
        controller.add(context.coordinator, name: "svImagesChanged")
        // 页面加载结束时注入辅助函数（收集图片、替换图片、监听新增图片）。
        let helper = WKUserScript(
            source: Self.helperScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true)
        controller.addUserScript(helper)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 关闭过滤时刷新页面恢复原图。
        if !filterEnabled, context.coordinator.wasFilterEnabled {
            uiView.reload()
        }
        context.coordinator.wasFilterEnabled = filterEnabled
    }

    /// 注入页面的辅助 JS：收集未打码的图片 URL、按 URL 替换为打码后的
    /// data URL、监听动态新增的图片并回调 Swift。
    static let helperScript = """
        (function() {
          if (window.__svInstalled) return;
          window.__svInstalled = true;
          window.__svCollectImages = function() {
            var imgs = document.querySelectorAll('img:not([data-sv-masked])');
            var urls = [];
            for (var i = 0; i < imgs.length; i++) {
              var src = imgs[i].currentSrc || imgs[i].src;
              if (src && src.indexOf('data:') !== 0) {
                urls.push(src);
              }
            }
            return urls;
          };
          window.__svReplaceImage = function(url, dataUrl) {
            var imgs = document.querySelectorAll('img');
            var count = 0;
            for (var i = 0; i < imgs.length; i++) {
              var src = imgs[i].currentSrc || imgs[i].src;
              if (src === url) {
                imgs[i].src = dataUrl;
                imgs[i].setAttribute('data-sv-masked', '1');
                count++;
              }
            }
            return count;
          };
          window.__svStartObserver = function() {
            if (window.__svObserverInstalled) return;
            window.__svObserverInstalled = true;
            var observer = new MutationObserver(function(mutations) {
              var hasNewImg = false;
              for (var i = 0; i < mutations.length; i++) {
                var added = mutations[i].addedNodes;
                for (var j = 0; j < added.length; j++) {
                  var node = added[j];
                  if (node.nodeType !== 1) continue;
                  if (node.tagName === 'IMG') { hasNewImg = true; break; }
                  if (node.querySelector && node.querySelector('img')) { hasNewImg = true; break; }
                }
                if (hasNewImg) break;
              }
              if (hasNewImg) {
                window.webkit.messageHandlers.svImagesChanged.postMessage('changed');
              }
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
          };
        })();
        """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BrowserWebView
        var wasFilterEnabled = true
        private let engine = DetectionEngine()
        private var isScanning = false
        private var scanRequested = false
        private var scanWorkItem: DispatchWorkItem?
        private var inFlight: Set<String> = []

        init(parent: BrowserWebView) {
            self.parent = parent
        }

        // MARK: - 导航

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            updateNavState(webView)
            parent.loadErrorMessage = ""
            parent.maskedCount = 0
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            updateNavState(webView)
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateNavState(webView)
            parent.isLoading = false
            parent.loadErrorMessage = ""
            if let url = webView.url {
                parent.urlText = url.absoluteString
            }
            webView.evaluateJavaScript(
                "window.__svStartObserver && window.__svStartObserver();",
                completionHandler: nil)
            scanImages()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.loadErrorMessage = localizedFormat(
                "browser_load_failed", error.localizedDescription)
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            // 加载失败必须说出来（比如 x.com 在国内直连打不开时），
            // 否则白屏 + 状态栏不变，用户只能干等。
            parent.loadErrorMessage = localizedFormat(
                "browser_load_failed", error.localizedDescription)
            updateNavState(webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebContent 进程在 LiveContainer 沙盒里崩了会白屏，
            // 自动重载恢复页面。
            webView.reload()
        }

        private func updateNavState(_ webView: WKWebView) {
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        // MARK: - 动态图片回调（防抖 1 秒）

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "svImagesChanged" else { return }
            scanWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.scanImages()
            }
            scanWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }

        // MARK: - 扫描与打码

        func scanImages() {
            guard parent.filterEnabled else { return }
            if isScanning {
                scanRequested = true
                return
            }
            isScanning = true
            Task {
                await performScan()
                await MainActor.run {
                    self.isScanning = false
                    if self.scanRequested {
                        self.scanRequested = false
                        self.scanImages()
                    }
                }
            }
        }

        private func performScan() async {
            guard let urls = try? await parent.webView.evaluateJavaScript(
                "window.__svCollectImages()") as? [String] else {
                return
            }
            for urlString in urls {
                if !parent.filterEnabled { return }
                await processImage(urlString: urlString)
            }
        }

        /// 下载一张图片 → 检测 → 打码 → 替换为 data URL。
        /// 检测失败、无检测结果、图片过大或格式不支持时保留原图。
        private func processImage(urlString: String) async {
            guard !inFlight.contains(urlString) else { return }
            inFlight.insert(urlString)
            defer { inFlight.remove(urlString) }
            guard let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https" else { return }
            do {
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.httpMethod = "GET"
                let (data, _) = try await URLSession.shared.data(for: request)
                guard data.count <= BrowserWebView.maxImageBytes else { return }
                guard let image = UIImage(data: data) else { return }
                // 模型按当前 profile 加载（已加载同一 profile 时是 no-op）。
                try engine.load(profile: AppSettingsManager.shared.modelProfile)
                let detections = try engine.detect(uiImage: image)
                guard !detections.isEmpty else { return }
                guard let masked = MaskRenderer.renderDetections(image, detections: detections),
                      let jpegData = masked.jpegData(compressionQuality: 0.85) else { return }
                let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
                let js = "window.__svReplaceImage(\(jsString(urlString)), \(jsString(dataURL)))"
                if let count = try? await parent.webView.evaluateJavaScript(js) as? Int,
                   count > 0 {
                    await MainActor.run {
                        parent.maskedCount += count
                    }
                }
            } catch {
                return
            }
        }

        /// 把一个字符串转成 JSON 字符串字面量（安全拼进 JS 调用）。
        /// 注意：不能用 JSONSerialization.data(withJSONObject:) 传 String——
        /// 它要求顶层是 NSArray/NSDictionary，传 String 会抛 NSException
        /// （"Invalid top-level type in JSON write"），Swift 的 try? 抓不住
        /// Objective-C 异常，会直接闪退。JSONEncoder 可以正确编码顶层 String。
        private func jsString(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let json = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return json
        }
    }
}
