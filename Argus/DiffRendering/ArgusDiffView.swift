import SwiftUI
import WebKit

struct ArgusDiffView: NSViewRepresentable {
    let input: ArgusDiffInput
    var onError: (String) -> Void = { _ in }

    func makeCoordinator() -> ArgusDiffWebViewCoordinator {
        let coordinator = ArgusDiffWebViewCoordinator()
        coordinator.onError = onError
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(
            context.coordinator,
            name: ArgusDiffHTMLTemplate.bridgeHandlerName
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        context.coordinator.attach(to: webView)
        webView.loadHTMLString(
            ArgusDiffHTMLTemplate.html,
            baseURL: Bundle.main.resourceURL
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.update(input: input)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: ArgusDiffWebViewCoordinator) {
        coordinator.dismantle(webView: webView)
    }
}
