import Foundation
import CockpitTerminalCore

#if COCKPIT_GHOSTTY_LINKED
import CockpitGhostty
#endif

enum GhosttyVTAdapterError: Error, Equatable {
    case unavailable
    case createFailed
    case feedFailed
    case snapshotFailed
}

final class GhosttyVTAdapter: @unchecked Sendable {
    private let lock = NSLock()

#if COCKPIT_GHOSTTY_LINKED
    private var terminal: OpaquePointer?

    init(launchSpec: LaunchSpec) throws {
        let size = launchSpec.terminalSize
        guard let terminal = cockpit_ghostty_vt_create(
            UInt32(size.columns),
            UInt32(size.rows),
            100_000
        ) else {
            throw GhosttyVTAdapterError.createFailed
        }
        self.terminal = terminal
    }

    deinit {
        lock.withLock {
            if let terminal {
                cockpit_ghostty_vt_destroy(terminal)
                self.terminal = nil
            }
        }
    }

    func feed(_ data: Data) throws {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            let result = data.withUnsafeBytes { bytes in
                cockpit_ghostty_vt_feed(
                    terminal,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
            guard result == 0 else { throw GhosttyVTAdapterError.feedFailed }
        }
    }

    func snapshot() throws -> Data {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            var bytes = cockpit_ghostty_bytes_t(bytes: nil, length: 0)
            guard cockpit_ghostty_vt_snapshot(terminal, &bytes) == 0 else {
                throw GhosttyVTAdapterError.snapshotFailed
            }
            defer { cockpit_ghostty_bytes_free(bytes) }
            if bytes.length == 0 { return Data() }
            guard let base = bytes.bytes else {
                throw GhosttyVTAdapterError.snapshotFailed
            }
            return Data(bytes: base, count: bytes.length)
        }
    }
#else
    init(launchSpec: LaunchSpec) throws {
        _ = launchSpec
        throw GhosttyVTAdapterError.unavailable
    }

    func feed(_ data: Data) throws {
        _ = data
        throw GhosttyVTAdapterError.unavailable
    }

    func snapshot() throws -> Data {
        throw GhosttyVTAdapterError.unavailable
    }
#endif
}
