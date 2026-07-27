import Foundation

private final class SynchronousFlushResult: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func setFailure(_ message: String) {
        lock.lock()
        self.message = message
        lock.unlock()
    }

    func takeFailure() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }
}

@MainActor
final class ReviewSessionCoordinator {
    enum RestoreOutcome {
        case restored(ReviewSessionSnapshot)
        case failed(String)
        case ignored
    }

    private let sessionStore: ReviewSessionStore
    private let restoreSession: @Sendable () async throws -> ReviewSessionSnapshot
    private let beforeScheduleSave: @Sendable () async -> Void
    private var restoreGeneration = 0
    // Reserve zero for store-only callers that retain the compatibility API.
    // Coordinator-issued generations start at one and remain strictly ordered.
    private var saveGeneration: UInt64 = 1
    private var saveGenerationExhausted = false
    private var hasLiveMutation = false
    private var restoreInFlight = false
    private var restoreCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        sessionStore: ReviewSessionStore,
        restoreSession: @escaping @Sendable () async throws -> ReviewSessionSnapshot,
        beforeScheduleSave: @escaping @Sendable () async -> Void = {}
    ) {
        self.sessionStore = sessionStore
        self.restoreSession = restoreSession
        self.beforeScheduleSave = beforeScheduleSave
    }

    func restoreSnapshot() async -> RestoreOutcome {
        restoreGeneration += 1
        let generation = restoreGeneration
        restoreInFlight = true
        do {
            let snapshot = try await restoreSession()
            guard generation == restoreGeneration, !hasLiveMutation else { return .ignored }
            return .restored(snapshot)
        } catch {
            guard generation == restoreGeneration else { return .ignored }
            return .failed(error.localizedDescription)
        }
    }

    /// Restore applies its snapshot in the model after `restoreSnapshot()`
    /// returns. Successful intake waits for that application boundary before
    /// recording its live mutation, so neither state can overwrite the other.
    func completeRestore() {
        guard restoreInFlight else { return }
        restoreInFlight = false
        let waiters = restoreCompletionWaiters
        restoreCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func recordLiveMutationAfterRestore() async {
        if restoreInFlight {
            await withCheckedContinuation { continuation in
                restoreCompletionWaiters.append(continuation)
            }
        }
        recordLiveMutation()
    }

    func recordLiveMutation() {
        hasLiveMutation = true
        restoreGeneration += 1
    }

    func scheduleSave(_ snapshot: ReviewSessionSnapshot) {
        guard let generation = nextSaveGeneration() else { return }
        let beforeScheduleSave = beforeScheduleSave
        Task { [sessionStore] in
            await beforeScheduleSave()
            await sessionStore.scheduleSave(snapshot, generation: generation)
        }
    }

    func flush(_ snapshot: ReviewSessionSnapshot) async throws {
        guard let generation = nextSaveGeneration() else { throw ReviewSessionStore.StoreError.generationExhausted }
        try await sessionStore.flushScheduledSave(snapshot, generation: generation)
    }

    func flushSynchronously(
        _ snapshot: ReviewSessionSnapshot,
        reportFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        guard let generation = nextSaveGeneration() else {
            reportFailure(ReviewSessionStore.StoreError.generationExhausted.localizedDescription)
            return
        }
        let completion = DispatchSemaphore(value: 0)
        let result = SynchronousFlushResult()
        // This cannot inherit MainActor: lifecycle callers synchronously wait
        // on the main thread until the actor write has completed.
        Task.detached { [sessionStore] in
            do {
                try await sessionStore.flushScheduledSave(snapshot, generation: generation)
            } catch {
                result.setFailure(error.localizedDescription)
                completion.signal()
                return
            }
            completion.signal()
        }
        completion.wait()
        if let message = result.takeFailure() {
            reportFailure(message)
        }
    }

    /// Generation allocation happens before any task is created, preserving
    /// call order even when the actor receives those tasks out of order.
    private func nextSaveGeneration() -> UInt64? {
        guard !saveGenerationExhausted else { return nil }
        let generation = saveGeneration
        if generation == .max {
            saveGenerationExhausted = true
        } else {
            saveGeneration += 1
        }
        return generation
    }
}
