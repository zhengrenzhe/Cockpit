import Foundation
import Darwin
import CockpitClientCore
import CockpitHostCore
import CockpitLocalTransport
import CockpitTerminalClient
import CockpitTerminalCore
import CockpitTypes

enum ProbeError: Error {
    case invalidCommand
    case invalidIdentifier
    case terminalFailure(String)
    case terminalStreamEnded
    case timeout
}

private struct TerminalProbeObservation: Sendable {
    let frame: TerminalOutputFrame
    let foundMarker: Bool
}

@main
enum CockpitProbe {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first {
        case "services":
            try await probeServices()
        case "create-terminal":
            let values = Array(CommandLine.arguments.dropFirst(2))
            guard values.count == 2 || values.count == 3 else {
                throw ProbeError.invalidCommand
            }
            try await createTerminal(
                runtimeDirectory: values[0],
                projectRoot: values[1],
                executablePath: values.count == 3 ? values[2] : nil
            )
        case "terminal-viewer":
            let values = Array(CommandLine.arguments.dropFirst(2))
            guard values.count == 6 || values.count == 7 else {
                throw ProbeError.invalidCommand
            }
            try await terminalViewer(
                runtimeDirectory: values[0],
                sessionValue: values[1],
                projectValue: values[2],
                environmentValue: values[3],
                clientValue: values[4],
                mode: values[5],
                marker: values.count == 7 ? values[6] : nil
            )
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func probeServices() async throws {
        for endpoint in [XPCServiceEndpoint.host, .terminal] {
            let controller = ConnectionController(
                transport: XPCHandshakeClient(endpoint: endpoint),
                deviceID: DeviceID()
            )
            let session = try await controller.connect(
                requestedFeatures: [
                    .workspaceControl,
                    .terminalControl,
                    .terminalFrames,
                ]
            )
            print(
                "\(endpoint.machServiceName) \(session.serviceKind) "
                    + "\(session.version.major).\(session.version.minor)"
            )
        }
    }

    private static func createTerminal(
        runtimeDirectory: String,
        projectRoot: String,
        executablePath: String?
    ) async throws {
        let host = HostXPCClient()
        let bookmark = try URL(
            fileURLWithPath: projectRoot,
            isDirectory: true
        ).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let projects = try await host.listWorkspace()
        let project: ProjectSnapshot
        if let existing = projects.first {
            project = existing
        } else {
            project = try await host.addProject(
                bookmark: bookmark,
                displayName: "Cockpit Phase 0"
            )
        }
        let context = project.resolvedContext
        let transport = HostTerminalControlTransport(
            client: host,
            contextID: context.contextID,
            environmentID: context.environmentID,
            runtimeDirectory: runtimeDirectory
        )
        let record = try await transport.create(TerminalCreateRequest(
            contextID: context.contextID,
            environmentID: context.environmentID,
            kind: executablePath == nil ? .shell : .agent(.codex),
            arguments: [],
            terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: [:],
            idempotencyKey: RequestID()
        ))
        guard let workerID = record.workerID else {
            throw CocoaError(.coderInvalidValue)
        }
        let descriptorPath = URL(
            fileURLWithPath: runtimeDirectory,
            isDirectory: true
        ).appendingPathComponent("\(record.sessionID).\(workerID).json").path
        var fields = [
            "\(record.sessionID)",
            "\(workerID)",
            descriptorPath,
        ]
        if executablePath != nil {
            fields += [
                "\(project.projectID)",
                "\(context.environmentID)",
            ]
        }
        print(fields.joined(separator: "\t"))
    }

    private static func terminalViewer(
        runtimeDirectory: String,
        sessionValue: String,
        projectValue: String,
        environmentValue: String,
        clientValue: String,
        mode: String,
        marker: String?
    ) async throws {
        guard let sessionUUID = UUID(uuidString: sessionValue),
              let projectUUID = UUID(uuidString: projectValue),
              let environmentUUID = UUID(uuidString: environmentValue),
              let clientUUID = UUID(uuidString: clientValue) else {
            throw ProbeError.invalidIdentifier
        }
        let capabilities: TerminalAttachCapabilities
        switch (mode, marker) {
        case ("read", nil):
            capabilities = [.view]
        case ("write", .some):
            capabilities = [.view, .input]
        default:
            throw ProbeError.invalidCommand
        }

        let host = HostXPCClient()
        let contextID = WorkspaceContextID.project(ProjectID(projectUUID))
        let environmentID = EnvironmentID(environmentUUID)
        let clientID = ClientInstanceID(clientUUID)
        let sessionID = TerminalSessionID(sessionUUID)
        let controller = TerminalAttachmentController(
            clientInstanceID: clientID,
            requestedCapabilities: capabilities,
            controlTransport: HostTerminalControlTransport(
                client: host,
                contextID: contextID,
                environmentID: environmentID,
                runtimeDirectory: runtimeDirectory
            ),
            dataTransport: KeeperTerminalDataTransport()
        )
        let events = await controller.events()
        let observation = Task {
            try await terminalObservation(from: events, marker: marker)
        }
        do {
            try await controller.attach(
                sessionID: sessionID,
                lastAcknowledgedSequence: nil
            )
            if let marker {
                try await controller.send(try TerminalInput(
                    validatingContext: RequestContext(
                        validating: .current,
                        clientInstanceID: clientID,
                        windowID: WindowID(),
                        workspaceContextID: contextID,
                        environmentID: environmentID,
                        activeContextGeneration: 1,
                        requestID: RequestID()
                    ),
                    terminalSessionID: sessionID,
                    inputLeaseID: InputLeaseID(),
                    inputSequence: 1,
                    payload: .text("\(marker)\n")
                ))
            }
            let result = try await observation.value
            await controller.detach()
            print([
                "\(clientID)",
                "\(getpid())",
                "\(sessionID)",
                "\(result.frame.outputSequence)",
                result.frame.kind.rawValue,
                result.foundMarker ? marker! : "none",
            ].joined(separator: "\t"))
        } catch {
            observation.cancel()
            await controller.detach()
            throw error
        }
    }

    private static func terminalObservation(
        from events: AsyncStream<TerminalClientEvent>,
        marker: String?
    ) async throws -> TerminalProbeObservation {
        try await withThrowingTaskGroup(of: TerminalProbeObservation.self) { group in
            group.addTask {
                var text = ""
                for await event in events {
                    switch event {
                    case let .frame(_, frame):
                        text += terminalGraphemeText(frame)
                        if marker == nil || text.contains("CONSUMED:\(marker!)") {
                            return TerminalProbeObservation(
                                frame: frame,
                                foundMarker: marker != nil
                            )
                        }
                    case let .failed(_, message):
                        throw ProbeError.terminalFailure(message)
                    case .detached:
                        throw ProbeError.terminalStreamEnded
                    case .attached:
                        continue
                    }
                }
                throw ProbeError.terminalStreamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ProbeError.timeout
            }
            defer { group.cancelAll() }
            guard let observation = try await group.next() else {
                throw ProbeError.terminalStreamEnded
            }
            return observation
        }
    }

    private static func terminalGraphemeText(_ frame: TerminalOutputFrame) -> String {
        var result = ""
        for fragment in frame.fragments where fragment.count >= 36 {
            guard fragment.prefix(4) == Data("CKGF".utf8),
                  let sectionCount = uint32(fragment, at: 32) else { continue }
            var offset = 36
            var cells: [(row: UInt32, column: UInt32, grapheme: UInt32)] = []
            var graphemes: [UInt32: String] = [:]
            for _ in 0..<sectionCount {
                guard offset + 8 <= fragment.count,
                      let length = uint32(fragment, at: offset + 4) else { break }
                let type = fragment[offset]
                let payloadStart = offset + 8
                let payloadEnd = payloadStart + Int(length)
                guard payloadEnd <= fragment.count else { break }
                if type == 4, let count = uint32(fragment, at: payloadStart) {
                    var entry = payloadStart + 4
                    for _ in 0..<count {
                        guard entry + 20 <= payloadEnd,
                              let row = uint32(fragment, at: entry),
                              let column = uint32(fragment, at: entry + 4),
                              let grapheme = uint32(fragment, at: entry + 12) else { break }
                        cells.append((row, column, grapheme))
                        entry += 20
                    }
                } else if type == 5, let count = uint32(fragment, at: payloadStart) {
                    var entry = payloadStart + 4
                    for _ in 0..<count {
                        guard entry + 8 <= payloadEnd,
                              let index = uint32(fragment, at: entry),
                              let byteCount = uint32(fragment, at: entry + 4) else { break }
                        let start = entry + 8
                        let end = start + Int(byteCount)
                        guard end <= payloadEnd else { break }
                        graphemes[index] = String(decoding: fragment[start..<end], as: UTF8.self)
                        entry = end
                    }
                }
                offset = payloadEnd
            }
            for cell in cells.sorted(by: {
                ($0.row, $0.column) < ($1.row, $1.column)
            }) where cell.grapheme != 0 {
                result += graphemes[cell.grapheme] ?? ""
            }
        }
        return result
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}
