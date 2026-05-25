#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

# Behavior: v1 exposes one unique SwiftUI main window, not a multi-window WindowGroup.
assert_contains Argus/App/ArgusApp.swift 'Window("Argus", id: "main")'
assert_not_contains Argus/App/ArgusApp.swift 'WindowGroup'

# Behavior: custom titlebar is mounted in the main window and shares formatter output.
assert_contains Argus/Views/MainWindowView.swift 'TitlebarView()'
assert_contains Argus/Views/Titlebar/TitlebarView.swift 'workspaceManager.activeWorkspaceTitle'

# Behavior: macOS window title is synchronized from the same workspace context.
assert_contains Argus/App/AppDelegate.swift 'workspaceManager?.activeWorkspaceTitle'
assert_contains Argus/Services/WorkspaceManager.swift '.workspaceContextDidChange'
assert_contains Argus/App/ArgusApp.swift 'appDelegate.updateWindowTitle()'

# Behavior: tabs expose drag/drop reordering without recreating panels.
assert_contains Argus/Views/Content/TabBarView.swift 'PanelTabDropDelegate'
assert_contains Argus/Views/Content/TabBarView.swift '.onDrag'
assert_contains Argus/Views/Content/TabBarView.swift '.onDrop'
assert_contains Argus/Models/Workspace.swift 'destination <= panelOrder.count'

# Behavior: sidebar workspaces expose project-scoped drag/drop reordering.
assert_contains Argus/Views/Sidebar/SidebarView.swift 'SidebarWorkspaceDropDelegate'
assert_contains Argus/Services/WorkspaceManager.swift 'reorderWorkspace(in projectId: UUID'
assert_contains Argus/Services/WorkspaceManager.swift 'project.moveWorkspace'
assert_contains Argus/Views/Sidebar/SidebarView.swift '.onDrop'

# Behavior: workspace/context title formatting omits redundant text and has an Argus fallback.
swiftc \
  Argus/Models/WorkspaceTitleFormatter.swift \
  Tests/Phase1FoundationTests/WorkspaceTitleFormatterTests.swift \
  -o /tmp/argus-workspace-title-formatter-tests
/tmp/argus-workspace-title-formatter-tests

# Behavior: sidebar layout preferences round-trip through lightweight app preferences.
swiftc \
  Argus/Views/Sidebar/SidebarState.swift \
  Tests/Phase1FoundationTests/SidebarStatePersistenceTests.swift \
  -o /tmp/argus-sidebar-state-persistence-tests
/tmp/argus-sidebar-state-persistence-tests

# Behavior: left sidebar live width range is 80 px through 33% of window width.
swiftc \
  Argus/Views/Sidebar/SidebarLayout.swift \
  Tests/Phase1FoundationTests/SidebarLayoutTests.swift \
  -o /tmp/argus-sidebar-layout-tests
/tmp/argus-sidebar-layout-tests
assert_contains Argus/Views/MainWindowView.swift 'GeometryReader'
assert_contains Argus/Views/MainWindowView.swift 'SidebarLayout.leftMaxWidth'

# Behavior: minimal argus CLI target builds and can print help/version without the app socket.
swift build --product argus
swift run argus --version | grep -Fq 'argus 0.1.0' || fail 'argus --version did not print expected version'
swift run argus --help | grep -Fq 'USAGE: argus' || fail 'argus --help did not print usage'

echo "phase1 foundation checks passed"
