from pathlib import Path

project = Path("Argus.xcodeproj/project.pbxproj").read_text()
panel = Path("Argus/Views/GitSidebar/GitPreviewPanel.swift").read_text()
view_model = Path("Argus/Views/GitSidebar/GitStatusViewModel.swift").read_text()

for source in ["GitPreviewService.swift", "GitPreviewPanel.swift"]:
    if f"/* {source} in Sources */" not in project:
        raise SystemExit(f"FAIL: {source} should be compiled by the Argus app target")

if "private let previewService: any GitPreviewProviding" not in view_model:
    raise SystemExit("FAIL: GitStatusViewModel should resolve GitPreviewProviding from app-target sources")

if "private let previewPresenter: any GitPreviewPresenting" not in view_model:
    raise SystemExit("FAIL: GitStatusViewModel should resolve GitPreviewPresenting from app-target sources")

if "@MainActor\nprotocol GitPreviewPanelClosing" not in panel:
    raise SystemExit("FAIL: GitPreviewPanelClosing should be main-actor isolated for NSPanel.close conformance")

if "extension NSPanel: GitPreviewPanelClosing" not in panel:
    raise SystemExit("FAIL: NSPanel should conform to the close protocol used by preview panel controller")
