import Foundation
import Network
import Security

public enum NetworkByteStreamError: Error, Equatable, Sendable {
    case closed
    case notReady
    case sendInProgress
    case receiveInProgress
    case invalidLength(UInt32)
    case invalidMaximumLength(Int)
}

private final class CompletionBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        let result = self.result
        if result == nil {
            self.continuation = continuation
        }
        lock.unlock()
        result.map { continuation.resume(with: $0) }
    }

    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public actor NWConnectionByteStream {
    public static let maximumMessageLength = 16 * 1_024 * 1_024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.cockpit.remote.connection")
    private var started = false
    private var ready = false
    private var cancelled = false
    private var startCompletion: CompletionBox<Void>?
    private var sendCompletion: CompletionBox<Void>?
    private var receiveCompletion: CompletionBox<Data>?
    private var sending = false
    private var receiving = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() async throws {
        guard !started, !cancelled else { throw NetworkByteStreamError.closed }
        started = true
        let completion = CompletionBox<Void>()
        startCompletion = completion
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                connection?.stateUpdateHandler = nil
                completion.resolve(.success(()))
            case .failed(let error):
                connection?.stateUpdateHandler = nil
                completion.resolve(.failure(error))
            case .waiting(let error):
                connection?.stateUpdateHandler = nil
                connection?.cancel()
                completion.resolve(.failure(error))
            case .cancelled:
                connection?.stateUpdateHandler = nil
                completion.resolve(.failure(NetworkByteStreamError.closed))
            default: break
            }
        }
        defer {
            if startCompletion === completion {
                startCompletion = nil
            }
        }
        try await awaitCompletion(completion) { self.connection.start(queue: self.queue) }
        guard !cancelled else { throw NetworkByteStreamError.closed }
        ready = true
    }

    public func sendLengthPrefixed(_ data: Data) async throws {
        guard !cancelled else { throw NetworkByteStreamError.closed }
        guard ready else { throw NetworkByteStreamError.notReady }
        guard !sending else { throw NetworkByteStreamError.sendInProgress }
        guard data.count <= Self.maximumMessageLength else {
            throw NetworkByteStreamError.invalidLength(UInt32(Self.maximumMessageLength + 1))
        }
        var length = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.reserveCapacity(4 + data.count)
        packet.append(data)
        let immutablePacket = packet
        let completion = CompletionBox<Void>()
        sending = true
        sendCompletion = completion
        defer {
            if sendCompletion === completion {
                sendCompletion = nil
                sending = false
            }
        }
        try await awaitCompletion(completion) {
            self.connection.send(content: immutablePacket, completion: .contentProcessed { error in
                completion.resolve(error.map(Result.failure) ?? .success(()))
            })
        }
    }

    public func receiveLengthPrefixed(maximumLength: Int = maximumMessageLength) async throws -> Data {
        guard maximumLength >= 0, maximumLength <= Self.maximumMessageLength else {
            throw NetworkByteStreamError.invalidMaximumLength(maximumLength)
        }
        guard !cancelled else { throw NetworkByteStreamError.closed }
        guard ready else { throw NetworkByteStreamError.notReady }
        guard !receiving else { throw NetworkByteStreamError.receiveInProgress }
        receiving = true
        defer { receiving = false }
        let lengthData = try await receiveExactly(4)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumLength) else { throw NetworkByteStreamError.invalidLength(length) }
        return try await receiveExactly(Int(length))
    }

    public func cancel() {
        close()
    }

    private func close() {
        guard !cancelled else { return }
        cancelled = true
        ready = false
        connection.cancel()
        let error = NetworkByteStreamError.closed
        startCompletion?.resolve(.failure(error))
        sendCompletion?.resolve(.failure(error))
        receiveCompletion?.resolve(.failure(error))
    }

    public func negotiatedTLSVersion() -> tls_protocol_version_t? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let completion = CompletionBox<Data>()
            receiveCompletion = completion
            defer {
                if receiveCompletion === completion {
                    receiveCompletion = nil
                }
            }
            let remaining = count - result.count
            let chunk = try await awaitCompletion(completion) {
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error {
                        completion.resolve(.failure(error))
                    } else if let data, !data.isEmpty {
                        completion.resolve(.success(data))
                    } else if complete {
                        completion.resolve(.failure(NetworkByteStreamError.closed))
                    } else {
                        completion.resolve(.failure(NetworkByteStreamError.closed))
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private func awaitCompletion<Value: Sendable>(
        _ completion: CompletionBox<Value>,
        begin: @escaping @Sendable () -> Void
    ) async throws -> Value {
        do {
            let value = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    begin()
                }
            }, onCancel: {
                completion.resolve(.failure(CancellationError()))
                connection.cancel()
            })
            try Task.checkCancellation()
            return value
        } catch {
            if Task.isCancelled {
                close()
                throw CancellationError()
            }
            if error is CancellationError {
                close()
            }
            throw error
        }
    }
}
