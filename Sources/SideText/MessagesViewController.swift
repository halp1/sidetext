import AppKit
import Network
import WebKit

/// Hosts Google Messages for Web in a WKWebView and bridges it to native features.
final class MessagesViewController: NSViewController {
    static let messagesHost = "messages.google.com"
    static let conversationsURL = URL(string: "https://messages.google.com/web/conversations")!

    private(set) var webView: WKWebView!
    private let statusView = StatusOverlay()
    private var pathMonitor: NWPathMonitor?
    private var isNetworkReachable = true
    private var crashRetries = 0
    private var urlObservation: NSKeyValueObservation?
    private var lastURL: URL?
    private var conversationsReady = false
    private var scrollbarApplied: Prefs.ScrollBarStyle?

    // Reply queue: replies wait until the conversation list is ready.
    private struct PendingReply { let text: String; let message: IncomingMessage }
    private var pendingReplies: [PendingReply] = []
    private var activeReply: PendingReply?
    private var replyTimeout: DispatchWorkItem?
    private var pendingReadMessages: [IncomingMessage] = []
    private var markingRead = false

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }
        let controller = WKUserContentController()
        let handler = WeakScriptHandler(self)
        for name in [WebScripts.notifyHandler, WebScripts.ajaxHandler, WebScripts.consoleHandler,
                     WebScripts.loadedHandler, WebScripts.sendButtonHandler, WebScripts.unreadHandler] {
            controller.add(handler, name: name)
        }
        for source in [WebScripts.consoleRedirect, WebScripts.helper] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for source in [WebScripts.emojiCSS, WebScripts.spellcheck, WebScripts.conversationsLoaded, WebScripts.scrollbar] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        config.userContentController = controller

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.pageZoom = Prefs.zoomFactor
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        statusView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        container.addSubview(statusView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusView.topAnchor.constraint(equalTo: container.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        statusView.onRetry = { [weak self] in self?.reload(clearCache: false) }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            self?.urlChanged()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        startNetworkMonitor()
        statusView.show(.loading)
        webView.load(URLRequest(url: Self.conversationsURL))
    }

    // MARK: Public actions

    func reload(clearCache: Bool) {
        Log.info("Reloading Messages (clearCache=\(clearCache))", category: "Web")
        conversationsReady = false
        statusView.show(.loading)
        if clearCache {
            let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                      WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeServiceWorkerRegistrations]
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
                self?.webView.load(URLRequest(url: Self.conversationsURL))
            }
        } else if webView.url == nil || webView.url?.host != Self.messagesHost {
            webView.load(URLRequest(url: Self.conversationsURL))
        } else {
            webView.reloadFromOrigin()
        }
    }

    func startNewMessage() {
        webView.evaluateJavaScript(WebScripts.startNewMessage) { [weak self] result, _ in
            if (result as? Bool) != true {
                self?.webView.load(URLRequest(url: URL(string: "https://messages.google.com/web/conversations/new")!))
            }
        }
    }

    func zoom(by delta: Double?) {
        if let delta {
            Prefs.zoomFactor = (Prefs.zoomFactor + delta).rounded(toPlaces: 2)
        } else {
            Prefs.zoomFactor = 1.0
        }
        webView.pageZoom = Prefs.zoomFactor
    }

    func open(message: IncomingMessage, completion: ((String?) -> Void)? = nil) {
        if let cid = message.conversationID, !cid.isEmpty, webView.url?.host == Self.messagesHost {
            // Direct navigation within the SPA is the most reliable way to reach a thread.
            let js = WebScripts.selectConversation(cid: cid, name: message.senderName, phone: message.senderPhone, snippet: message.body)
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                if let found = result as? String {
                    completion?(found)
                } else {
                    self?.webView.load(URLRequest(url: Self.conversationsURL.appendingPathComponent(cid)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { completion?(cid) }
                }
            }
            return
        }
        let js = WebScripts.selectConversation(cid: nil, name: message.senderName, phone: message.senderPhone, snippet: message.body)
        webView.evaluateJavaScript(js) { result, _ in completion?(result as? String) }
    }

    // MARK: Automatically handled codes

    private func queueMarkRead(_ message: IncomingMessage) {
        if !pendingReadMessages.contains(message) { pendingReadMessages.append(message) }
        processNextRead()
    }

    private func processNextRead() {
        guard !markingRead, activeReply == nil, pendingReplies.isEmpty,
              conversationsReady, !pendingReadMessages.isEmpty else { return }
        let message = pendingReadMessages.removeFirst()
        let cid = message.trustedConversationID ?? ""
        markingRead = true
        webView.callAsyncJavaScript(WebScripts.markConversationRead(cid: cid, body: message.body,
                                                                   senderName: message.senderName ?? message.title,
                                                                   phone: message.senderPhone),
                                    arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.markingRead = false
            switch result {
            case .success(let value):
                Log.info("Auto-copied code read action: \(value)", category: "OTP")
            case .failure:
                Log.error("Could not mark code conversation read", category: "OTP")
            }
            self.processNextReply()
            self.processNextRead()
        }
    }

    // MARK: Replies

    func queueReply(_ text: String, to message: IncomingMessage) {
        pendingReplies.append(PendingReply(text: text, message: message))
        Log.info("Reply queued (\(pendingReplies.count) pending)", category: "Reply")
        processNextReply()
    }

    private func processNextReply() {
        guard activeReply == nil, !markingRead, conversationsReady, !pendingReplies.isEmpty else { return }
        let reply = pendingReplies.removeFirst()
        activeReply = reply
        let timeout = DispatchWorkItem { [weak self] in self?.finishReply(success: false, reason: "timed out") }
        replyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

        open(message: reply.message) { [weak self] cid in
            guard let self, self.activeReply != nil else { return }
            if cid == nil {
                self.finishReply(success: false, reason: "conversation not found")
                return
            }
            self.waitForComposer(attempts: 0) { found in
                guard found else { self.finishReply(success: false, reason: "composer not found"); return }
                self.webView.evaluateJavaScript(WebScripts.fillReply(reply.text)) { result, _ in
                    if (result as? String) != "filled" { self.finishReply(success: false, reason: "composer not found") }
                    // Otherwise wait for the sendButtonLocation message.
                }
            }
        }
    }

    private func waitForComposer(attempts: Int, completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript(WebScripts.composerState) { [weak self] result, _ in
            if (result as? String) != "missing" { completion(true); return }
            guard attempts < 30 else { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.waitForComposer(attempts: attempts + 1, completion: completion) }
        }
    }

    private func clickSendButton(at cssPoint: CGPoint) {
        // Convert CSS pixels to view coordinates (WKWebView is flipped), then to window coordinates.
        let zoom = webView.pageZoom
        let viewPoint = NSPoint(x: cssPoint.x * zoom, y: cssPoint.y * zoom)
        var clicked = false
        if let window = webView.window {
            let windowPoint = webView.convert(viewPoint, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                    clicked = true
                }
            }
        }
        Log.info("Send click dispatched (native=\(clicked)) at page zoom \(zoom)", category: "Reply")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.confirmSent(retry: true) }
    }

    private func confirmSent(retry: Bool) {
        webView.evaluateJavaScript(WebScripts.composerState) { [weak self] result, _ in
            guard let self else { return }
            if (result as? String) == "cleared" {
                self.finishReply(success: true, reason: nil)
            } else if retry {
                self.webView.evaluateJavaScript(WebScripts.domClickSend) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.confirmSent(retry: false) }
                }
            } else {
                self.finishReply(success: false, reason: "send not confirmed")
            }
        }
    }

    private func finishReply(success: Bool, reason: String?) {
        guard let reply = activeReply else { return }
        replyTimeout?.cancel()
        activeReply = nil
        if success {
            Log.info("Reply accepted by Google Messages", category: "Reply")
            if Prefs.showWindowAfterReply { AppDelegate.shared?.showMainWindow() }
        } else {
            Log.error("Reply failed: \(reason ?? "unknown")", category: "Reply")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(reply.text, forType: .string)
            AppDelegate.shared?.showMainWindow()
            let alert = NSAlert()
            alert.messageText = "Message Not Sent"
            alert.informativeText = "There was a problem sending the reply from the notification. The message has been copied to the clipboard and can be pasted into the conversation."
            alert.runModal()
        }
        processNextReply()
        processNextRead()
    }

    // MARK: State

    private func urlChanged() {
        guard let url = webView.url, url != lastURL else { return }
        lastURL = url
        let path = url.path
        if url.host == Self.messagesHost {
            if path.hasPrefix("/web/settings") {
                webView.evaluateJavaScript(WebScripts.settingsPage)
            } else if path.hasPrefix("/web/authentication") {
                webView.evaluateJavaScript(WebScripts.authPage)
            } else if path.hasPrefix("/web/unableToConnect") {
                webView.evaluateJavaScript(WebScripts.hideFeedbackLink)
            }
            if !path.contains("conversations") { conversationsReady = false }
        } else if url.host == "accounts.google.com" {
            webView.evaluateJavaScript(WebScripts.passkeyHint(
                title: "Passkeys aren't supported here",
                message: "Select \u{201C}Try another way\u{201D}, then choose a sign-in option other than passkeys."))
        }
    }

    private func applyScrollbarStyle(force: Bool = false) {
        let style = Prefs.scrollBarStyle
        guard force || style != scrollbarApplied else { return }
        let previous = scrollbarApplied
        scrollbarApplied = style
        // Only call into the page for "system", or when switching back to "google" at runtime.
        if style == .system || previous == .system {
            webView.evaluateJavaScript("window.SideText && window.SideText.setScrollbarMode('\(style == .system ? "system" : "google")');")
        }
    }

    @objc private func prefsChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if abs(self.webView.pageZoom - Prefs.zoomFactor) > 0.001 { self.webView.pageZoom = Prefs.zoomFactor }
            self.applyScrollbarStyle()
            DockManager.shared.refresh()
        }
    }

    @objc private func didWake() {
        Log.info("System wake detected; refreshing", category: "Web")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isNetworkReachable else { return }
            self.webView.evaluateJavaScript("document.readyState") { result, error in
                if error != nil || result == nil { self.reload(clearCache: false) }
            }
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let reachable = path.status == .satisfied
                let changed = reachable != self.isNetworkReachable
                self.isNetworkReachable = reachable
                guard changed else { return }
                Log.info("Network \(reachable ? "restored" : "lost")", category: "Network")
                if reachable {
                    self.reload(clearCache: false)
                } else {
                    self.statusView.show(.offline)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "SideText.network"))
        pathMonitor = monitor
    }
}

// MARK: - Script messages

extension MessagesViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case WebScripts.notifyHandler:
            guard let incoming = IncomingMessage.parse(message.body) else {
                Log.error("Notification payload could not be parsed", category: "Notifications")
                return
            }
            Log.info("New message received", category: "Notifications")
            // Handle codes before every alert path, including foreground sound and Dock bounce.
            if NotificationManager.shared.autoCopyOTP(in: incoming) {
                queueMarkRead(incoming)
                return
            }
            DockManager.shared.messageArrived()
            if !NSApp.isActive || !(view.window?.isVisible ?? false) {
                NotificationManager.shared.post(message: incoming)
            } else {
                if Prefs.playSound { SoundCatalog.play(Prefs.soundName) }
            }
        case WebScripts.ajaxHandler:
            guard let body = message.body as? [String: Any] else { return }
            if let current = body["currentURL"] as? String, current.contains("/conversations"),
               (body["inputBoxExists"] as? Bool == true || body["newMessageButtonExists"] as? Bool == true) {
                markConversationsReady()
            }
        case WebScripts.loadedHandler:
            markConversationsReady()
        case WebScripts.sendButtonHandler:
            guard activeReply != nil, let body = message.body as? [String: Any] else { return }
            if body["error"] != nil {
                finishReply(success: false, reason: "send button never enabled")
            } else if let x = body["x"] as? Double, let y = body["y"] as? Double {
                clickSendButton(at: CGPoint(x: x, y: y))
            }
        case WebScripts.unreadHandler:
            if let body = message.body as? [String: Any], let count = body["count"] as? Int,
               (body["rows"] as? Int ?? 0) > 0 {
                DockManager.shared.setPageUnread(count)
            }
        case WebScripts.consoleHandler:
            if let body = message.body as? [String: Any] {
                Log.info("\(body["type"] as? String ?? "log"): \(body["message"].map { "\($0)" } ?? "")", category: "Page")
            }
        default:
            break
        }
    }

    private func markConversationsReady() {
        if !conversationsReady {
            conversationsReady = true
            crashRetries = 0
            statusView.show(nil)
            Log.info("Conversations loaded", category: "Web")
            applyScrollbarStyle(force: true)
        }
        processNextReply()
        processNextRead()
    }
}

// MARK: - Navigation, downloads, UI delegate

extension MessagesViewController: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private static let allowedHostSuffixes = ["google.com", "gstatic.com", "googleusercontent.com", "googleapis.com", "youtube.com"]

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        let scheme = url.scheme ?? ""
        if ["about", "blob", "data"].contains(scheme) { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        let host = url.host ?? ""
        let isGoogle = Self.allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        let isHelpOrFeedback = host == "support.google.com" || url.absoluteString.hasPrefix("https://www.google.com/tools/feedback")
        if isGoogle && !isHelpOrFeedback {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType { decisionHandler(.download) } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        webView.evaluateJavaScript(WebScripts.downloadFilename) { result, _ in
            var name = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty { name = suggestedFilename }
            name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let folder = Prefs.downloadFolder
            let access = BookmarkStore.startAccessingDownloadFolder()
            defer { if access { BookmarkStore.stopAccessingDownloadFolder() } }
            completionHandler(Self.uniqueURL(in: folder, name: name))
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        Log.info("Download finished", category: "Downloads")
        Toast.show("File downloaded", subtitle: "Saved to \(Prefs.downloadFolder.lastPathComponent)")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Prefs.downloadFolder.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Log.error("Download failed: \(error.localizedDescription)", category: "Downloads")
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !conversationsReady { statusView.show(.loading) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.info("Navigation finished: \(webView.url?.absoluteString ?? "-")", category: "Web")
        if webView.url?.host != Self.messagesHost || !(webView.url?.path.contains("conversations") ?? false) {
            // Sign-in, pairing, and settings pages have no conversation list; show them directly.
            statusView.show(nil)
        }
        urlChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.statusView.state == .loading { self?.statusView.show(nil) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted (downloads)
        Log.error("Navigation error: \(error.localizedDescription)", category: "Web")
        statusView.show(isNetworkReachable ? .cannotConnect : .offline)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashRetries += 1
        Log.error("Web content process terminated (attempt \(crashRetries))", category: "Web")
        guard crashRetries <= 5 else { statusView.show(.cannotConnect); return }
        let delay = min(pow(2.0, Double(crashRetries - 1)), 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reload(clearCache: self?.crashRetries ?? 0 > 2) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.host == Self.messagesHost {
                webView.load(navigationAction.request)
            } else if url.scheme != "about" {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: view.window!) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: view.window!) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: view.window!) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == Self.messagesHost ? .grant : .deny)
    }
}

/// Avoids a retain cycle between WKUserContentController and the controller.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// Loading / offline / cannot-connect overlay.
final class StatusOverlay: NSView {
    enum State { case loading, offline, cannotConnect }
    private(set) var state: State?
    var onRetry: (() -> Void)?
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        spinner.style = .spinning
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor
        retry.target = self
        retry.action = #selector(retryTapped)
        let stack = NSStackView(views: [spinner, title, detail, retry])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }

    func show(_ newState: State?) {
        state = newState
        isHidden = newState == nil
        switch newState {
        case .loading:
            spinner.isHidden = false; spinner.startAnimation(nil)
            title.stringValue = "Loading Messages…"; detail.stringValue = ""; retry.isHidden = true
        case .offline:
            spinner.isHidden = true; spinner.stopAnimation(nil)
            title.stringValue = "You're Offline"
            detail.stringValue = "Messages will reload automatically when your Mac reconnects to the internet."
            retry.isHidden = false
        case .cannotConnect:
            spinner.isHidden = true; spinner.stopAnimation(nil)
            title.stringValue = "Can't Connect to Google Messages"
            detail.stringValue = "Check your connection and try again."
            retry.isHidden = false
        case nil:
            spinner.stopAnimation(nil)
        }
    }

    @objc private func retryTapped() { onRetry?() }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10.0, Double(p))
        return (self * m).rounded() / m
    }
}
