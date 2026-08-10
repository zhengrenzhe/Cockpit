import Foundation
import CockpitTerminalCore
import CockpitTypes

#if COCKPIT_GHOSTTY_LINKED
import CockpitGhostty
#endif

enum GhosttyVTAdapterError: Error, Equatable {
    case unavailable
    case createFailed
    case feedFailed
    case snapshotFailed
    case deltaFailed
    case resizeFailed
    case encodeFailed
}

final class GhosttyVTAdapter: @unchecked Sendable {
    private let lock = NSLock()

#if COCKPIT_GHOSTTY_LINKED
    private var terminal: OpaquePointer?
    private var viewportSequence: UInt64 = 0

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
            guard viewportSequence < UInt64.max else {
                throw GhosttyVTAdapterError.snapshotFailed
            }
            var bytes = cockpit_ghostty_bytes_t(bytes: nil, length: 0)
            guard cockpit_ghostty_vt_snapshot(terminal, &bytes) == 0 else {
                throw GhosttyVTAdapterError.snapshotFailed
            }
            defer { cockpit_ghostty_bytes_free(bytes) }
            guard bytes.length == 0 || bytes.bytes != nil else {
                throw GhosttyVTAdapterError.snapshotFailed
            }
            let data = bytes.length == 0
                ? Data()
                : Data(bytes: bytes.bytes!, count: bytes.length)
            viewportSequence += 1
            return data
        }
    }

    func delta() throws -> Data {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            guard viewportSequence > 0, viewportSequence < UInt64.max else {
                throw GhosttyVTAdapterError.deltaFailed
            }
            var bytes = cockpit_ghostty_bytes_t(bytes: nil, length: 0)
            guard cockpit_ghostty_vt_delta(terminal, viewportSequence, &bytes) == 0 else {
                throw GhosttyVTAdapterError.deltaFailed
            }
            defer { cockpit_ghostty_bytes_free(bytes) }
            guard bytes.length > 0, let base = bytes.bytes else {
                throw GhosttyVTAdapterError.deltaFailed
            }
            let data = Data(bytes: base, count: bytes.length)
            viewportSequence += 1
            return data
        }
    }

    func scrollback(start: UInt64, count: UInt32) throws -> Data {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            var bytes = cockpit_ghostty_bytes_t(bytes: nil, length: 0)
            guard cockpit_ghostty_vt_scrollback(terminal, start, count, &bytes) == 0 else {
                throw GhosttyVTAdapterError.snapshotFailed
            }
            defer { cockpit_ghostty_bytes_free(bytes) }
            guard bytes.length == 0 || bytes.bytes != nil else {
                throw GhosttyVTAdapterError.snapshotFailed
            }
            return bytes.length == 0 ? Data() : Data(bytes: bytes.bytes!, count: bytes.length)
        }
    }

    func resize(_ size: TerminalResize) throws {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            guard cockpit_ghostty_vt_resize(
                terminal,
                UInt32(size.columns),
                UInt32(size.rows)
            ) == 0 else {
                throw GhosttyVTAdapterError.resizeFailed
            }
        }
    }

    func encodeKey(_ event: TerminalKeyEvent) throws -> Data {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            var input = cockpit_ghostty_key_event_t()
            input.logical_key = event.logicalKey
            input.physical_key = event.physicalKey
            input.modifiers = event.modifiers
            input.action = event.action.rawValue
            return try encodedBytes { output in
                cockpit_ghostty_vt_encode_key(terminal, &input, output)
            }
        }
    }

    func encodePaste(_ text: String) throws -> Data {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            let data = Data(text.utf8)
            return try data.withUnsafeBytes { bytes in
                try encodedBytes { output in
                    cockpit_ghostty_vt_encode_paste(
                        terminal,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count,
                        output
                    )
                }
            }
        }
    }

    func encodeMouse(_ event: TerminalMouseEvent) throws -> Data {
        try lock.withLock {
            guard let terminal else { throw GhosttyVTAdapterError.unavailable }
            var input = cockpit_ghostty_mouse_event_t()
            input.cell_x = event.cellX
            input.cell_y = event.cellY
            input.buttons = event.buttons
            input.wheel_x = event.wheelX
            input.wheel_y = event.wheelY
            input.modifiers = event.modifiers
            input.action = event.action.rawValue
            return try encodedBytes { output in
                cockpit_ghostty_vt_encode_mouse(terminal, &input, output)
            }
        }
    }

    func resetInputState() {
        lock.withLock {
            if let terminal { cockpit_ghostty_vt_reset_input_state(terminal) }
        }
    }

    private func encodedBytes(
        _ operation: (UnsafeMutablePointer<cockpit_ghostty_bytes_t>) -> Int32
    ) throws -> Data {
        var bytes = cockpit_ghostty_bytes_t(bytes: nil, length: 0)
        guard operation(&bytes) == 0 else { throw GhosttyVTAdapterError.encodeFailed }
        defer { cockpit_ghostty_bytes_free(bytes) }
        guard bytes.length == 0 || bytes.bytes != nil else {
            throw GhosttyVTAdapterError.encodeFailed
        }
        return bytes.length == 0 ? Data() : Data(bytes: bytes.bytes!, count: bytes.length)
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

    func delta() throws -> Data {
        throw GhosttyVTAdapterError.unavailable
    }

    func scrollback(start: UInt64, count: UInt32) throws -> Data {
        _ = start
        _ = count
        throw GhosttyVTAdapterError.unavailable
    }

    func resize(_ size: TerminalResize) throws {
        _ = size
        throw GhosttyVTAdapterError.unavailable
    }

    func encodeKey(_ event: TerminalKeyEvent) throws -> Data {
        _ = event
        throw GhosttyVTAdapterError.unavailable
    }

    func encodePaste(_ text: String) throws -> Data {
        _ = text
        throw GhosttyVTAdapterError.unavailable
    }

    func encodeMouse(_ event: TerminalMouseEvent) throws -> Data {
        _ = event
        throw GhosttyVTAdapterError.unavailable
    }

    func resetInputState() {}
#endif
}
