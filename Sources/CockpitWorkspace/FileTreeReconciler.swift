import Foundation

final class FileTreeReconciler: @unchecked Sendable {
    private let lock = NSLock()
    private var reconciliationTask: Task<Void, Never>?

    init(
        provider: FileTreeProvider,
        invalidations: AsyncStream<FileSystemInvalidation>
    ) {
        reconciliationTask = Task { [weak provider] in
            for await invalidation in invalidations {
                guard !Task.isCancelled, let provider else { return }
                let directories = await provider.expandedDirectories(affectedBy: invalidation)
                for directory in directories {
                    guard !Task.isCancelled else { return }
                    do {
                        _ = try await provider.reconcile(directory)
                    } catch is CancellationError {
                        return
                    } catch {
                        continue
                    }
                }
            }
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        let task = reconciliationTask
        reconciliationTask = nil
        lock.unlock()
        task?.cancel()
    }
}
