import Foundation

final class FileTreeReconciler: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let condition = NSCondition()
        private var isFinished = false

        func finish() {
            condition.lock()
            isFinished = true
            condition.broadcast()
            condition.unlock()
        }

        func wait() {
            condition.lock()
            while !isFinished {
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
        invalidations: AsyncThrowingStream<FileSystemInvalidation, Error>
    ) {
        let completion = completion
        reconciliationTask = Task { [weak provider] in
            defer { completion.finish() }
            do {
                for try await invalidation in invalidations {
                    guard !Task.isCancelled, let provider else { return }
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
}
