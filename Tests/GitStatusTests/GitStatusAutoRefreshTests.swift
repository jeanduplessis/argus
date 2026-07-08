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
    try watchesLinkedWorktreeGitDirectory()
    try await startsAndStopsFSEventsWatcherForRoot()
  }

  @MainActor
  private func ignoresGitInternalEvents() async {
    let watcher = RecordingGitStatusFileWatcher()
    let scheduler = RecordingGitStatusRefreshScheduler()
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
    let watcher = RecordingGitStatusFileWatcher()
    let scheduler = RecordingGitStatusRefreshScheduler()
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
    let watcher = RecordingGitStatusFileWatcher()
    let scheduler = RecordingGitStatusRefreshScheduler()
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
    let watcher = RecordingGitStatusFileWatcher()
    let scheduler = RecordingGitStatusRefreshScheduler()
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
    let watcher = RecordingGitStatusFileWatcher()
    let scheduler = RecordingGitStatusRefreshScheduler()
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
      FSEventsGitStatusFileWatcher.watchedPaths(for: worktree.path),
      [worktree.standardizedFileURL.path, gitDirectory.standardizedFileURL.path],
      "linked worktrees watch their external git directory for commit metadata")
  }

  @MainActor
  private func startsAndStopsFSEventsWatcherForRoot() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("argus-fsevents-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = FSEventsGitStatusFileWatcher()
    watcher.start(rootPath: directory.path) { _ in }
    watcher.stop()
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }
}

private final class RecordingGitStatusFileWatcher: GitStatusFileWatching, @unchecked Sendable {
  var onEvents: (@MainActor @Sendable ([String]) -> Void)?
  private(set) var startedRoots: [String] = []
  private(set) var stopCount = 0

  func start(rootPath: String, onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
    startedRoots.append(rootPath)
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
private final class RecordingGitStatusRefreshScheduler: GitStatusRefreshScheduling {
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
