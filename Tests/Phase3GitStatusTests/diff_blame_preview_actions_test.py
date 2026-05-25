from pathlib import Path

view = Path("Argus/Views/GitSidebar/GitSidebarView.swift").read_text()
panel = Path("Argus/Views/GitSidebar/GitPreviewPanel.swift").read_text()
service = Path("Argus/Services/GitPreviewService.swift").read_text()

if "case diff" not in view or "case blame" not in view:
    raise SystemExit("FAIL: row action model should include diff and blame preview actions")

if 'case "staged":' not in view or '.diff' not in view or '.blame' not in view:
    raise SystemExit("FAIL: staged rows should expose diff and blame preview actions")

if 'case "unstaged":' not in view or '.diff' not in view or '.blame' not in view:
    raise SystemExit("FAIL: unstaged rows should expose diff and blame preview actions")

if 'case "untracked":' not in view or '.diff' not in view:
    raise SystemExit("FAIL: untracked rows should expose diff preview actions")

untracked_block = view.split('case "untracked":', 1)[1].split('default:', 1)[0]
if '.blame' in untracked_block:
    raise SystemExit("FAIL: untracked rows should not expose blame")

if "await showPreview(kind: .diff, file: file)" not in view or "await showPreview(kind: .blame, file: file)" not in view:
    raise SystemExit("FAIL: diff/blame actions should request previews through the view model path")

if "EscapeClosingGitPreviewPanel" not in panel or "event.keyCode == 53" not in panel:
    raise SystemExit("FAIL: preview panel should close on Escape")

if 'Button("Close"' not in panel or '.keyboardShortcut(.cancelAction)' not in panel:
    raise SystemExit("FAIL: preview panel should include a close button with Escape shortcut")

if "diff.external=" not in service or "--no-ext-diff" not in service:
    raise SystemExit("FAIL: diff command should use difftastic when available and disable external diff for fallback")
