import Foundation
import CockpitProtocol
import CockpitTerminalCore

public final class TerminalSupervisorXPCExport:
    NSObject,
    TerminalSupervisorXPCProtocol,
    @unchecked Sendable
{
    public typealias HandshakeHandler =
        @Sendable (CPHandshakeRequest) throws -> CPHandshakeResponse
    public typealias SpawnHandler =
        @Sendable (KeeperProbeRequest) throws -> KeeperLaunchReceipt

    private let handshakeHandler: HandshakeHandler
    private let spawnHandler: SpawnHandler

    public init(
        handshakeHandler: @escaping HandshakeHandler,
        spawnHandler: @escaping SpawnHandler
    ) {
        self.handshakeHandler = handshakeHandler
        self.spawnHandler = spawnHandler
    }

    public func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let decoded = try HandshakeCodec.decodeRequest(request)
            reply(try HandshakeCodec.encode(handshakeHandler(decoded)), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    public func spawnKeeperProbe(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let decoded = try JSONDecoder().decode(KeeperProbeRequest.self, from: request)
            reply(try JSONEncoder().encode(spawnHandler(decoded)), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}
