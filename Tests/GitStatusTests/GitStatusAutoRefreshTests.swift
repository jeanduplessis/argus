import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusAutoRefreshTests {
  @Test
  func coveredBehaviors() async throws {
    await ignoresGitInternalEvents()
    await refreshesForCommitMetadataEvents()
    await switchesWatchedRootWithoutStoppingBeforeFirstStart()
    await schedulesRefreshAfterDebounceForWorktreeEvents()
    await suppressesFilesystemEventsDuringPostRefreshCooldown()
    await refreshesWorkspaceFilesAfterDebouncedEvent()
    try await reloadsExpandedDirectoryAfterExternalFileCreation()
    try watchesLinkedWorktreeGitDirectory()
    try await startsAndStopsFSEventsWatcherForRoot()
  }

  @MainActor
  private func ignoresGitInternalEvents() async {
    let watcher = RecordingFileSystemEventWatcher()
    let scheduler = RecordingRefreshScheduler()
    let controller = GitStatusAutoRefreshController(
      watcher: watcher,
      scheduler: scheduler,
      now: { Date(timeIntervalSince1970: 100) }
    )
    var refreshCount = 0
    controller.start(rootPath: "/repo") {
      refreshCount += 1
    }

    watcher.emit(paths: ["/repo/.git/index"])

    assertEqual(scheduler.scheduledDelays, [], ".git events do not schedule refresh")
    assertEqual(refreshCount, 0, ".git events do not refresh")
  }

  @MainActor
  private func refreshesForCommitMetadataEvents() async {
    let watcher = RecordingFileSystemEventWatcher()
    let scheduler = RecordingRefreshScheduler()
    let controller = GitStatusAutoRefreshController(
      watcher: watcher,
      scheduler: scheduler,
      now: { Date(timeIntervalSince1970: 100) }
    )
    var refreshCount = 0
    controller.start(rootPath: "/repo") {
      refreshCount += 1
    }

    watcher.emit(paths: ["/repo/.git/logs/HEAD"])
    await scheduler.runScheduled()

    assertEqual(refreshCount, 1, "commit metadata events refresh status")
  }

  @MainActor
  private func switchesWatchedRootWithoutStoppingBeforeFirstStart() async {
    let watcher = RecordingFileSystemEventWatcher()
    let scheduler = RecordingRefreshScheduler()
    let controller = GitStatusAutoRefreshController(
      watcher: watcher,
      scheduler: scheduler,
      now: { Date(timeIntervalSince1970: 100) }
    )

    controller.start(rootPath: "/repo-a") {}
    controller.start(rootPath: "/repo-b") {}

    assertEqual(watcher.startedRoots, ["/repo-a", "/repo-b"], "watcher starts each distinct root")
    assertEqual(watcher.stopCount, 1, "switching roots stops only the previous active watch")
    assertEqual(scheduler.cancelCount, 1, "switching roots cancels pending refresh work")
  }

  @MainActor
  private func schedulesRefreshAfterDebounceForWorktreeEvents() async {
    let watcher = RecordingFileSystemEventWatcher()
    let scheduler = RecordingRefreshScheduler()
    let controller = GitStatusAutoRefreshController(
      watcher: watcher,
      scheduler: scheduler,
      now: { Date(timeIntervalSince1970: 100) }
    )
    var refreshCount = 0
    controller.start(rootPath: "/repo") {
      refreshCount += 1
    }

    watcher.emit(paths: ["/repo/Sources/App.swift"])

    assertEqual(
      scheduler.scheduledDelays, [GitStatusAutoRefreshController.debounceInterval],
      "file events schedule one debounced refresh")
    assertEqual(refreshCount, 0, "refresh waits for debounce scheduler")
    await scheduler.runScheduled()
    assertEqual(refreshCount, 1, "scheduled debounce operation refreshes")
  }

  @MainActor
  private func suppressesFilesystemEventsDuringPostRefreshCooldown() async {
    let watcher = RecordingFileSystemEventWatcher()
    let scheduler = RecordingRefreshScheduler()
    var currentTime = Date(timeIntervalSince1970: 100)
    let controller = GitStatusAutoRefreshController(
      watcher: watcher,
      scheduler: scheduler,
      now: { currentTime }
    )
    var refreshCount = 0
    controller.start(rootPath: "/repo") {
      refreshCount += 1
    }

    watcher.emit(paths: ["/repo/file-a.txt"])
    await scheduler.runScheduled()
    assertEqual(refreshCount, 1, "first event refreshes")

    currentTime = Date(timeIntervalSince1970: 100.5)
    watcher.emit(paths: ["/repo/file-b.txt"])
    assertEqual(
      scheduler.scheduledDelays, [GitStatusAutoRefreshController.debounceInterval],
      "cooldown suppresses new schedules")

    currentTime = Date(timeIntervalSince1970: 101.1)
    watcher.emit(paths: ["/repo/file-c.txt"])
    assertEqual(
      scheduler.scheduledDelays,
      [
        GitStatusAutoRefreshController.debounceInterval,
        GitStatusAutoRefreshController.debounceInterval,
      ], "events after cooldown schedule again")
  }

  @MainActor
  private func refreshesWorkspaceFilesAfterDebouncedEvent() async {
    let watcher = RecordingFileSystemEventWatcher()
    let scheduler = RecordingRefreshScheduler()
    let controller = WorkspaceFilesAutoRefreshController(
      watcher: watcher,
      scheduler: scheduler)
    var refreshCount = 0

    controller.start(rootPath: "/workspace") {
      refreshCount += 1
    }
    watcher.emit(paths: ["/workspace/Sources/NewFile.swift"])

    assertEqual(
      scheduler.scheduledDelays, [WorkspaceFilesAutoRefreshController.debounceInterval],
      "workspace file events schedule a debounced refresh")
    assertEqual(refreshCount, 0, "workspace file refresh waits for debounce")
    await scheduler.runScheduled()
    assertEqual(refreshCount, 1, "workspace file event refreshes the tree")
  }

  @MainActor
  private func reloadsExpandedDirectoryAfterExternalFileCreation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("argus-files-auto-refresh-\(UUID().uuidString)", isDirectory: true)
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try "existing\n".write(
      to: sources.appendingPathComponent("Existing.swift"),
      atomically: true,
      encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let request = WorkspaceFileTreeRequest(workspaceId: UUID(), rootPath: root.path)
    let viewModel = WorkspaceFilesViewModel()
    viewModel.activate(request: request)
    await viewModel.refresh(request: request)
    await viewModel.loadChildren(request: request, directoryPath: "Sources")

    try "new\n".write(
      to: sources.appendingPathComponent("NewFile.swift"),
      atomically: true,
      encoding: .utf8)
    await viewModel.refresh(request: request)

    guard case .loaded(let snapshot) = viewModel.state else {
      Issue.record("expected refreshed workspace file tree")
      return
    }
    let sourceNames = snapshot.nodes
      .first(where: { $0.path == "Sources" })?
      .children
      .map(\.name)
    assertEqual(
      sourceNames, ["Existing.swift", "NewFile.swift"],
      "refresh reloads previously expanded directory children")
    #expect(snapshot.loadedDirectoryPaths.contains("Sources"))
  }

  private func watchesLinkedWorktreeGitDirectory() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("argus-linked-worktree-\(UUID().uuidString)", isDirectory: true)
    let worktree = base.appendingPathComponent("worktree", isDirectory: true)
    let gitDirectory = base.appendingPathComponent("repository/.git/worktrees/feature", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try "gitdir: ../repository/.git/worktrees/feature\n".write(
      to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: base) }

    assertEqual(
      GitStatusAutoRefreshController.watchedPaths(for: worktree.path),
      [worktree.standardizedFileURL.path, gitDirectory.standardizedFileURL.path],
      "linked worktrees watch their external git directory for commit metadata")
  }

  @MainActor
  private func startsAndStopsFSEventsWatcherForRoot() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("argus-fsevents-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = FSEventsFileWatcher()
    watcher.start(paths: [directory.path]) { _ in }
    watcher.stop()
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }
}

private final class RecordingFileSystemEventWatcher: FileSystemEventWatching, @unchecked Sendable {
  var onEvents: (@MainActor @Sendable ([String]) -> Void)?
  private(set) var startedRoots: [String] = []
  private(set) var stopCount = 0

  func start(paths: [String], onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
    startedRoots.append(contentsOf: paths)
    self.onEvents = onEvents
  }

  func stop() {
    stopCount += 1
  }

  @MainActor
  func emit(paths: [String]) {
    onEvents?(paths)
  }
}

@MainActor
private final class RecordingRefreshScheduler: RefreshScheduling {
  private(set) var scheduledDelays: [TimeInterval] = []
  private(set) var cancelCount = 0
  private var scheduledOperation: (@MainActor @Sendable () async -> Void)?

  func schedule(
    after delay: TimeInterval, operation: @escaping @MainActor @Sendable () async -> Void
  ) {
    scheduledDelays.append(delay)
    scheduledOperation = operation
  }

  func cancel() {
    cancelCount += 1
    scheduledOperation = nil
  }

  func runScheduled() async {
    await scheduledOperation?()
  }
}
