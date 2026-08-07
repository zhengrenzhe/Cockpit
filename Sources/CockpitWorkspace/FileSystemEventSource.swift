import CoreServices
import Foundation
import CockpitTypes

enum FileSystemInvalidation: Equatable, Sendable {
    case targeted([WorkspaceDirectory])
    case allExpanded
}

final class FileSystemEventSource: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let rootURL: URL
        let continuation: AsyncStream<FileSystemInvalidation>.Continuation

        init(
            rootURL: URL,
            continuation: AsyncStream<FileSystemInvalidation>.Continuation
        ) {
            self.rootURL = rootURL
            self.continuation = continuation
        }

        func emit(paths: [String], flags: [FSEventStreamEventFlags]) {
            guard let invalidation = FileSystemEventSource.map(
                rootURL: rootURL,
                paths: paths,
                flags: flags
            ) else { return }
            if case .dropped = continuation.yield(invalidation) {
                continuation.yield(.allExpanded)
            }
        }
    }

    let invalidations: AsyncStream<FileSystemInvalidation>
    private let continuation: AsyncStream<FileSystemInvalidation>.Continuation
    private let callbackBox: CallbackBox
    private let lock = NSLock()
    private var eventStream: FSEventStreamRef?

    init(rootURL: URL) {
        let pair = AsyncStream<FileSystemInvalidation>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        invalidations = pair.stream
        continuation = pair.continuation
        callbackBox = CallbackBox(rootURL: rootURL, continuation: pair.continuation)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            createFlags
        )
        guard let eventStream else {
            continuation.finish()
            return
        }
        FSEventStreamSetDispatchQueue(
            eventStream,
            DispatchQueue(label: "com.openai.cockpit.file-tree-fsevents")
        )
        guard FSEventStreamStart(eventStream) else {
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
            continuation.finish()
            return
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        let stream = eventStream
        eventStream = nil
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        continuation.finish()
    }

    static func map(
        rootURL: URL,
        paths: [String],
        flags: [FSEventStreamEventFlags]
    ) -> FileSystemInvalidation? {
        guard paths.count == flags.count else { return .allExpanded }
        let conservativeFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        if flags.contains(where: { $0 & conservativeFlags != 0 }) {
            return .allExpanded
        }

        let rootPath = rootURL.standardizedFileURL.path
        var directories: Set<WorkspaceDirectory> = []
        for (path, flag) in zip(paths, flags) {
            let eventPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let relative = relativePath(eventPath, under: rootPath) else { continue }
            let components = relative.split(separator: "/").map(String.init)
            if components.count <= 1 {
                directories.insert(.root)
            } else {
                let parent = components.dropLast().joined(separator: "/")
                if let path = try? RelativePath(parent) {
                    directories.insert(.relative(path))
                }
            }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
               !relative.isEmpty,
               let path = try? RelativePath(relative) {
                directories.insert(.relative(path))
            }
        }
        guard !directories.isEmpty else { return nil }
        return .targeted(directories.sorted(by: directoryPrecedes))
    }

    private static let callback: FSEventStreamCallback = {
        _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let pathArray = unsafeBitCast(eventPaths, to: NSArray.self)
        let paths = pathArray.compactMap { $0 as? String }
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
        box.emit(paths: paths, flags: flags)
    }

    private static func relativePath(_ path: String, under root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func directoryPrecedes(
        _ lhs: WorkspaceDirectory,
        _ rhs: WorkspaceDirectory
    ) -> Bool {
        switch (lhs, rhs) {
        case (.root, .root): return false
        case (.root, _): return true
        case (_, .root): return false
        case let (.relative(lhsPath), .relative(rhsPath)):
            let comparison = lhsPath.string.localizedStandardCompare(rhsPath.string)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhsPath.string < rhsPath.string
        }
    }
}
