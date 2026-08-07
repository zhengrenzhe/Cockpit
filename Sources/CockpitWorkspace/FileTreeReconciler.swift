import Foundation

final class FileTreeReconciler: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let condition = NSCondition()
        private var isFinished = false
        private var waiterCount = 0

        func finish() {
            condition.lock()
            isFinished = true
            condition.broadcast()
            condition.unlock()
        }

        func wait() {
            condition.lock()
            while !isFinished {
                waiterCount += 1
                condition.broadcast()
                condition.wait()
                waiterCount -= 1
            }
            condition.unlock()
        }

        func waitUntilWaiterIsBlocked() {
            condition.lock()
            while waiterCount == 0 {
                condition.wait()
            }
            condition.unlock()
        }
    }

    private let lock = NSLock()
    private let completion = Completion()
    private var reconciliationTask: Task<Void, Never>?

    init(
        provider: FileTreeProvider,
        invalidations: AsyncThrowingStream<FileSystemInvalidation, Error>,
        documentRegistry: DocumentRegistry? = nil
    ) {
        let completion = completion
        reconciliationTask = Task { [weak provider] in
            defer { completion.finish() }
            do {
                for try await invalidation in invalidations {
                    guard !Task.isCancelled, let provider else { return }
                    if let documentRegistry {
                        switch invalidation {
                        case let .targeted(scopes):
                            await documentRegistry.handleExternalChanges(in: Set(scopes))
                        case .allExpanded:
                            await documentRegistry.handleExternalChanges(in: [.root])
                        }
                    }
                    let directories = await provider.expandedDirectories(affectedBy: invalidation)
                    for directory in directories {
                        guard !Task.isCancelled else { return }
                        do { _ = try await provider.reconcile(directory) }
                        catch is CancellationError { return }
                        catch {
                            await provider.failCurrentSubscribers(.filesystemEnumerationFailed)
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let provider else { return }
                await provider.terminateChanges(.eventSourceUnavailable)
            }
        }
    }

    deinit {
        cancelAndWait()
    }

    func cancel() {
        cancelAndWait()
    }

    func cancelAndWait() {
        lock.lock()
        let task = reconciliationTask
        reconciliationTask = nil
        lock.unlock()
        task?.cancel()
        completion.wait()
    }

    func waitUntilJoinIsBlocked() {
        completion.waitUntilWaiterIsBlocked()
    }
}
