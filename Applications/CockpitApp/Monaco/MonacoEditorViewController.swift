import AppKit
import WebKit
import CockpitProtocol
import CockpitTypes

public typealias MonacoWebViewFactory = @MainActor (WKWebViewConfiguration) -> WKWebView

@MainActor
final class WeakMonacoScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: MonacoBridge?

    init(bridge: MonacoBridge) {
        self.bridge = bridge
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let reply = await bridge?.handleMessageBody(message.body)
            ?? .failure(.transportFailure)
        return (MonacoMessageCodec.javaScriptObject(for: reply), nil)
    }
}

@MainActor
private final class MonacoJavaScriptMessageDispatcher {
    private weak var webView: WKWebView?
    private var tail: Task<Void, Never>?
    private var isActive = true

    init(webView: WKWebView) {
        self.webView = webView
    }

    func enqueue(_ message: [String: Any]) {
        guard isActive else { return }
        let previous = tail
        tail = Task { @MainActor [weak self, weak webView] in
            await previous?.value
            guard let self, self.isActive, let webView else { return }
            _ = try? await webView.callAsyncJavaScript(
                "return globalThis.cockpitMonacoReceive(message)",
                arguments: ["message": message],
                in: nil,
                contentWorld: .page
            )
        }
    }

    func invalidate() {
        isActive = false
        tail?.cancel()
        tail = nil
        webView = nil
    }
}

@MainActor
public final class MonacoEditorViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    public let bridge: MonacoBridge
    public let webView: WKWebView
    public let runtimeBundleURL: URL
    private(set) var forwarder: WeakMonacoScriptMessageHandler?
    private let dispatcher: MonacoJavaScriptMessageDispatcher
    private var tornDown = false

    public init(
        bridge: MonacoBridge,
        runtimeBundleURL: URL,
        webViewFactory: MonacoWebViewFactory = { WKWebView(frame: .zero, configuration: $0) }
    ) {
        self.bridge = bridge
        self.runtimeBundleURL = runtimeBundleURL
        let configuration = WKWebViewConfiguration()
        let forwarder = WeakMonacoScriptMessageHandler(bridge: bridge)
        configuration.userContentController.addScriptMessageHandler(
            forwarder,
            contentWorld: .page,
            name: "cockpitMonaco"
        )
        let webView = webViewFactory(configuration)
        let dispatcher = MonacoJavaScriptMessageDispatcher(webView: webView)
        self.forwarder = forwarder
        self.webView = webView
        self.dispatcher = dispatcher
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridge.setSink { [weak dispatcher] message in
            let object = try MonacoMessageCodec.javaScriptObject(for: message)
            dispatcher?.enqueue(object)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        view = webView
    }

    public func loadRuntime() {
        let userContentController = webView.configuration.userContentController
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(WKUserScript(
            source: "globalThis.cockpitWebContentGeneration = \(bridge.webContentGeneration);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        let index = runtimeBundleURL.appendingPathComponent("index.html", isDirectory: false)
        webView.loadFileURL(index, allowingReadAccessTo: runtimeBundleURL)
    }

    public func allowsNavigation(
        _ url: URL?,
        isMainFrame: Bool,
        opensNewWindow: Bool,
        isDownload: Bool
    ) -> Bool {
        guard let url, url.isFileURL, isMainFrame, !opensNewWindow, !isDownload else {
            return false
        }
        let root = runtimeBundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target == root || target.hasPrefix(root + "/")
    }

    public func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "cockpitMonaco",
            contentWorld: .page
        )
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        bridge.setSink { _ in }
        dispatcher.invalidate()
        forwarder = nil
    }

    deinit {
        MainActor.assumeIsolated { tearDown() }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView,
              bridge.webContentGeneration < documentJavaScriptMaximum,
              (try? bridge.prepareForWebContentRestart(
                generation: bridge.webContentGeneration + 1
              )) != nil
        else { return }
        loadRuntime()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let forbiddenNavigationType: Bool
        switch navigationAction.navigationType {
        case .formSubmitted, .formResubmitted:
            forbiddenNavigationType = true
        default:
            forbiddenNavigationType = false
        }
        guard !forbiddenNavigationType,
              allowsNavigation(
                navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                opensNewWindow: navigationAction.targetFrame == nil,
                isDownload: navigationAction.shouldPerformDownload
              )
        else { return .cancel }
        return .allow
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        guard navigationResponse.canShowMIMEType,
              allowsNavigation(
                navigationResponse.response.url,
                isMainFrame: navigationResponse.isForMainFrame,
                opensNewWindow: false,
                isDownload: false
              )
        else { return .cancel }
        return .allow
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }
}
