import Foundation
import WebKit

@MainActor
final class ArgusDiffWebViewCoordinator: NSObject, WKScriptMessageHandler {
    typealias JavaScriptEvaluator = @MainActor (String) -> Void

    private var evaluateJavaScript: JavaScriptEvaluator?
    private var latestInput: ArgusDiffInput?
    private var pendingInput: ArgusDiffInput?
    private(set) var isReady = false
    var onError: ((String) -> Void)?

    init(evaluateJavaScript: JavaScriptEvaluator? = nil) {
        self.evaluateJavaScript = evaluateJavaScript
    }

    func attach(to webView: WKWebView) {
        evaluateJavaScript = { [weak webView, weak self] script in
            webView?.evaluateJavaScript(script) { _, error in
                if let error {
                    self?.onError?(error.localizedDescription)
                }
            }
        }
    }

    func update(input: ArgusDiffInput) {
        let previousInput = latestInput
        latestInput = input

        guard isReady else {
            pendingInput = input
            return
        }

        guard let previousInput,
              previousInput.oldFile == input.oldFile,
              previousInput.newFile == input.newFile else {
            render(input)
            return
        }

        if previousInput.options.theme != input.options.theme {
            evaluate("window.argusDiff.setTheme(\(javaScriptString(input.options.theme.rawValue)));")
        }
        if previousInput.options.style != input.options.style {
            evaluate("window.argusDiff.setStyle(\(javaScriptString(input.options.style.rawValue)));")
        }
        if previousInput.options.overflow != input.options.overflow {
            evaluate("window.argusDiff.setOverflow(\(javaScriptString(input.options.overflow.rawValue)));")
        }
    }

    func bridgeDidBecomeReady() {
        guard !isReady else { return }
        isReady = true
        if let pendingInput {
            self.pendingInput = nil
            render(pendingInput)
        }
    }

    func dismantle(webView: WKWebView) {
        evaluate("window.argusDiff?.cleanup();")
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: ArgusDiffHTMLTemplate.bridgeHandlerName)
        evaluateJavaScript = nil
        latestInput = nil
        pendingInput = nil
        isReady = false
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else { return }

            switch type {
            case "ready":
                bridgeDidBecomeReady()
            case "error":
                onError?(payload["message"] as? String ?? "Diff renderer failed")
            default:
                break
            }
        }
    }

    private func render(_ input: ArgusDiffInput) {
        do {
            let data = try JSONEncoder().encode(input)
            evaluate("window.argusDiff.render('\(data.base64EncodedString())');")
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func evaluate(_ script: String) {
        evaluateJavaScript?(script)
    }

    private func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}
