import CoreServices
import Foundation
import CockpitHostCore
import CockpitTypes

enum FileSystemInvalidation: Equatable, Sendable { case targeted([WorkspaceDirectory]); case allExpanded }

protocol FileSystemEventDriving: AnyObject, Sendable {
    func start(rootURL: URL, callback: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) -> Bool
    func cancel()
}

protocol FSEventStreamAPI: Sendable {
    func create(
        callback: @escaping FSEventStreamCallback,
        context: inout FSEventStreamContext,
        paths: CFArray,
        sinceWhen: FSEventStreamEventId,
        latency: CFTimeInterval,
        flags: FSEventStreamCreateFlags
    ) -> FSEventStreamRef?
    func setDispatchQueue(_ stream: FSEventStreamRef, queue: DispatchQueue)
    func start(_ stream: FSEventStreamRef) -> Bool
    func stop(_ stream: FSEventStreamRef)
    func invalidate(_ stream: FSEventStreamRef)
    func release(_ stream: FSEventStreamRef)
}

private struct CoreServicesFSEventStreamAPI: FSEventStreamAPI {
    func create(
        callback: @escaping FSEventStreamCallback,
        context: inout FSEventStreamContext,
        paths: CFArray,
        sinceWhen: FSEventStreamEventId,
        latency: CFTimeInterval,
        flags: FSEventStreamCreateFlags
    ) -> FSEventStreamRef? {
        FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            sinceWhen,
            latency,
            flags
        )
    }

    func setDispatchQueue(_ stream: FSEventStreamRef, queue: DispatchQueue) {
        FSEventStreamSetDispatchQueue(stream, queue)
    }

    func start(_ stream: FSEventStreamRef) -> Bool {
        FSEventStreamStart(stream)
    }

    func stop(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
    }

    func invalidate(_ stream: FSEventStreamRef) {
        FSEventStreamInvalidate(stream)
    }

    func release(_ stream: FSEventStreamRef) {
        FSEventStreamRelease(stream)
    }
}

final class CoreServicesEventStreamDriver: FileSystemEventDriving, @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let callback: @Sendable ([String], [FSEventStreamEventFlags]) -> Void
        init(_ callback: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) { self.callback = callback }
    }
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "com.openai.cockpit.file-tree-fsevents")
    private let api: any FSEventStreamAPI
    private var stream: FSEventStreamRef?

    init(api: any FSEventStreamAPI = CoreServicesFSEventStreamAPI()) {
        self.api = api
    }

    func start(rootURL: URL, callback: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) -> Bool {
        let box = CallbackBox(callback)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: Self.retainContext, release: Self.releaseContext, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = api.create(callback: Self.callback, context: &context, paths: [rootURL.path] as CFArray, sinceWhen: FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency: 0.05, flags: flags) else { return false }
        api.setDispatchQueue(created, queue: callbackQueue)
        guard api.start(created) else { api.invalidate(created); api.release(created); return false }
        lock.withLock { stream = created }
        return true
    }
    func cancel() {
        guard let value = lock.withLock({ let value = stream; stream = nil; return value }) else { return }
        api.stop(value)
        api.invalidate(value)
        api.release(value)
    }
    deinit { cancel() }
    private static let retainContext: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }; _ = Unmanaged<CallbackBox>.fromOpaque(info).retain(); return UnsafeRawPointer(info)
    }
    private static let releaseContext: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }; Unmanaged<CallbackBox>.fromOpaque(info).release()
    }
    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self).compactMap { $0 as? String }
        box.callback(paths, Array(UnsafeBufferPointer(start: eventFlags, count: count)))
    }
}

final class FileSystemEventSource: @unchecked Sendable {
    let invalidations: AsyncThrowingStream<FileSystemInvalidation, Error>
    private let continuation: AsyncThrowingStream<FileSystemInvalidation, Error>.Continuation
    private let driver: any FileSystemEventDriving
    private let lock = NSLock()
    private var cancelled = false
    init(rootURL: URL, driver: any FileSystemEventDriving = CoreServicesEventStreamDriver()) {
        let pair = AsyncThrowingStream<FileSystemInvalidation, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        invalidations = pair.stream; continuation = pair.continuation; self.driver = driver
        let started = driver.start(rootURL: rootURL) { [continuation = pair.continuation] paths, flags in
            guard let invalidation = Self.map(rootURL: rootURL, paths: paths, flags: flags) else { return }
            if case .dropped = continuation.yield(invalidation) { continuation.yield(.allExpanded) }
        }
        if !started { pair.continuation.finish(throwing: FileTreeProviderError.eventSourceUnavailable) }
    }
    func cancel() {
        let perform = lock.withLock { if cancelled { return false }; cancelled = true; return true }
        guard perform else { return }; driver.cancel(); continuation.finish()
    }
    deinit { cancel() }
    static func map(rootURL: URL, paths: [String], flags: [FSEventStreamEventFlags]) -> FileSystemInvalidation? {
        guard paths.count == flags.count else { return .allExpanded }
        let conservative = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        if flags.contains(where: { $0 & conservative != 0 }) { return .allExpanded }
        let root = rootURL.standardizedFileURL.path; var result: Set<WorkspaceDirectory> = []
        for (raw, flag) in zip(paths, flags) {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let relative: String
            if path == root { relative = "" } else { guard path.hasPrefix(prefix) else { continue }; relative = String(path.dropFirst(prefix.count)) }
            let components = relative.split(separator: "/")
            if components.count <= 1 { result.insert(.root) }
            else if let parent = try? RelativePath(components.dropLast().joined(separator: "/")) { result.insert(.relative(parent)) }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0, let directory = try? RelativePath(relative) { result.insert(.relative(directory)) }
        }
        guard !result.isEmpty else { return nil }
        return .targeted(result.sorted(by: directoryPrecedes))
    }
    private static func directoryPrecedes(_ l: WorkspaceDirectory, _ r: WorkspaceDirectory) -> Bool {
        switch (l, r) { case (.root, .root): return false; case (.root, _): return true; case (_, .root): return false; case let (.relative(a), .relative(b)): let c = a.string.localizedStandardCompare(b.string); return c == .orderedSame ? a.string < b.string : c == .orderedAscending }
    }
}
