from pathlib import Path

view = Path("Argus/Views/GitSidebar/GitSidebarView.swift").read_text()

if "case .notRepository(let rootPath):" not in view:
    raise SystemExit("FAIL: not-repository state should keep the root path for the initialize action")

if "notRepositoryContent(rootPath: rootPath" not in view:
    raise SystemExit("FAIL: not-repository state should render actionable content")

if 'Text("Initialize Repository")' not in view:
    raise SystemExit("FAIL: not-repository content should offer an Initialize Repository action")

if "await viewModel.initializeRepository(context: context)" not in view:
    raise SystemExit("FAIL: initialize action should call the view model through the resolved context")

if "case .repositoryInitializationFailed(let rootPath, let message):" not in view:
    raise SystemExit("FAIL: initialization failures should render a recoverable sidebar state")

if "notRepositoryContent(rootPath: rootPath, message: message" not in view:
    raise SystemExit("FAIL: initialization failure should preserve the initialize action and show the error message")
