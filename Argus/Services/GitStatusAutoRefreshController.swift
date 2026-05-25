import CoreServices
import Foundation

protocol GitStatusFileWatching: AnyObject, Sendable {
    func start(rootPath: String, onEvents: @escaping @MainActor @Sendable ([String]) -> Void)
    func stop()
}

@MainActor
protocol GitStatusRefreshScheduling: AnyObject {
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () async -> Void)
    func cancel()
}

@MainActor
final class GitStatusAutoRefreshController {
    static let debounceInterval: TimeInterval = 0.3
    static let cooldownInterval: TimeInterval = 1.0

    private let watcher: any GitStatusFileWatching
    private let scheduler: any GitStatusRefreshScheduling
    private let now: () -> Date
    private var refresh: (@MainActor @Sendable () async -> Void)?
    private var currentRootPath: String?
    private var lastRefreshCompletedAt: Date?

    convenience init() {
        self.init(
            watcher: FSEventsGitStatusFileWatcher(),
            scheduler: DispatchGitStatusRefreshScheduler()
        )
    }

    init(
        watcher: any GitStatusFileWatching,
        scheduler: any GitStatusRefreshScheduling,
        now: @escaping () -> Date = Date.init
    ) {
        self.watcher = watcher
        self.scheduler = scheduler
        self.now = now
    }

    func start(rootPath: String, refresh: @escaping @MainActor @Sendable () async -> Void) {
        self.refresh = refresh
        guard currentRootPath != rootPath else { return }
        if currentRootPath != nil {
            scheduler.cancel()
            watcher.stop()
        }
        currentRootPath = rootPath
        watcher.start(rootPath: rootPath) { [weak self] paths in
            self?.handleFileEvents(paths)
        }
    }

    func stop() {
        scheduler.cancel()
        watcher.stop()
        currentRootPath = nil
        refresh = nil
    }

    func handleFileEvents(_ paths: [String]) {
        guard paths.contains(where: shouldRefresh(for:)) else { return }
        guard isOutsideCooldown else { return }

        scheduler.cancel()
        scheduler.schedule(after: Self.debounceInterval) { [weak self] in
            guard let self else { return }
            await self.refresh?()
            self.lastRefreshCompletedAt = self.now()
        }
    }

    private var isOutsideCooldown: Bool {
        guard let lastRefreshCompletedAt else { return true }
        return now().timeIntervalSince(lastRefreshCompletedAt) >= Self.cooldownInterval
    }

    private func shouldRefresh(for path: String) -> Bool {
        let components = path.split(separator: "/")
        return !components.contains(".git")
    }
}

final class FSEventsGitStatusFileWatcher: GitStatusFileWatching, @unchecked Sendable {
    static let latency: CFTimeInterval = 0.3

    private let callbackBox = FSEventsCallbackBox()
    private let queue = DispatchQueue(label: "com.argus.git-status.fsevents")
    private var stream: FSEventStreamRef?

    func start(rootPath: String, onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
        stop()
        callbackBox.onEvents = onEvents

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [rootPath] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fseventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

private final class FSEventsCallbackBox: @unchecked Sendable {
    var onEvents: (@MainActor @Sendable ([String]) -> Void)?
}

private let fseventsCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let box = Unmanaged<FSEventsCallbackBox>.fromOpaque(info).takeUnretainedValue()
    let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray)
        .compactMap { $0 as? String }
    Task { @MainActor in
        box.onEvents?(paths)
    }
}

@MainActor
final class DispatchGitStatusRefreshScheduler: GitStatusRefreshScheduling {
    private var workItem: DispatchWorkItem?

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () async -> Void) {
        cancel()
        let item = DispatchWorkItem {
            Task { @MainActor in await operation() }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
