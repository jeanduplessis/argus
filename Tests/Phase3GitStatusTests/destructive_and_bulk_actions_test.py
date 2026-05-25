from pathlib import Path

view = Path("Argus/Views/GitSidebar/GitSidebarView.swift").read_text()

if "case discard" not in view or "case delete" not in view:
    raise SystemExit("FAIL: row action model should include discard and delete")

if 'case "unstaged":' not in view or '.discard' not in view:
    raise SystemExit("FAIL: unstaged rows should expose discard")

if 'case "untracked":' not in view or '.delete' not in view:
    raise SystemExit("FAIL: untracked rows should expose delete")

if "await confirmAndPerformFileOperation(action.operation, paths: [file.path])" not in view:
    raise SystemExit("FAIL: destructive row actions should require confirmation before execution")

if "sectionActions(title: String, count: Int)" not in view:
    raise SystemExit("FAIL: sections should derive section-level bulk actions from total section counts")

for expected in ["Stage All", "Unstage All", "Discard All", "Delete All"]:
    if expected not in view:
        raise SystemExit(f"FAIL: missing section-level action {expected}")

if "await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count)" not in view:
    raise SystemExit("FAIL: bulk section actions should use whole-section operation path")

if "files.map(\\.path)" in view:
    raise SystemExit("FAIL: bulk section actions must not be limited to capped displayed rows")
