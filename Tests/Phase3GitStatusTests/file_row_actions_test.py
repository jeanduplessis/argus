from pathlib import Path

view = Path("Argus/Views/GitSidebar/GitSidebarView.swift").read_text()

if "fileActions(for file: GitFileChange)" not in view:
    raise SystemExit("FAIL: file rows should derive section-aware actions")

if 'case "staged":' not in view or '.unstage' not in view:
    raise SystemExit("FAIL: staged rows should expose an unstage action")

if 'case "unstaged":' not in view or 'case "untracked":' not in view or '.stage' not in view:
    raise SystemExit("FAIL: unstaged and untracked rows should expose a stage action")

if '.copyPath' not in view:
    raise SystemExit("FAIL: every file row should expose a copy-path action")

if 'await performFileOperation(action.operation, path: file.path)' not in view:
    raise SystemExit("FAIL: stage/unstage row actions should invoke async file operations")

if 'viewModel.copyPath(file.path)' not in view:
    raise SystemExit("FAIL: copy-path row action should copy the displayed file path")

if 'case .fileOperationFailed(_, let message):' not in view:
    raise SystemExit("FAIL: file operation failures should surface as recoverable UI state")
