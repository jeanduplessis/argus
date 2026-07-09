import Foundation

enum ArgusDiffHTMLTemplate {
    static let bundleResourceName = "pierre-diffs-bundle"
    static let bridgeHandlerName = "argusDiffBridge"

    static var html: String {
        let colorScheme = ChromeColors.colorScheme == .dark ? "dark" : "light"
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="argus-diff-bridge" content="argusDiffBridge">
          <style>
            @media (prefers-color-scheme: dark) {
              :root { color-scheme: dark; }
            }
            :root {
              color-scheme: \(colorScheme);
              --argus-monospace-font: ui-monospace, "SFMono-Regular", Menlo, Monaco, monospace;
              --argus-font-size: 12px;
              --argus-background: \(ChromeColors.backgroundCSS);
              --argus-foreground: \(ChromeColors.foregroundCSS);
            }
            html, body {
              width: 100%;
              height: 100%;
              margin: 0;
              overflow: hidden;
              color: var(--argus-foreground);
              background: var(--argus-background);
              font-family: var(--argus-monospace-font);
              font-size: var(--argus-font-size);
            }
            #diff {
              width: 100%;
              height: 100%;
              overflow: auto;
              color: inherit;
              background: inherit;
            }
          </style>
        </head>
        <body>
          <div id="diff"></div>
          <script src="pierre-diffs-bundle.js"></script>
        </body>
        </html>
        """
    }
}
