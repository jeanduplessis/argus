import AppKit
import Combine
import Foundation
import WebKit

enum BrowserFocusTarget: Equatable, Sendable {
    case addressField
    case webContent
}

struct BrowserFocusRequest: Equatable, Sendable {
    let generation: Int
    let target: BrowserFocusTarget
}

enum BrowserFindDirection: Sendable {
    case next
    case previous
}

/// Web view that rejects AppKit focus while its Browser Panel is in a background tab.
final class BrowserWKWebView: WKWebView {
    var allowsApplicationFocus = false

    override func becomeFirstResponder() -> Bool {
        guard allowsApplicationFocus else { return false }
        return super.becomeFirstResponder()
    }
}

/// Browser Panel model and owner of one stable WebKit browsing session.
@MainActor
final class BrowserPanel: NSObject, Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .browser
    let webView: BrowserWKWebView

    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var findRequestGeneration = 0
    @Published private(set) var findMatchCount = 0
    @Published private(set) var currentFindMatch = 0
    @Published private(set) var focusRequest = BrowserFocusRequest(
        generation: 0,
        target: .addressField
    )

    var pageZoom: Double {
        didSet {
            webView.pageZoom = pageZoom
        }
    }

    /// Enables WebKit's public inspectability setting. This does not represent
    /// developer-tools window visibility, which WebKit does not expose publicly.
    var developerToolsEnabled: Bool {
        didSet {
            webView.isInspectable = developerToolsEnabled
        }
    }

    private var isFocused = false
    private var isContentActive = false
    private var hasReceivedInitialFocus = false
    private var findQuery = ""
    private var findGeneration = 0

    var displayTitle: String {
        let trimmedTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let host = currentURL?.host, !host.isEmpty { return host }
        return "Browser"
    }

    var displayIcon: String? { "globe" }

    init(
        id: UUID = UUID(),
        currentURL: URL? = nil,
        pageZoom: Double = 1,
        developerToolsEnabled: Bool = false
    ) {
        let configuration = WKWebViewConfiguration()
        let webView = BrowserWKWebView(frame: .zero, configuration: configuration)

        self.id = id
        self.currentURL = currentURL
        self.pageZoom = pageZoom
        self.developerToolsEnabled = developerToolsEnabled
        self.webView = webView

        super.init()

        webView.navigationDelegate = self
        webView.pageZoom = pageZoom
        webView.isInspectable = developerToolsEnabled

        if let currentURL {
            webView.load(URLRequest(url: currentURL))
        }
    }
}

extension BrowserPanel {
    static func resolvedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let hasExplicitScheme =
            trimmed.contains("://")
            || ["about:", "data:", "file:", "mailto:"].contains(where: lowercased.hasPrefix)
        let candidate = hasExplicitScheme ? trimmed : "https://\(trimmed)"

        if let url = URL(string: candidate) {
            return url
        }
        return candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }

    @discardableResult
    func navigate(to input: String) -> Bool {
        guard let url = Self.resolvedURL(from: input) else { return false }
        navigate(to: url)
        return true
    }

    func navigate(to url: URL) {
        currentURL = url
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reload() {
        guard currentURL != nil, !isLoading else { return }
        webView.reload()
    }

    func requestFind() {
        findRequestGeneration &+= 1
    }

    func find(_ query: String, direction: BrowserFindDirection) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            clearFind()
            return
        }

        let isNewQuery = trimmedQuery != findQuery
        if isNewQuery {
            findQuery = trimmedQuery
            findMatchCount = 0
            currentFindMatch = 0
        }

        findGeneration &+= 1
        let generation = findGeneration
        let configuration = WKFindConfiguration()
        configuration.caseSensitive = false
        configuration.wraps = true
        configuration.backwards = direction == .previous

        webView.find(trimmedQuery, configuration: configuration) { [weak self] result in
            let matchFound = result.matchFound
            Task { @MainActor [weak self] in
                self?.updateFindCounts(
                    query: trimmedQuery,
                    direction: direction,
                    isNewQuery: isNewQuery,
                    matchFound: matchFound,
                    generation: generation
                )
            }
        }
    }

    func clearFind() {
        findQuery = ""
        findGeneration &+= 1
        findMatchCount = 0
        currentFindMatch = 0

        let configuration = WKFindConfiguration()
        webView.find("", configuration: configuration) { _ in }
    }

    func focus() {
        isFocused = true
        webView.allowsApplicationFocus = true
        focusRequest = BrowserFocusRequest(
            generation: focusRequest.generation &+ 1,
            target: hasReceivedInitialFocus ? .webContent : .addressField
        )
        hasReceivedInitialFocus = true
    }

    func unfocus() {
        isFocused = false
        isContentActive = false
        webView.allowsApplicationFocus = false

        guard let window = webView.window,
            let firstResponder = window.firstResponder as? NSView,
            firstResponder == webView || firstResponder.isDescendant(of: webView)
        else { return }
        window.makeFirstResponder(nil)
    }

    func focusWebContent() {
        guard isFocused || isContentActive else { return }
        webView.allowsApplicationFocus = true
        webView.window?.makeFirstResponder(webView)
    }

    func setWebContentActive(_ isActive: Bool) {
        isContentActive = isActive
        webView.allowsApplicationFocus = isActive
    }

    func close() {
        unfocus()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private func synchronizeNavigationState() {
        currentURL = webView.url ?? currentURL
        pageTitle = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }

    private func updateFindCounts(
        query: String,
        direction: BrowserFindDirection,
        isNewQuery: Bool,
        matchFound: Bool,
        generation: Int
    ) {
        guard generation == findGeneration else { return }
        guard matchFound else {
            findMatchCount = 0
            currentFindMatch = 0
            return
        }

        countMatches(for: query) { [weak self] count in
            guard let self, generation == self.findGeneration else { return }
            self.findMatchCount = count
            guard count > 0 else {
                self.currentFindMatch = 0
                return
            }

            if isNewQuery || self.currentFindMatch == 0 {
                self.currentFindMatch = direction == .previous ? count : 1
            } else if direction == .previous {
                self.currentFindMatch =
                    self.currentFindMatch == 1
                    ? count
                    : self.currentFindMatch - 1
            } else {
                self.currentFindMatch =
                    self.currentFindMatch == count
                    ? 1
                    : self.currentFindMatch + 1
            }
        }
    }

    /// WebKit's public find result reports whether a match exists but not its
    /// ordinal or total. JavaScript is limited to counting document text;
    /// selection and next/previous navigation continue to use `WKWebView.find`.
    private func countMatches(for query: String, completion: @escaping @MainActor (Int) -> Void) {
        guard let encoded = try? JSONEncoder().encode(query),
            let queryLiteral = String(data: encoded, encoding: .utf8)
        else {
            completion(0)
            return
        }

        let script = """
            (() => {
              const needle = \(queryLiteral).toLocaleLowerCase();
              if (!needle || !document.body) return 0;
              const walker = document.createTreeWalker(
                document.body,
                NodeFilter.SHOW_TEXT,
                {
                  acceptNode(node) {
                    const parent = node.parentElement;
                    if (!parent || ['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(parent.tagName)) {
                      return NodeFilter.FILTER_REJECT;
                    }
                    return NodeFilter.FILTER_ACCEPT;
                  }
                }
              );
              let count = 0;
              let node;
              while ((node = walker.nextNode())) {
                const text = (node.nodeValue || '').toLocaleLowerCase();
                let offset = 0;
                while ((offset = text.indexOf(needle, offset)) !== -1) {
                  count += 1;
                  offset += Math.max(needle.length, 1);
                }
              }
              return count;
            })();
            """

        webView.evaluateJavaScript(script) { value, _ in
            let count = (value as? NSNumber)?.intValue ?? 0
            Task { @MainActor in completion(count) }
        }
    }
}

extension BrowserPanel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.isLoading = true
            self?.synchronizeNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.synchronizeNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.synchronizeNavigationState()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.synchronizeNavigationState()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.synchronizeNavigationState()
        }
    }
}
