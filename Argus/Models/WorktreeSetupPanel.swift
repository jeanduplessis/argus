import Foundation

struct WorktreeSetupOwner: Equatable, Sendable {
    let projectID: UUID
    let repositoryRoot: String
    let workspaceID: UUID
    let rootPath: String
}

/// One runtime-only log/run per Workspace. No Terminal Surface or persisted process state.
@MainActor
final class WorktreeSetupPanel: Panel {
    let id = UUID()
    let panelType: PanelType = .worktreeSetup
    let displayTitle = "Worktree Setup"
    let displayIcon: String? = "hammer"
    @Published private(set) var command = ""
    @Published private(set) var rootPath = ""
    @Published private(set) var output = ""
    @Published private(set) var truncated = false
    @Published private(set) var isRunning = false
    @Published private(set) var outcome: WorktreeSetupOutcome?
    @Published private(set) var terminationConfirmed = true
    @Published private(set) var isStopping = false
    private(set) var generation = UUID()
    private(set) var owner: WorktreeSetupOwner?
    private var cancellation = WorktreeSetupCancellation()
    private var task: Task<Void, Never>?
    private var stopTask: Task<Bool, Never>?

    var isLoading: Bool { isRunning }
    var status: String {
        if !terminationConfirmed {
            return "Could not verify process cleanup. The Workspace and worktree have been retained."
        }
        if isStopping { return "Stopping…" }
        return isRunning ? "Running…" : outcome?.label ?? "Not run"
    }

    func begin(
        command: String,
        owner: WorktreeSetupOwner,
        operation: @escaping @MainActor (UUID, WorktreeSetupCancellation) async -> Void
    ) {
        guard !isRunning else { return }
        self.command = command
        self.owner = owner
        rootPath = owner.rootPath
        output = ""
        truncated = false
        outcome = nil
        terminationConfirmed = true
        isStopping = false
        isRunning = true
        generation = UUID()
        cancellation = WorktreeSetupCancellation()
        let generation = generation
        let cancellation = cancellation
        task = Task { await operation(generation, cancellation) }
    }

    func publish(_ update: WorktreeSetupOutput, generation: UUID) {
        guard self.generation == generation else { return }
        output = update.text
        truncated = update.truncated
    }

    func finish(_ result: WorktreeSetupResult, generation: UUID) {
        guard self.generation == generation else { return }
        outcome = result.outcome
        terminationConfirmed = result.terminationConfirmed
        isRunning = !result.terminationConfirmed
        if stopTask == nil { isStopping = false }
    }

    @discardableResult
    func stop() async -> Bool {
        guard isRunning else { return terminationConfirmed }
        if let stopTask { return await stopTask.value }
        isStopping = true
        cancellation.cancel()
        task?.cancel()
        let stopping = Task {
            await task?.value
            if !terminationConfirmed, await cancellation.retryCleanup() {
                terminationConfirmed = true
                isRunning = false
            }
            return terminationConfirmed && !isRunning
        }
        stopTask = stopping
        let stopped = await stopping.value
        stopTask = nil
        isStopping = false
        return stopped
    }

    func close() {
        // Close paths await stop before removing this Panel. Never silently abandon a process.
        cancellation.cancel()
    }
    func focus() {}
    func unfocus() {}
}
