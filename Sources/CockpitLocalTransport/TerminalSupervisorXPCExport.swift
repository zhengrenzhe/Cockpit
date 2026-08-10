import Foundation
import CockpitProtocol
import CockpitHostCore
import CockpitTerminalCore
import CockpitTypes

public final class TerminalSupervisorXPCExport:
    NSObject,
    TerminalSupervisorXPCProtocol,
    @unchecked Sendable
{
    public typealias HandshakeHandler =
        @Sendable (CPHandshakeRequest) throws -> CPHandshakeResponse
    public typealias CommandHandler = @Sendable (
        TerminalSupervisorCommandRequest
    ) async throws -> TerminalSupervisorCommandResponse
    public typealias ArchiveHandler = @Sendable (TerminalSessionID) async throws -> FileHandle

    private let handshakeHandler: HandshakeHandler
    private let commandHandler: CommandHandler?
    private let archiveHandler: ArchiveHandler?

    public init(
        handshakeHandler: @escaping HandshakeHandler,
        commandHandler: CommandHandler? = nil,
        archiveHandler: ArchiveHandler? = nil
    ) {
        self.handshakeHandler = handshakeHandler
        self.commandHandler = commandHandler
        self.archiveHandler = archiveHandler
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

    public func openTerminalArchive(
        _ request: Data,
        withReply reply: @escaping (FileHandle?, NSError?) -> Void
    ) {
        let reply = TerminalXPCFileReply(reply)
        guard let archiveHandler else {
            reply.complete(handle: nil, error: CocoaError(.featureUnsupported) as NSError)
            return
        }
        let sessionID: TerminalSessionID
        do { sessionID = try JSONDecoder().decode(TerminalSessionID.self, from: request) }
        catch { reply.complete(handle: nil, error: error as NSError); return }
        Task {
            do { reply.complete(handle: try await archiveHandler(sessionID), error: nil) }
            catch { reply.complete(handle: nil, error: error as NSError) }
        }
    }

    public func terminalCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        guard let commandHandler else {
            reply(nil, CocoaError(.featureUnsupported) as NSError)
            return
        }
        let decoded: TerminalSupervisorCommandRequest
        do {
            decoded = try JSONDecoder().decode(TerminalSupervisorCommandRequest.self, from: request)
        } catch {
            reply(nil, error as NSError)
            return
        }
        let reply = TerminalXPCReply(reply)
        Task {
            do {
                reply.complete(
                    data: try JSONEncoder().encode(try await commandHandler(decoded)),
                    error: nil
                )
            } catch {
                reply.complete(data: nil, error: error as NSError)
            }
        }
    }
}

private final class TerminalXPCFileReply: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((FileHandle?, NSError?) -> Void)?

    init(_ callback: @escaping (FileHandle?, NSError?) -> Void) { self.callback = callback }

    func complete(handle: FileHandle?, error: NSError?) {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?(handle, error)
    }
}

private final class TerminalXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, NSError?) -> Void)?

    init(_ callback: @escaping (Data?, NSError?) -> Void) { self.callback = callback }

    func complete(data: Data?, error: NSError?) {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?(data, error)
    }
}
