import Foundation
import Network
import Security
import CockpitClientCore

public enum RemoteTransportError: Error, Equatable, Sendable {
    case notConnected
    case invalidPort(UInt16)
    case alreadyConnecting
    case alreadyConnected
    case exchangeInProgress
    case connectionFailed
}

public actor RemoteDirectTransport: CockpitTransport {
    private enum State {
        case disconnected
        case connecting(NWConnectionByteStream, UInt64)
        case connected(NWConnectionByteStream)
        case exchanging(NWConnectionByteStream, UInt64)
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let pinnedCertificateDER: Data
    private let beforeStart: @Sendable () async -> Void
    private var state: State = .disconnected
    private var generation: UInt64 = 0

    public init(host: String, port: UInt16, pinnedCertificateDER: Data) throws {
        try self.init(host: host, port: port, pinnedCertificateDER: pinnedCertificateDER, beforeStart: {})
    }

    init(
        host: String,
        port: UInt16,
        pinnedCertificateDER: Data,
        beforeStart: @escaping @Sendable () async -> Void
    ) throws {
        guard port != 0, let resolvedPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteTransportError.invalidPort(port)
        }
        self.host = NWEndpoint.Host(host)
        self.port = resolvedPort
        self.pinnedCertificateDER = pinnedCertificateDER
        self.beforeStart = beforeStart
    }

    public func connect() async throws {
        switch state {
        case .connecting: throw RemoteTransportError.alreadyConnecting
        case .connected, .exchanging: throw RemoteTransportError.alreadyConnected
        case .disconnected: break
        }
        let parameters = NWParameters(tls: TLSOptionsFactory.client(pinnedCertificateDER: pinnedCertificateDER))
        let stream = NWConnectionByteStream(connection: NWConnection(host: host, port: port, using: parameters))
        generation &+= 1
        let attempt = generation
        state = .connecting(stream, attempt)
        do {
            await beforeStart()
            try await stream.start()
            guard case .connecting(_, attempt) = state else {
                await stream.cancel()
                throw RemoteTransportError.connectionFailed
            }
            state = .connected(stream)
        } catch {
            await stream.cancel()
            if case .connecting(_, let activeAttempt) = state, activeAttempt == attempt {
                state = .disconnected
            }
            throw error
        }
    }

    public func exchangeHandshake(_ request: Data) async throws -> Data {
        let stream: NWConnectionByteStream
        switch state {
        case .connected(let currentStream):
            stream = currentStream
        case .exchanging:
            throw RemoteTransportError.exchangeInProgress
        case .disconnected, .connecting:
            throw RemoteTransportError.notConnected
        }
        generation &+= 1
        let attempt = generation
        state = .exchanging(stream, attempt)
        do {
            try await stream.sendLengthPrefixed(request)
            let response = try await stream.receiveLengthPrefixed()
            guard case .exchanging(_, let activeAttempt) = state, activeAttempt == attempt else {
                throw RemoteTransportError.connectionFailed
            }
            state = .connected(stream)
            return response
        } catch {
            await stream.cancel()
            if case .exchanging(_, let activeAttempt) = state, activeAttempt == attempt {
                state = .disconnected
            }
            throw error
        }
    }

    public func disconnect() async {
        switch state {
        case .connecting(let stream, _), .connected(let stream), .exchanging(let stream, _):
            await stream.cancel()
        case .disconnected:
            break
        }
        state = .disconnected
    }

    public func negotiatedTLSVersion() async -> tls_protocol_version_t? {
        guard case .connected(let stream) = state else { return nil }
        return await stream.negotiatedTLSVersion()
    }
}
