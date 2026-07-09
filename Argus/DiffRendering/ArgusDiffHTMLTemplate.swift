import Foundation

enum ArgusDiffHTMLTemplate {
    static let bundleResourceName = "pierre-diffs-bundle"
    static let bridgeHandlerName = "argusDiffBridge"

    static let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="argus-diff-bridge" content="argusDiffBridge">
          <style>
            :root {
              color-scheme: light dark;
              --argus-monospace-font: ui-monospace, "SFMono-Regular", Menlo, Monaco, monospace;
              --argus-font-size: 12px;
            }
            html, body {
              width: 100%;
              height: 100%;
              margin: 0;
              overflow: hidden;
              background: #ffffff;
              font-family: var(--argus-monospace-font);
              font-size: var(--argus-font-size);
            }
            #diff {
              width: 100%;
              height: 100%;
              overflow: auto;
            }
            ::-webkit-scrollbar { width: 12px; height: 12px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb {
              min-width: 28px;
              min-height: 28px;
              border: 3px solid transparent;
              border-radius: 8px;
              background: rgba(128, 128, 128, 0.45);
              background-clip: padding-box;
            }
            @media (prefers-color-scheme: dark) {
              html, body { background: #0d1117; }
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
