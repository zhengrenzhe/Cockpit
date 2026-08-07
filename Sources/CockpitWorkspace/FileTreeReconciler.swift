import Foundation

final class FileTreeReconciler: @unchecked Sendable {
    private let lock = NSLock()
    private var reconciliationTask: Task<Void, Never>?

    init(
        provider: FileTreeProvider,
        invalidations: AsyncThrowingStream<FileSystemInvalidation, Error>
    ) {
        reconciliationTask = Task { [weak provider] in
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
