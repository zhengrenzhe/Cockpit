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
    private var tail: Task<Void, any Error>?
    private var isActive = true

    init(webView: WKWebView) {
        self.webView = webView
    }

    func dispatch(_ message: [String: Any]) async throws {
        guard isActive else { throw MonacoBridgeError.transportFailure }
        let previous = tail
        let current = Task { @MainActor [weak self, weak webView] in
            if let previous { _ = await previous.result }
            guard let self, self.isActive, let webView else {
                throw MonacoBridgeError.transportFailure
            }
            let reply = try await webView.callAsyncJavaScript(
                "return globalThis.cockpitMonacoReceive(message)",
                arguments: ["message": message],
                in: nil,
                contentWorld: .page
            )
            try Self.validate(reply)
        }
        tail = current
        do {
            try await current.value
        } catch let error as MonacoBridgeError {
            throw error
        } catch {
            throw MonacoBridgeError.transportFailure
        }
    }

    func invalidate() {
        isActive = false
        tail?.cancel()
        tail = nil
        webView = nil
    }

    private static func validate(_ value: Any?) throws {
        guard let reply = value as? [String: Any],
              let ok = reply["ok"] as? Bool
        else { throw MonacoBridgeError.transportFailure }
        if ok {
            guard Set(reply.keys) == ["ok"] else {
                throw MonacoBridgeError.transportFailure
            }
            return
        }
        guard Set(reply.keys) == ["ok", "error"],
              let code = reply["error"] as? String,
              let error = bridgeError(for: code)
        else { throw MonacoBridgeError.transportFailure }
        throw error
    }

    private static func bridgeError(for code: String) -> MonacoBridgeError? {
        switch code {
        case MonacoBridgeError.invalidSchema.wireCode: .invalidSchema
        case MonacoBridgeError.staleGeneration.wireCode: .staleGeneration
        case MonacoBridgeError.staleDocumentState.wireCode: .staleDocumentState
        case MonacoBridgeError.unknownDocument.wireCode: .unknownDocument
        case MonacoBridgeError.readOnly.wireCode: .readOnly
        case MonacoBridgeError.resynchronizing.wireCode: .resynchronizing
        case MonacoBridgeError.fileMissing.wireCode: .fileMissing
        case MonacoBridgeError.transportFailure.wireCode: .transportFailure
        default: nil
        }
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
    private var terminationTask: Task<Void, Never>?
    private var terminationTaskID: UUID?

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
            guard let dispatcher else { throw MonacoBridgeError.transportFailure }
            try await dispatcher.dispatch(object)
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
        guard (url.host ?? "").isEmpty,
              url.user?.isEmpty ?? true,
              url.password?.isEmpty ?? true,
              url.port == nil
        else { return false }
        let root = runtimeBundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target == root || target.hasPrefix(root + "/")
    }

    public func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        terminationTask?.cancel()
        terminationTask = nil
        terminationTaskID = nil
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
              !tornDown,
              terminationTask == nil,
              bridge.webContentGeneration < documentJavaScriptMaximum
        else { return }
        let bridge = bridge
        let generation = bridge.webContentGeneration + 1
        let taskID = UUID()
        terminationTaskID = taskID
        terminationTask = Task { @MainActor [weak self, weak webView, weak bridge] in
            defer { self?.finishTerminationTask(taskID) }
            guard let bridge else { return }
            do {
                try await bridge.prepareForWebContentRestart(
                    generation: generation
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  let webView,
                  webView === self.webView,
                  !self.tornDown
            else { return }
            self.loadRuntime()
        }
    }

    private func finishTerminationTask(_ taskID: UUID) {
        guard terminationTaskID == taskID else { return }
        terminationTask = nil
        terminationTaskID = nil
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
