# Diff Rendering Plan

## Status

Implemented on 2026-07-09.

## Goal

Use `@pierre/diffs` for Argus diff previews without depending on the
`PierreDiffsSwift` package. Argus should own the Swift API, the WebKit bridge,
the JavaScript bundle, and the git content extraction logic.

This must preserve the application spec:

- The right git sidebar offers diff actions for staged, unstaged, and untracked
  files.
- Diff previews open as center-column workspace tabs with colorized output.
- Blame previews use the same center-column tab lifecycle.
- Reopening the same repository, preview kind, and path refreshes its existing
  tab.

## Non-Goals

- Do not add a dependency on `PierreDiffsSwift`.
- Do not route preview rendering through React.
- Do not require npm, Node, or network access at app runtime.
- Do not replace the git status sidebar, file operations, diff stats, or blame
  preview pipeline.
- Do not add review comments, inline annotations, edit-tool abstractions, or
  multi-file review flows in the first pass.
- Do not use libgit2. All git data still comes from the `git` CLI.

## Architecture

Add a small Argus-owned diff renderer:

```text
Argus/
  DiffRendering/
    ArgusDiffInput.swift
    ArgusDiffView.swift
    ArgusDiffWebViewCoordinator.swift
    ArgusDiffHTMLTemplate.swift
  Resources/
    pierre-diffs-bundle.js

ArgusWeb/
  package.json
  package-lock.json
  src/
    pierre-diffs-entry.js

scripts/
  build-pierre-diffs.mjs
```

`ArgusWeb` is only a build-time asset package. The Xcode app target copies the
generated `Argus/Resources/pierre-diffs-bundle.js` into the app bundle.

The Swift side should expose Argus types, not PierreDiffsSwift types:

```swift
struct ArgusDiffInput: Codable, Sendable, Equatable {
    let oldFile: ArgusDiffFile
    let newFile: ArgusDiffFile
    let options: ArgusDiffOptions
}

struct ArgusDiffFile: Codable, Sendable, Equatable {
    let name: String
    let contents: String
    let language: String?
}

struct ArgusDiffOptions: Codable, Sendable, Equatable {
    let theme: ArgusDiffTheme
    let style: ArgusDiffStyle
    let overflow: ArgusDiffOverflow
}

enum ArgusDiffStyle: String, Codable, Sendable {
    case split
    case unified
}

enum ArgusDiffOverflow: String, Codable, Sendable {
    case scroll
    case wrap
}
```

Keep the first API intentionally narrow. Add more renderer options only when the
Argus UI needs them.

## JavaScript Bundle

Pin `@pierre/diffs` in `ArgusWeb/package.json` and bundle a single browser entry
with esbuild. The entry should import the vanilla API:

```js
import { FileDiff } from "@pierre/diffs";
```

The entry exposes a tiny bridge:

```js
window.argusDiff = {
  render(input) {},
  setTheme(theme) {},
  setStyle(style) {},
  setOverflow(overflow) {},
  cleanup() {},
};
```

The bridge posts WebKit messages through one handler name:

```js
window.webkit.messageHandlers.argusDiffBridge.postMessage({
  type: "ready" | "error",
  message: "...",
});
```

The bundle should be an IIFE so the local HTML template can load it directly
without module resolution. The generated file should be committed so normal
Xcode builds do not require Node.

## Swift WebKit Renderer

`ArgusDiffView` should be an `NSViewRepresentable` over `WKWebView`.

Responsibilities:

- Load HTML from `ArgusDiffHTMLTemplate`.
- Embed the generated `pierre-diffs-bundle.js` from `Bundle.main`.
- Register `argusDiffBridge` on `WKUserContentController`.
- Base64-encode JSON input before evaluating JavaScript.
- Render once the bridge reports readiness.
- Update theme/style/overflow without rebuilding the entire web view when
  possible.
- Remove script handlers and stop loading in `dismantleNSView`.

The HTML template should be local and self-contained. It should define the
scrolling container, base font variables, light/dark background behavior, and
macOS-like scrollbar styling.

## Git Preview Data Model

`GitPreviewService` currently returns a raw text `output` for both diff and
blame previews. Split preview content into explicit cases:

```swift
enum GitPreviewContent: Equatable, Sendable {
    case diff(GitDiffPreview)
    case ansiText(String)
}

struct GitDiffPreview: Equatable, Sendable {
    let fileName: String
    let oldContent: String
    let newContent: String
}

struct GitPreview: Equatable, Sendable {
    let kind: GitPreviewKind
    let path: String
    let content: GitPreviewContent
}
```

Blame previews keep using ANSI text. Diff previews use `GitDiffPreview`.

Once diffs render through Pierre, the `difftasticPathProvider` branch should be
removed from the diff path. Difftastic produces terminal-oriented output, while
Pierre needs structured old/new text.

## Git Content Extraction

Add a small helper inside the preview service, or a separate
`GitDiffContentLoader`, that resolves the two text sides for a single
`GitFileChange`.

Use git object reads for committed/index content and safe filesystem reads for
working-tree content. All commands must use `Process` arguments, never shell
string interpolation.

| Row | Old content | New content |
| --- | --- | --- |
| Staged modified | `HEAD:<path>` | `:<path>` |
| Staged added | empty | `:<path>` |
| Staged deleted | `HEAD:<path>` | empty |
| Staged renamed | `HEAD:<originalPath>` | `:<path>` |
| Unstaged modified | `:<path>` | working tree `<path>` |
| Unstaged deleted | `:<path>` | empty |
| Unstaged renamed | `:<originalPath>` when available | working tree `<path>` |
| Untracked | empty | working tree `<path>` |

Fallback rules:

- If a git object side does not exist because the file is added or deleted,
  treat that side as empty.
- If a working-tree path escapes the repository root after standardization,
  fail the preview.
- If either side is binary or not UTF-8, return a recoverable text preview such
  as "Binary file differs" instead of trying to render Pierre.
- If a git command fails for an unexpected reason, preserve the existing
  recoverable failure behavior.

## Tab Integration

Model each preview as a runtime-only `GitPreviewPanel` in the active workspace.
The existing tab bar owns selection, reordering, and closing.

Its content selection remains:

- `.diff` content renders `ArgusDiffView`.
- `.ansiText` content renders the existing `GitPreviewANSITextView`.
- Failure messages render through the existing text path.

Add lightweight controls in the tab content header only after the basic renderer is
working:

- Split / Unified segmented control.
- Scroll / Wrap segmented control.

Persisting these controls is optional for the first pass.

## Build Integration

Update `project.yml` so Xcode copies `Argus/Resources/pierre-diffs-bundle.js`
into the Argus app bundle. Regenerate `Argus.xcodeproj` using the repo's normal
XcodeGen workflow if needed.

Add a build helper:

```sh
npm ci --prefix ArgusWeb
npm run build --prefix ArgusWeb
```

The npm build should write only `Argus/Resources/pierre-diffs-bundle.js`.

`scripts/build.sh` may call the bundle build before release packaging, but day
to day Xcode builds should work from the committed generated bundle.

## Implementation Order

1. Add `ArgusWeb`, the esbuild script, the JavaScript bridge, and the generated
   bundle resource.
2. Add `ArgusDiffInput`, `ArgusDiffHTMLTemplate`, `ArgusDiffWebViewCoordinator`,
   and `ArgusDiffView`.
3. Update `GitPreview` to distinguish Pierre diff content from ANSI text.
4. Replace the diff command path with old/new content extraction.
5. Add runtime-only `GitPreviewPanel` tabs that render diff content with
   `ArgusDiffView` and keep blame/failure content on the ANSI text path.
6. Remove obsolete difftastic command selection from diff preview tests.
7. Add focused tests for git content extraction and renderer wiring.
8. Run the focused preview tests, then the full repo validation.

## Tests

Service tests:

- Staged modified file resolves `HEAD` as old content and index as new content.
- Staged added file resolves empty old content and index new content.
- Staged deleted file resolves `HEAD` old content and empty new content.
- Staged renamed file uses `originalPath` for old content and `path` for new
  content.
- Unstaged modified file resolves index old content and working-tree new
  content.
- Unstaged deleted file resolves index old content and empty new content.
- Untracked file resolves empty old content and working-tree new content.
- Binary or non-UTF-8 content returns a recoverable text preview or failure.
- Blame previews still return colorized ANSI text.
- Untracked rows still do not expose blame previews.

Renderer tests:

- `ArgusDiffInput` encodes the expected JSON shape.
- The HTML template includes `pierre-diffs-bundle.js` and the
  `argusDiffBridge` handler name.
- The coordinator queues render work until the bridge is ready.
- Dismantling removes script message handlers.

Tab tests:

- Preview tabs use the generic workspace tab lifecycle.
- Reopening the same preview updates and selects its existing tab.
- Diff content selects `ArgusDiffView`.
- Blame and failure content select the ANSI text view.

Validation commands:

```sh
xcodebuild test \
  -project Argus.xcodeproj \
  -scheme Argus \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ArgusTests/GitPreviewServiceTests

./scripts/test.sh
git diff --check
```

## Risks

The main risk is git content extraction, not WebKit. The renderer needs the
correct old/new text for each status state. Handle that with targeted tests
before polishing UI controls.

The second risk is bundle churn. Keep npm dependencies pinned and make the
bundle script deterministic so changes to `pierre-diffs-bundle.js` are
intentional and reviewable.

The third risk is large files. Pierre syntax highlighting can be expensive. Add
size and line-length thresholds before rendering, and fall back to a text
preview when a file is too large for interactive rendering.

## References

- `@pierre/diffs`: https://www.npmjs.com/package/@pierre/diffs
- Swift reference project: https://github.com/jamesrochabrun/PierreDiffsSwift
