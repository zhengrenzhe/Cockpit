import Foundation
import Network
import Security

public enum NetworkByteStreamError: Error, Equatable, Sendable {
    case closed
    case invalidLength(UInt32)
    case invalidMaximumLength(Int)
}

private actor CompletionBox<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        if let result {
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

public actor NWConnectionByteStream {
    public static let maximumMessageLength = 16 * 1_024 * 1_024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.cockpit.remote.connection")
    private var started = false
    private var cancelled = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() async throws {
        guard !started, !cancelled else { throw NetworkByteStreamError.closed }
        started = true
        let completion = CompletionBox<Void>()
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                connection?.stateUpdateHandler = nil
                Task { await completion.resolve(.success(())) }
            case .failed(let error):
                connection?.stateUpdateHandler = nil
                Task { await completion.resolve(.failure(error)) }
            case .waiting(let error):
                connection?.stateUpdateHandler = nil
                connection?.cancel()
                Task { await completion.resolve(.failure(error)) }
            case .cancelled:
                connection?.stateUpdateHandler = nil
                Task { await completion.resolve(.failure(NetworkByteStreamError.closed)) }
            default: break
            }
        }
        try await awaitCompletion(completion) { self.connection.start(queue: self.queue) }
    }

    public func sendLengthPrefixed(_ data: Data) async throws {
        guard data.count <= Self.maximumMessageLength else {
            throw NetworkByteStreamError.invalidLength(UInt32(Self.maximumMessageLength + 1))
        }
        var length = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.reserveCapacity(4 + data.count)
        packet.append(data)
        let immutablePacket = packet
        let completion = CompletionBox<Void>()
        try await awaitCompletion(completion) {
            self.connection.send(content: immutablePacket, completion: .contentProcessed { error in
                Task { await completion.resolve(error.map(Result.failure) ?? .success(())) }
            })
        }
    }

    public func receiveLengthPrefixed(maximumLength: Int = maximumMessageLength) async throws -> Data {
        guard maximumLength >= 0, maximumLength <= Self.maximumMessageLength else {
            throw NetworkByteStreamError.invalidMaximumLength(maximumLength)
        }
        let lengthData = try await receiveExactly(4)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumLength) else { throw NetworkByteStreamError.invalidLength(length) }
        return try await receiveExactly(Int(length))
    }

    public func cancel() {
        cancelled = true
        connection.cancel()
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
            let remaining = count - result.count
            let chunk = try await awaitCompletion(completion) {
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error {
                        Task { await completion.resolve(.failure(error)) }
                    } else if let data, !data.isEmpty {
                        Task { await completion.resolve(.success(data)) }
                    } else if complete {
                        Task { await completion.resolve(.failure(NetworkByteStreamError.closed)) }
                    } else {
                        Task { await completion.resolve(.failure(NetworkByteStreamError.closed)) }
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
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Task { await completion.install(continuation) }
                begin()
            }
        }, onCancel: {
            connection.cancel()
            Task { await completion.resolve(.failure(CancellationError())) }
        })
    }
}
