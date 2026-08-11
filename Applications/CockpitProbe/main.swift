import Foundation
import AppKit
import Darwin
import CockpitClientCore
import CockpitHostCore
import CockpitLocalTransport
import CockpitProtocol
@_spi(CockpitTerminalApp) import CockpitTerminalClient
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
    let text: String
}

private indirect enum ProbeJSONValue: Encodable, Sendable {
    case object([String: ProbeJSONValue])
    case array([ProbeJSONValue])
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)
    case boolean(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsigned(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct ProbeJSONEnvelope: Encodable, Sendable {
    let schemaVersion = 1
    let ok: Bool
    let command: String
    let requestID: String
    let result: ProbeJSONValue?
    let error: ProbeJSONValue?
}

private struct ProbeOptions {
    let values: [String]

    func value(_ name: String) throws -> String {
        guard let index = values.firstIndex(of: name),
              values.indices.contains(index + 1),
              !values[index + 1].hasPrefix("--")
        else { throw ProbeError.invalidCommand }
        return values[index + 1]
    }

    func optional(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name),
              values.indices.contains(index + 1),
              !values[index + 1].hasPrefix("--") else { return nil }
        return values[index + 1]
    }

    func contains(_ name: String) -> Bool { values.contains(name) }
}

private struct PhaseOneAppReceipt: Codable, Sendable {
    let schemaVersion: Int
    let appPID: Int32
    let ready: Bool
    let closedTab: Bool
    let reconnected: Bool
    var applicationWillTerminate: Bool
    let workspaceContextID: String
    let environmentID: String
    let terminalSessionID: String
    let tabID: String?
    let tabCountBefore: Int
    let tabCountAfter: Int
    let error: String?
}

private struct RunOwnedProcessIdentity {
    let processID: Int32
    let auditToken: String
    let executable: String

    private let kernelAuditToken: audit_token_t

    static func capture(
        processID: Int32,
        expectedExecutable: String? = nil
    ) throws -> Self {
        guard processID > 1 else { throw ProbeError.invalidCommand }
        let token = try captureKernelAuditToken(processID: processID)
        let kernelExecutable = try executablePath(auditToken: token)
        let executable = try canonicalExecutable(expectedExecutable ?? kernelExecutable)
        guard kernelExecutable == executable else {
            throw ProbeError.terminalFailure("Process executable identity mismatch")
        }
        return Self(
            processID: processID,
            auditToken: tokenHex(token),
            executable: executable,
            kernelAuditToken: token
        )
    }

    static func validate(
        processID: Int32,
        auditToken: String,
        expectedExecutable: String
    ) throws -> Self {
        guard processID > 1,
              auditToken.count == MemoryLayout<audit_token_t>.size * 2,
              auditToken == auditToken.lowercased()
        else { throw ProbeError.invalidCommand }
        let token = try token(fromHex: auditToken)
        let currentToken = try captureKernelAuditToken(processID: processID)
        guard tokenData(token) == tokenData(currentToken) else {
            throw ProbeError.terminalFailure("Process audit-token identity mismatch")
        }
        let canonicalExecutable = try canonicalExecutable(expectedExecutable)
        guard try executablePath(auditToken: token) == canonicalExecutable else {
            throw ProbeError.terminalFailure("Process executable identity mismatch")
        }
        return Self(
            processID: processID,
            auditToken: auditToken,
            executable: canonicalExecutable,
            kernelAuditToken: token
        )
    }

    func revalidate() throws {
        let currentToken = try Self.captureKernelAuditToken(processID: processID)
        guard Self.tokenData(kernelAuditToken) == Self.tokenData(currentToken),
              try Self.executablePath(auditToken: kernelAuditToken) == executable else {
            throw ProbeError.terminalFailure("Process identity changed")
        }
    }

    func isCurrentProcessExecution() -> Bool {
        var token = kernelAuditToken
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count)) > 0
    }

    func signal(_ signal: Int32) throws {
        try revalidate()
        var token = kernelAuditToken
        let result = proc_signal_with_audittoken(&token, signal)
        guard result == 0 else {
            throw ProbeError.terminalFailure("Exact process signal failed: \(result)")
        }
    }

    var json: ProbeJSONValue {
        .object([
            "processID": .integer(Int64(processID)),
            "auditToken": .string(auditToken),
            "executablePath": .string(executable),
        ])
    }

    private static func captureKernelAuditToken(processID: Int32) throws -> audit_token_t {
        var taskPort: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, processID, &taskPort) == KERN_SUCCESS,
              taskPort != MACH_PORT_NULL else {
            throw ProbeError.terminalFailure("Process audit token is unavailable")
        }
        defer { _ = mach_port_deallocate(mach_task_self_, taskPort) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { info in
                task_info(taskPort, task_flavor_t(TASK_AUDIT_TOKEN), info, &count)
            }
        }
        guard result == KERN_SUCCESS,
              count == mach_msg_type_number_t(
                  MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
              ) else {
            throw ProbeError.terminalFailure("Process audit token lookup failed")
        }
        return token
    }

    private static func executablePath(auditToken: audit_token_t) throws -> String {
        var token = auditToken
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            throw ProbeError.terminalFailure("Process audit-token path lookup failed")
        }
        let bytes = buffer.prefix(Int(length)).prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return try canonicalExecutable(String(decoding: bytes, as: UTF8.self))
    }

    private static func canonicalExecutable(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ProbeError.invalidCommand
        }
        let canonical = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        var status = stat()
        guard lstat(canonical, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              access(canonical, X_OK) == 0 else {
            throw ProbeError.invalidCommand
        }
        return canonical
    }

    private static func tokenData(_ token: audit_token_t) -> Data {
        var value = token
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func tokenHex(_ token: audit_token_t) -> String {
        tokenData(token).map { String(format: "%02x", $0) }.joined()
    }

    private static func token(fromHex value: String) throws -> audit_token_t {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(MemoryLayout<audit_token_t>.size)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw ProbeError.invalidCommand
            }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == MemoryLayout<audit_token_t>.size else {
            throw ProbeError.invalidCommand
        }
        var token = audit_token_t()
        bytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &token) { destination in
                destination.copyBytes(from: source)
            }
        }
        return token
    }
}

@main
enum CockpitProbe {
    private static let jsonClientID = ClientInstanceID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    )
    private static let jsonDeviceID = DeviceID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    )
    private static let jsonWindowID = WindowID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    )

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let first = arguments.first ?? ""
        let jsonCommands: Set<String> = [
            "services", "workspace", "conversation", "terminal", "document", "file", "app",
        ]
        if jsonCommands.contains(first) || ![
            "create-terminal", "terminal-viewer", "context-workflow",
            "conversation-deletion",
        ].contains(first) {
            await runJSON(arguments)
            return
        }
        do {
            try await runLegacy(arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func runLegacy(_ arguments: [String]) async throws {
        switch arguments.first {
        case "create-terminal":
            let values = Array(arguments.dropFirst())
            guard values.count == 2 || values.count == 3 else {
                throw ProbeError.invalidCommand
            }
            try await createTerminal(
                runtimeDirectory: values[0],
                projectRoot: values[1],
                executablePath: values.count == 3 ? values[2] : nil
            )
        case "terminal-viewer":
            let values = Array(arguments.dropFirst())
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
        case "context-workflow":
            let values = Array(arguments.dropFirst())
            guard values.count == 5 else { throw ProbeError.invalidCommand }
            try await contextWorkflow(
                runtimeDirectory: values[0],
                projectRoot: values[1],
                codexExecutablePath: values[2],
                claudeExecutablePath: values[3],
                agentOutputDirectory: values[4]
            )
        case "conversation-deletion":
            let values = Array(arguments.dropFirst())
            guard values.count == 3 else { throw ProbeError.invalidCommand }
            try await conversationDeletion(
                runtimeDirectory: values[0],
                projectRoot: values[1],
                agentExecutablePath: values[2]
            )
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func runJSON(_ arguments: [String]) async {
        let requestID = RequestID().description
        let command: String
        if let first = arguments.first, [
            "workspace", "conversation", "terminal", "document", "file", "app",
        ].contains(first), arguments.count > 1 {
            command = "\(first) \(arguments[1])"
        } else {
            command = arguments.first ?? ""
        }
        do {
            let namespace = try XPCServiceNamespace(
                ProcessInfo.processInfo.environment["COCKPIT_SERVICE_NAMESPACE"] ?? ""
            )
            let result = try await performJSON(
                arguments,
                namespace: namespace
            )
            emit(ProbeJSONEnvelope(
                ok: true,
                command: command,
                requestID: requestID,
                result: result,
                error: nil
            ))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            emit(ProbeJSONEnvelope(
                ok: false,
                command: command,
                requestID: requestID,
                result: nil,
                error: .object([
                    "type": .string(String(describing: type(of: error))),
                    "message": .string(String(describing: error)),
                ])
            ))
            Darwin.exit(1)
        }
    }

    private static func emit(_ envelope: ProbeJSONEnvelope) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope) else { Darwin.exit(70) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func performJSON(
        _ arguments: [String],
        namespace: XPCServiceNamespace
    ) async throws -> ProbeJSONValue {
        guard let group = arguments.first else { throw ProbeError.invalidCommand }
        let host = HostXPCClient(serviceNamespace: namespace)
        switch group {
        case "services":
            guard arguments.count == 1 else { throw ProbeError.invalidCommand }
            var services: [String: ProbeJSONValue] = [:]
            var summaries: [String] = []
            for endpoint in [XPCServiceEndpoint.host, .terminal] {
                let controller = ConnectionController(
                    transport: XPCHandshakeClient(
                        endpoint: endpoint,
                        serviceNamespace: namespace
                    ),
                    deviceID: DeviceID()
                )
                let session = try await controller.connect(
                    requestedFeatures: [
                        .workspaceControl, .terminalControl, .terminalFrames,
                    ]
                )
                let name = endpoint.machServiceName(in: namespace)
                let summary = "\(name) \(session.serviceKind) \(session.version.major).\(session.version.minor)"
                summaries.append(summary)
                let resultKey: String
                switch endpoint {
                case .host: resultKey = "host"
                case .terminal: resultKey = "terminal"
                }
                services[resultKey] = .object([
                    "machServiceName": .string(name),
                    "serviceKind": .string(session.serviceKind),
                    "protocolMajor": .unsigned(UInt64(session.version.major)),
                    "protocolMinor": .unsigned(UInt64(session.version.minor)),
                ])
            }
            services["summary"] = .string(summaries.joined(separator: "\n"))
            return .object(services)
        case "workspace":
            return try await workspaceJSON(arguments, host: host)
        case "conversation":
            return try await conversationJSON(arguments, host: host, namespace: namespace)
        case "terminal":
            return try await terminalJSON(arguments, host: host, namespace: namespace)
        case "document":
            return try await documentJSON(arguments, host: host)
        case "file":
            return try await fileJSON(arguments, host: host)
        case "app":
            return try await appJSON(arguments, namespace: namespace)
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func workspaceJSON(
        _ arguments: [String],
        host: HostXPCClient
    ) async throws -> ProbeJSONValue {
        guard arguments.count >= 2 else { throw ProbeError.invalidCommand }
        switch arguments[1] {
        case "snapshot":
            let projects = try await host.listWorkspace()
            return .object([
                "generation": .unsigned(1),
                "projects": .array(projects.map(projectJSON)),
            ])
        case "add-project":
            let options = ProbeOptions(values: Array(arguments.dropFirst(2)))
            let path = try options.value("--path")
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard root.path == path, FileManager.default.fileExists(atPath: path) else {
                throw ProbeError.invalidCommand
            }
            let bookmark = try root.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let project = try await host.addProject(
                bookmark: bookmark,
                displayName: root.lastPathComponent
            )
            return projectJSON(project)
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func projectJSON(_ project: ProjectSnapshot) -> ProbeJSONValue {
        .object([
            "projectID": .string(project.projectID.description),
            "workspaceContextID": .string(contextString(project.resolvedContext.contextID)),
            "environmentID": .string(project.resolvedContext.environmentID.description),
            "generation": .unsigned(1),
            "conversationCount": .integer(Int64(project.conversations.count)),
        ])
    }

    private static func appJSON(
        _ arguments: [String],
        namespace: XPCServiceNamespace
    ) async throws -> ProbeJSONValue {
        guard arguments.count >= 2,
              !namespace.description.isEmpty,
              ProcessInfo.processInfo.environment["COCKPIT_APPLICATION_SUPPORT_ROOT"]?.isEmpty == false
        else { throw ProbeError.invalidCommand }
        let options = ProbeOptions(values: Array(arguments.dropFirst(2)))
        switch arguments[1] {
        case "launch":
            let executable = try options.value("--executable")
            let receipt = try options.value("--receipt")
            let context = try options.value("--context-id")
            let environment = try options.value("--environment-id")
            let session = try options.value("--session-id")
            let terminalKind = try options.value("--terminal-kind")
            _ = try parseContext(context)
            let _: EnvironmentID = try identifier(environment)
            let _: TerminalSessionID = try identifier(session)
            guard executable.hasPrefix("/"), receipt.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: executable),
                  ["shell", "codex", "claude"].contains(terminalKind),
                  !FileManager.default.fileExists(atPath: receipt)
            else { throw ProbeError.invalidCommand }
            var environmentValues = ProcessInfo.processInfo.environment
            environmentValues["COCKPIT_PHASE1_APP_RECEIPT_PATH"] = receipt
            environmentValues["COCKPIT_PHASE1_APP_CONTEXT_ID"] = context
            environmentValues["COCKPIT_PHASE1_APP_ENVIRONMENT_ID"] = environment
            environmentValues["COCKPIT_PHASE1_APP_TERMINAL_SESSION_ID"] = session
            environmentValues["COCKPIT_PHASE1_APP_TERMINAL_KIND"] = terminalKind
            environmentValues["COCKPIT_PHASE1_APP_CLOSE_TAB"] = options.contains("--close-tab") ? "1" : "0"
            environmentValues["COCKPIT_PHASE1_APP_EXPECT_RECONNECTED"] = options.contains("--expect-reconnected") ? "1" : "0"
            let executableURL = URL(fileURLWithPath: executable).standardizedFileURL
            let contentsURL = executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appURL = contentsURL.deletingLastPathComponent()
            guard contentsURL.lastPathComponent == "Contents", appURL.pathExtension == "app" else {
                throw ProbeError.invalidCommand
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.environment = environmentValues
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            let application = try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
            guard application.executableURL?.standardizedFileURL == executableURL else {
                throw ProbeError.terminalFailure("LaunchServices executable identity mismatch")
            }
            let processIdentity = try RunOwnedProcessIdentity.capture(
                processID: application.processIdentifier,
                expectedExecutable: executable
            )
            return .object([
                "appPID": .integer(Int64(application.processIdentifier)),
                "receipt": .string(receipt),
                "processIdentity": processIdentity.json,
            ])
        case "status":
            let processID = try probeProcessID(options.value("--pid"))
            let receipt = try appReceipt(at: options.value("--receipt"), pid: processID)
            let identity = try RunOwnedProcessIdentity.validate(
                processID: processID,
                auditToken: options.value("--identity-token"),
                expectedExecutable: options.value("--executable")
            )
            guard case let .object(receiptResult) = appReceiptJSON(receipt) else {
                throw ProbeError.terminalFailure("Invalid App receipt result")
            }
            var result = receiptResult
            result["processIdentity"] = identity.json
            return .object(result)
        case "quit":
            let processID = try probeProcessID(options.value("--pid"))
            let receiptPath = try options.value("--receipt")
            _ = try appReceipt(at: receiptPath, pid: processID)
            let identity = try RunOwnedProcessIdentity.validate(
                processID: processID,
                auditToken: options.value("--identity-token"),
                expectedExecutable: options.value("--executable")
            )
            guard let application = NSRunningApplication(processIdentifier: processID),
                  application.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path
                    == identity.executable else {
                throw ProbeError.terminalFailure("App running-instance identity mismatch")
            }
            try identity.revalidate()
            guard application.terminate() else {
                throw ProbeError.terminalFailure("App normal termination was not accepted")
            }
            for _ in 0..<200 {
                if application.isTerminated || !identity.isCurrentProcessExecution() { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard application.isTerminated || !identity.isCurrentProcessExecution() else {
                throw ProbeError.timeout
            }
            var receipt = try appReceipt(at: receiptPath, pid: processID)
            for _ in 0..<200 where !receipt.applicationWillTerminate {
                try await Task.sleep(for: .milliseconds(25))
                receipt = try appReceipt(at: receiptPath, pid: processID)
            }
            guard receipt.applicationWillTerminate else {
                throw ProbeError.terminalFailure("applicationWillTerminate was not observed")
            }
            return .object([
                "appPID": .integer(Int64(processID)),
                "terminated": .boolean(true),
                "applicationWillTerminate": .boolean(true),
                "processIdentity": identity.json,
            ])
        case "crash":
            let processID = try probeProcessID(options.value("--pid"))
            _ = try appReceipt(
                at: options.value("--receipt"),
                pid: processID
            )
            let identity = try RunOwnedProcessIdentity.validate(
                processID: processID,
                auditToken: options.value("--identity-token"),
                expectedExecutable: options.value("--executable")
            )
            try identity.signal(SIGKILL)
            return .object([
                "appPID": .integer(Int64(processID)),
                "signalled": .boolean(true),
                "signal": .integer(Int64(SIGKILL)),
                "processIdentity": identity.json,
            ])
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func probeProcessID(_ value: String) throws -> Int32 {
        guard let processID = Int32(value), processID > 1 else {
            throw ProbeError.invalidCommand
        }
        return processID
    }

    private static func appReceipt(at path: String, pid: Int32) throws -> PhaseOneAppReceipt {
        guard path.hasPrefix("/"),
              let data = FileManager.default.contents(atPath: path) else {
            throw ProbeError.terminalFailure("App receipt is unavailable")
        }
        let receipt = try JSONDecoder().decode(PhaseOneAppReceipt.self, from: data)
        guard receipt.schemaVersion == 1, receipt.appPID == pid else {
            throw ProbeError.terminalFailure("App receipt identity mismatch")
        }
        return receipt
    }

    private static func appReceiptJSON(_ receipt: PhaseOneAppReceipt) -> ProbeJSONValue {
        .object([
            "appPID": .integer(Int64(receipt.appPID)),
            "ready": .boolean(receipt.ready),
            "closedTab": .boolean(receipt.closedTab),
            "reconnected": .boolean(receipt.reconnected),
            "applicationWillTerminate": .boolean(receipt.applicationWillTerminate),
            "workspaceContextID": .string(receipt.workspaceContextID),
            "environmentID": .string(receipt.environmentID),
            "terminalSessionID": .string(receipt.terminalSessionID),
            "tabID": receipt.tabID.map(ProbeJSONValue.string) ?? .null,
            "tabCountBefore": .integer(Int64(receipt.tabCountBefore)),
            "tabCountAfter": .integer(Int64(receipt.tabCountAfter)),
            "error": receipt.error.map(ProbeJSONValue.string) ?? .null,
        ])
    }

    private static func conversationJSON(
        _ arguments: [String],
        host: HostXPCClient,
        namespace: XPCServiceNamespace
    ) async throws -> ProbeJSONValue {
        guard arguments.count >= 2 else { throw ProbeError.invalidCommand }
        let options = ProbeOptions(values: Array(arguments.dropFirst(2)))
        switch arguments[1] {
        case "create":
            let projectID: ProjectID = try identifier(options.value("--project-id"))
            let conversation = try await host.createDirectConversation(projectID: projectID)
            let context = try await host.resolveContext(.conversation(conversation.id))
            return .object([
                "conversationID": .string(conversation.id.description),
                "workspaceContextID": .string(contextString(context.contextID)),
                "environmentID": .string(context.environmentID.description),
                "generation": .unsigned(1),
            ])
        case "rename":
            let conversationID: ConversationID = try identifier(
                options.value("--conversation-id")
            )
            try await host.renameConversation(
                id: conversationID,
                title: options.value("--title")
            )
            let context = try await host.resolveContext(.conversation(conversationID))
            return .object([
                "conversationID": .string(conversationID.description),
                "workspaceContextID": .string(contextString(context.contextID)),
                "environmentID": .string(context.environmentID.description),
                "generation": .unsigned(1),
            ])
        case "delete":
            let conversationID: ConversationID = try identifier(
                options.value("--conversation-id")
            )
            if let value = options.optional("--resume-operation-id") {
                guard options.contains("--force") else { throw ProbeError.invalidCommand }
                let operationID: DeletionOperationID = try identifier(value)
                let final = try await host.resumeConversationDeletion(
                    operationID: operationID,
                    force: true
                )
                guard case let .deleted(projectContextID) = final,
                      case let .project(projectID) = projectContextID,
                      let project = try await host.listWorkspace().first(where: {
                          $0.projectID == projectID
                      }) else {
                    throw ProbeError.terminalFailure("conversation deletion resume incomplete")
                }
                return .object([
                    "deleted": .boolean(true),
                    "operationID": .string(operationID.description),
                    "projectID": .string(projectID.description),
                    "environmentID": .string(
                        project.resolvedContext.environmentID.description
                    ),
                    "workspaceContextID": .string(
                        contextString(.conversation(conversationID))
                    ),
                    "generation": .unsigned(1),
                ])
            }
            let context = try await host.resolveContext(.conversation(conversationID))
            if let value = options.optional("--document-id") {
                let documentID: DocumentID = try identifier(value)
                try await host.saveClientState(try ClientWorkspaceState(
                    validatingKey: ClientWorkspaceStateKey(
                        deviceID: jsonDeviceID,
                        windowID: jsonWindowID,
                        workspaceContextID: context.contextID
                    ),
                    tabs: [try TabRecord(
                        validatingID: TabID(),
                        resource: .file(documentID),
                        fileViewState: .initial()
                    )],
                    selectedTabID: nil,
                    sidebar: SidebarState(isCollapsed: false),
                    splitView: SplitViewState(
                        validatingLeadingPaneWidth: 240,
                        trailingPaneWidth: 300
                    )
                ))
            }
            let impact = try await host.deletionImpact(conversationID: conversationID)
            guard impact.dirtyDocuments.isEmpty,
                  let preparationID = impact.preparationID else {
                let dirtyDocumentID = impact.dirtyDocuments.first?.documentID
                return .object([
                    "deleted": .boolean(false),
                    "dirtyDocumentCount": .integer(Int64(impact.dirtyDocuments.count)),
                    "dirtyDocumentID": dirtyDocumentID.map {
                        .string($0.description)
                    } ?? .null,
                    "workspaceContextID": .string(contextString(context.contextID)),
                    "environmentID": .string(context.environmentID.description),
                    "generation": .unsigned(1),
                ])
            }
            let operationID = DeletionOperationID()
            let progress = try await host.beginConversationDeletion(
                conversationID: conversationID,
                operationID: operationID,
                preparationID: preparationID
            )
            let final: ConversationDeletionProgress
            switch progress {
            case .forceConfirmationRequired:
                guard options.contains("--force") else {
                    return .object([
                        "deleted": .boolean(false),
                        "forceRequired": .boolean(true),
                        "normalTerminationAttempted": .boolean(true),
                        "operationID": .string(operationID.description),
                        "workspaceContextID": .string(contextString(context.contextID)),
                        "environmentID": .string(context.environmentID.description),
                        "generation": .unsigned(1),
                    ])
                }
                final = try await host.resumeConversationDeletion(
                    operationID: operationID,
                    force: true
                )
            default:
                final = progress
            }
            guard case .deleted = final else {
                throw ProbeError.terminalFailure("conversation deletion incomplete")
            }
            return .object([
                "deleted": .boolean(true),
                "operationID": .string(operationID.description),
                "projectID": .string(context.projectID.description),
                "environmentID": .string(context.environmentID.description),
                "workspaceContextID": .string(contextString(context.contextID)),
                "generation": .unsigned(1),
            ])
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func terminalJSON(
        _ arguments: [String],
        host: HostXPCClient,
        namespace: XPCServiceNamespace
    ) async throws -> ProbeJSONValue {
        guard arguments.count >= 2 else { throw ProbeError.invalidCommand }
        let options = ProbeOptions(values: Array(arguments.dropFirst(2)))
        let contextID = try parseContext(options.value("--context-id"))
        let environmentID: EnvironmentID = try identifier(
            options.value("--environment-id")
        )
        let runtimeRoot = ProcessInfo.processInfo.environment[
            "COCKPIT_TERMINAL_RUNTIME_ROOT"
        ] ?? "/private/tmp/cockpit.\(geteuid())/terminal"
        let transport = HostTerminalControlTransport(
            client: host,
            contextID: contextID,
            environmentID: environmentID,
            runtimeDirectory: runtimeRoot
        )
        switch arguments[1] {
        case "create":
            let kindValue = try options.value("--kind")
            let kind: TerminalKind
            switch kindValue {
            case "shell": kind = .shell
            case "codex": kind = .agent(.codex)
            case "claude": kind = .agent(.claude)
            default: throw ProbeError.invalidCommand
            }
            let executable = options.optional("--resolved-executable")
            if executable != nil {
                guard ProcessInfo.processInfo.environment[
                    "COCKPIT_APPLICATION_SUPPORT_ROOT"
                ]?.isEmpty == false,
                !namespace.description.isEmpty,
                let executable,
                executable.hasPrefix("/"),
                FileManager.default.isExecutableFile(atPath: executable),
                kind != .shell else { throw ProbeError.invalidCommand }
            }
            let session = try await transport.create(TerminalCreateRequest(
                contextID: contextID,
                environmentID: environmentID,
                kind: kind,
                arguments: [],
                terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
                environmentOverrides: [:],
                idempotencyKey: RequestID(),
                selectedExecutableBookmark: executable.map(testResolvedExecutableToken)
            ))
            return try await terminalInspectionJSON(
                sessionID: session.sessionID,
                contextID: contextID,
                environmentID: environmentID,
                runtimeRoot: runtimeRoot,
                namespace: namespace
            )
        case "list":
            return .object([
                "workspaceContextID": .string(contextString(contextID)),
                "environmentID": .string(environmentID.description),
                "generation": .unsigned(1),
                "sessions": .array(try await transport.list().map {
                    terminalSessionJSON(
                        $0,
                        keeperProcessIdentity: nil,
                        cliProcessIdentity: nil
                    )
                }),
            ])
        case "inspect":
            let sessionID: TerminalSessionID = try identifier(
                options.value("--session-id")
            )
            return try await terminalInspectionJSON(
                sessionID: sessionID,
                contextID: contextID,
                environmentID: environmentID,
                runtimeRoot: runtimeRoot,
                namespace: namespace
            )
        case "attach", "input":
            let sessionID: TerminalSessionID = try identifier(
                options.value("--session-id")
            )
            let inputText = arguments[1] == "input" ? try options.value("--text") : nil
            let expectedOutput = inputText.map {
                options.optional("--expect-output") ?? "CONSUMED:\($0)"
            } ?? options.optional("--expect-output")
            let lastAcknowledgedSequence: UInt64?
            if let value = options.optional("--last-ack") {
                guard arguments[1] == "attach", let parsed = UInt64(value) else {
                    throw ProbeError.invalidCommand
                }
                lastAcknowledgedSequence = parsed
            } else {
                lastAcknowledgedSequence = nil
            }
            let observation = try await terminalJSONObservation(
                transport: transport,
                contextID: contextID,
                environmentID: environmentID,
                sessionID: sessionID,
                inputText: inputText,
                expectedOutput: expectedOutput,
                lastAcknowledgedSequence: lastAcknowledgedSequence
            )
            guard case let .object(inspection) = try await terminalInspectionJSON(
                sessionID: sessionID,
                contextID: contextID,
                environmentID: environmentID,
                runtimeRoot: runtimeRoot,
                namespace: namespace
            ) else { throw ProbeError.terminalFailure("invalid inspection") }
            var result = inspection
            result["latestSequence"] = .unsigned(observation.frame.outputSequence)
            result["frameKind"] = .string(observation.frame.kind.rawValue)
            result["output"] = .string(observation.text)
            return .object(result)
        case "terminate":
            let sessionID: TerminalSessionID = try identifier(
                options.value("--session-id")
            )
            let controller = TerminalAttachmentController(
                clientInstanceID: ClientInstanceID(),
                requestedCapabilities: [.view, .terminate],
                controlTransport: transport,
                dataTransport: KeeperTerminalDataTransport()
            )
            do {
                try await controller.attach(
                    sessionID: sessionID,
                    lastAcknowledgedSequence: nil
                )
                try await controller.terminate(force: options.contains("--force"))
                await controller.detach()
            } catch {
                await controller.detach()
                throw error
            }
            return try await terminalInspectionJSON(
                sessionID: sessionID,
                contextID: contextID,
                environmentID: environmentID,
                runtimeRoot: runtimeRoot,
                namespace: namespace
            )
        case "crash-keeper":
            let sessionID: TerminalSessionID = try identifier(
                options.value("--session-id")
            )
            let expectedWorkerID: WorkerInstanceID = try identifier(
                options.value("--worker-id")
            )
            let expectedKeeperPID = try probeProcessID(options.value("--pid"))
            let supervisor = TerminalSupervisorControlTransport(
                client: TerminalSupervisorXPCClient(serviceNamespace: namespace)
            )
            guard let record = try await supervisor.list(contextID: contextID)
                .first(where: { $0.sessionID == sessionID }),
                  record.contextID == contextID,
                  record.environmentID == environmentID,
                  record.workerID == expectedWorkerID else {
                throw ProbeError.terminalFailure("Terminal worker identity mismatch")
            }
            let descriptorURL = URL(fileURLWithPath: runtimeRoot, isDirectory: true)
                .appendingPathComponent("\(sessionID).\(expectedWorkerID).json")
            let descriptor = try JSONDecoder().decode(
                KeeperRuntimeDescriptor.self,
                from: Data(contentsOf: descriptorURL)
            )
            guard descriptor.sessionID == sessionID,
                  descriptor.workerInstanceID == expectedWorkerID,
                  descriptor.processID == expectedKeeperPID else {
                throw ProbeError.terminalFailure("Keeper descriptor identity mismatch")
            }
            let identity = try RunOwnedProcessIdentity.validate(
                processID: expectedKeeperPID,
                auditToken: options.value("--identity-token"),
                expectedExecutable: options.value("--executable")
            )
            try identity.signal(SIGKILL)
            return .object([
                "terminalSessionID": .string(sessionID.description),
                "workerInstanceID": .string(expectedWorkerID.description),
                "keeperPID": .integer(Int64(expectedKeeperPID)),
                "signalled": .boolean(true),
                "signal": .integer(Int64(SIGKILL)),
                "keeperProcessIdentity": identity.json,
            ])
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func documentJSON(
        _ arguments: [String],
        host: HostXPCClient
    ) async throws -> ProbeJSONValue {
        guard arguments.count >= 2 else { throw ProbeError.invalidCommand }
        let options = ProbeOptions(values: Array(arguments.dropFirst(2)))
        let contextID = try parseContext(options.value("--context-id"))
        let environmentID: EnvironmentID = try identifier(
            options.value("--environment-id")
        )
        let clientID = jsonClientID
        let client = HostDataPlaneClient(
            binding: try HostDataPlaneBinding(
                validatingClientInstanceID: clientID,
                windowID: WindowID(),
                workspaceContextID: contextID,
                environmentID: environmentID,
                activeContextGeneration: 1
            ),
            xpcClient: host
        )
        let snapshot: DocumentSnapshot
        switch arguments[1] {
        case "open":
            snapshot = try await client.openDocument(
                in: environmentID,
                at: RelativePath(options.value("--path"))
            )
        case "snapshot":
            let documentID: DocumentID = try identifier(
                options.value("--document-id")
            )
            snapshot = try await client.snapshot(documentID: documentID)
        case "edit":
            let documentID: DocumentID = try identifier(
                options.value("--document-id")
            )
            let current = try await client.snapshot(documentID: documentID)
            let lease = try await client.acquireEditLease(
                documentID: documentID,
                client: clientID
            )
            guard let offset = UInt64(try options.value("--offset")),
                  let length = UInt64(try options.value("--length")) else {
                throw ProbeError.invalidCommand
            }
            let acknowledgement = try await client.apply(EditTransaction(
                validatingDocumentID: documentID,
                editLeaseID: lease.id,
                baseVersion: current.documentVersion,
                clientSequence: current.lastAcceptedClientSequence + 1,
                changes: [try UTF16TextEdit(
                    validatingOffset: offset,
                    length: length,
                    replacement: options.value("--text")
                )]
            ))
            snapshot = try await client.snapshot(documentID: acknowledgement.documentID)
        case "save":
            let documentID: DocumentID = try identifier(
                options.value("--document-id")
            )
            let current = try await client.snapshot(documentID: documentID)
            _ = try await client.acquireEditLease(
                documentID: documentID,
                client: clientID
            )
            guard let fingerprint = current.observedDiskFingerprint else {
                throw ProbeError.terminalFailure("document fingerprint unavailable")
            }
            snapshot = try await client.save(
                documentID: documentID,
                expectedFingerprint: fingerprint
            )
        default:
            throw ProbeError.invalidCommand
        }
        await client.disconnect()
        return documentSnapshotJSON(snapshot, contextID: contextID)
    }

    private static func documentSnapshotJSON(
        _ snapshot: DocumentSnapshot,
        contextID: WorkspaceContextID
    ) -> ProbeJSONValue {
        .object([
            "workspaceContextID": .string(contextString(contextID)),
            "environmentID": .string(snapshot.environmentID.description),
            "generation": .unsigned(1),
            "documentID": .string(snapshot.documentID.description),
            "version": .unsigned(snapshot.documentVersion),
            "persistedVersion": .unsigned(snapshot.persistedVersion),
            "path": .string(snapshot.relativePath.string),
            "dirtyState": .string(snapshot.dirtyState.rawValue),
            "text": .string(snapshot.text),
        ])
    }

    private static func fileJSON(
        _ arguments: [String],
        host: HostXPCClient
    ) async throws -> ProbeJSONValue {
        guard arguments.count >= 2 else { throw ProbeError.invalidCommand }
        let options = ProbeOptions(values: Array(arguments.dropFirst(2)))
        let contextID = try parseContext(options.value("--context-id"))
        let environmentID: EnvironmentID = try identifier(
            options.value("--environment-id")
        )
        let pathValue = try options.value("--path")
        if arguments[1] == "tree" {
            let client = HostDataPlaneClient(
                binding: try HostDataPlaneBinding(
                    validatingClientInstanceID: ClientInstanceID(),
                    windowID: WindowID(),
                    workspaceContextID: contextID,
                    environmentID: environmentID,
                    activeContextGeneration: 1
                ),
                xpcClient: host
            )
            let directory: WorkspaceDirectory = pathValue == "."
                ? .root : .relative(try RelativePath(pathValue))
            let tree = try await client.children(at: directory)
            let result: ProbeJSONValue = .object([
                "workspaceContextID": .string(contextString(contextID)),
                "environmentID": .string(tree.environmentID.description),
                "generation": .unsigned(tree.generation),
                "revision": .unsigned(tree.revision),
                "entries": .array(tree.children.map {
                    .object([
                        "environmentID": .string($0.identity.environmentID.description),
                        "path": .string($0.identity.path.string),
                        "kind": .string(fileKindString($0.kind)),
                    ])
                }),
            ])
            await client.disconnect()
            return result
        }

        let operation: FileOperation
        switch arguments[1] {
        case "create", "mkdir":
            let path = try RelativePath(pathValue)
            let components = path.string.split(separator: "/")
            guard let name = components.last.map(String.init) else {
                throw ProbeError.invalidCommand
            }
            let parent: WorkspaceDirectory
            if components.count == 1 {
                parent = .root
            } else {
                parent = .relative(try RelativePath(
                    components.dropLast().joined(separator: "/")
                ))
            }
            operation = arguments[1] == "create"
                ? .createFile(parent: parent, name: name)
                : .createDirectory(parent: parent, name: name)
        case "move":
            let destinationValue = try options.value("--destination")
            operation = .move(
                source: try RelativePath(pathValue),
                destinationDirectory: destinationValue == "."
                    ? .root : .relative(try RelativePath(destinationValue))
            )
        case "rename":
            operation = .rename(
                source: try RelativePath(pathValue),
                newName: try options.value("--name")
            )
        case "trash":
            operation = .trash(path: try RelativePath(pathValue))
        default:
            throw ProbeError.invalidCommand
        }
        let result = try await host.performFileOperation(
            context: try RequestContext(
                validating: .current,
                clientInstanceID: ClientInstanceID(),
                windowID: WindowID(),
                workspaceContextID: contextID,
                environmentID: environmentID,
                activeContextGeneration: 1,
                requestID: RequestID()
            ),
            operation: operation
        )
        let resultPath: String
        switch result {
        case let .created(path, _): resultPath = path.string
        case let .relocated(_, to): resultPath = to.string
        case let .trashed(path): resultPath = path.string
        }
        return .object([
            "workspaceContextID": .string(contextString(contextID)),
            "environmentID": .string(environmentID.description),
            "generation": .unsigned(1),
            "path": .string(resultPath),
        ])
    }

    private static func terminalJSONObservation(
        transport: HostTerminalControlTransport,
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        sessionID: TerminalSessionID,
        inputText: String?,
        expectedOutput: String?,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> TerminalProbeObservation {
        let clientID = ClientInstanceID()
        let controller = TerminalAttachmentController(
            clientInstanceID: clientID,
            requestedCapabilities: inputText == nil ? [.view] : [.view, .input],
            controlTransport: transport,
            dataTransport: KeeperTerminalDataTransport()
        )
        let events = await controller.events()
        let observation = Task {
            try await terminalObservation(from: events, expectedText: expectedOutput)
        }
        do {
            try await controller.attach(
                sessionID: sessionID,
                lastAcknowledgedSequence: lastAcknowledgedSequence
            )
            if let inputText {
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
                    payload: .text("\(inputText)\n")
                ))
            }
            let result = try await observation.value
            await controller.detach()
            return result
        } catch {
            observation.cancel()
            await controller.detach()
            throw error
        }
    }

    private static func terminalInspectionJSON(
        sessionID: TerminalSessionID,
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        runtimeRoot: String,
        namespace: XPCServiceNamespace
    ) async throws -> ProbeJSONValue {
        let supervisor = TerminalSupervisorControlTransport(
            client: TerminalSupervisorXPCClient(serviceNamespace: namespace)
        )
        guard let record = try await supervisor.list(contextID: contextID)
            .first(where: { $0.sessionID == sessionID }),
              record.environmentID == environmentID,
              let workerID = record.workerID else {
            throw ProbeError.terminalFailure("terminal session not found")
        }
        let descriptor = URL(fileURLWithPath: runtimeRoot, isDirectory: true)
            .appendingPathComponent("\(sessionID).\(workerID).json")
        let descriptorValue: KeeperRuntimeDescriptor?
        if let data = try? Data(contentsOf: descriptor),
           let value = try? JSONDecoder().decode(KeeperRuntimeDescriptor.self, from: data) {
            guard value.sessionID == sessionID,
                  value.workerInstanceID == workerID else {
                throw ProbeError.terminalFailure("Keeper descriptor identity mismatch")
            }
            descriptorValue = value
        } else {
            descriptorValue = nil
        }
        return try terminalRecordJSON(record, descriptor: descriptorValue)
    }

    private static func terminalSessionJSON(
        _ session: ClientTerminalSession,
        keeperProcessIdentity: RunOwnedProcessIdentity?,
        cliProcessIdentity: RunOwnedProcessIdentity?
    ) -> ProbeJSONValue {
        var result: [String: ProbeJSONValue] = [
            "terminalSessionID": .string(session.sessionID.description),
            "workspaceContextID": .string(contextString(session.contextID)),
            "environmentID": .string(session.environmentID.description),
            "generation": .unsigned(1),
            "workerInstanceID": session.workerID.map { .string($0.description) } ?? .null,
            "lifecycleState": .string(session.lifecycleState.rawValue),
            "terminalKind": .string(terminalKindString(session.kind)),
            "exitStatus": session.exitStatus.map { .integer(Int64($0)) } ?? .null,
            "latestSequence": .unsigned(session.latestSequence),
        ]
        result["keeperPID"] = keeperProcessIdentity.map {
            .integer(Int64($0.processID))
        } ?? .null
        result["cliPID"] = cliProcessIdentity.map {
            .integer(Int64($0.processID))
        } ?? .null
        result["keeperProcessIdentity"] = keeperProcessIdentity?.json ?? .null
        result["cliProcessIdentity"] = cliProcessIdentity?.json ?? .null
        return .object(result)
    }

    private static func terminalRecordJSON(
        _ record: TerminalSessionRecord,
        descriptor: KeeperRuntimeDescriptor?
    ) throws -> ProbeJSONValue {
        let session = try ClientTerminalSession(validating: record)
        let keeperProcessIdentity = descriptor.flatMap {
            try? RunOwnedProcessIdentity.capture(processID: $0.processID)
        }
        let launchSpec = try JSONDecoder().decode(LaunchSpec.self, from: record.launchSpecData)
        let cliProcessIdentity = record.processIdentity.flatMap {
            try? RunOwnedProcessIdentity.capture(
                processID: $0.processID,
                expectedExecutable: launchSpec.executablePath
            )
        }
        return terminalSessionJSON(
            session,
            keeperProcessIdentity: keeperProcessIdentity,
            cliProcessIdentity: cliProcessIdentity
        )
    }

    private static func contextString(_ context: WorkspaceContextID) -> String {
        switch context {
        case let .project(id): "project:\(id)"
        case let .conversation(id): "conversation:\(id)"
        }
    }

    private static func parseContext(_ value: String) throws -> WorkspaceContextID {
        if value.hasPrefix("project:") {
            let id: ProjectID = try identifier(String(value.dropFirst(8)))
            return .project(id)
        }
        if value.hasPrefix("conversation:") {
            let id: ConversationID = try identifier(String(value.dropFirst(13)))
            return .conversation(id)
        }
        throw ProbeError.invalidIdentifier
    }

    private static func identifier<Scope>(_ value: String) throws -> CockpitID<Scope> {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw ProbeError.invalidIdentifier
        }
        return CockpitID<Scope>(uuid)
    }

    private static func fileKindString(_ kind: FileTreeEntryKind) -> String {
        switch kind {
        case .file: "file"
        case .directory: "directory"
        case .symbolicLink: "symbolicLink"
        }
    }

    private static func terminalKindString(_ kind: TerminalKind) -> String {
        switch kind {
        case .shell: "shell"
        case .agent(.codex): "codex"
        case .agent(.claude): "claude"
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
            idempotencyKey: RequestID(),
            selectedExecutableBookmark: try executablePath.map {
                try URL(fileURLWithPath: $0).bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
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

    private static func contextWorkflow(
        runtimeDirectory: String,
        projectRoot: String,
        codexExecutablePath: String,
        claudeExecutablePath: String,
        agentOutputDirectory: String
    ) async throws {
        let host = HostXPCClient()
        guard try await host.listWorkspace().isEmpty else {
            throw ProbeError.terminalFailure("workspace fixture is not empty")
        }
        let projectBookmark = try URL(
            fileURLWithPath: projectRoot,
            isDirectory: true
        ).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let codexBookmark = try executableBookmark(path: codexExecutablePath)
        let claudeBookmark = try executableBookmark(path: claudeExecutablePath)
        let project = try await host.addProject(
            bookmark: projectBookmark,
            displayName: "Task 18 Project"
        )
        guard project.conversations.isEmpty else {
            throw ProbeError.terminalFailure("project unexpectedly created a conversation")
        }
        let conversationOne = try await host.createDirectConversation(
            projectID: project.projectID
        )
        try await host.renameConversation(
            id: conversationOne.id,
            title: "Task 18 One"
        )
        let conversationTwo = try await host.createDirectConversation(
            projectID: project.projectID
        )
        let projectContext = project.resolvedContext
        let firstContext = try await host.resolveContext(.conversation(conversationOne.id))
        let secondContext = try await host.resolveContext(.conversation(conversationTwo.id))
        guard projectContext.projectID == project.projectID,
              firstContext.projectID == project.projectID,
              secondContext.projectID == project.projectID,
              projectContext.environmentID == firstContext.environmentID,
              firstContext.environmentID == secondContext.environmentID,
              firstContext.conversationID == conversationOne.id,
              secondContext.conversationID == conversationTwo.id
        else { throw ProbeError.terminalFailure("context binding mismatch") }

        let projectTerminal = HostTerminalControlTransport(
            client: host,
            contextID: projectContext.contextID,
            environmentID: projectContext.environmentID,
            runtimeDirectory: runtimeDirectory
        )
        let firstTerminal = HostTerminalControlTransport(
            client: host,
            contextID: firstContext.contextID,
            environmentID: firstContext.environmentID,
            runtimeDirectory: runtimeDirectory
        )
        let secondTerminal = HostTerminalControlTransport(
            client: host,
            contextID: secondContext.contextID,
            environmentID: secondContext.environmentID,
            runtimeDirectory: runtimeDirectory
        )
        let projectShell = try await createWorkflowTerminal(
            transport: projectTerminal,
            context: projectContext,
            kind: .shell,
            executableBookmark: nil,
            agentOutputPath: nil
        )
        let firstCodex = try await createWorkflowTerminal(
            transport: firstTerminal,
            context: firstContext,
            kind: .agent(.codex),
            executableBookmark: codexBookmark,
            agentOutputPath: URL(
                fileURLWithPath: agentOutputDirectory,
                isDirectory: true
            ).appendingPathComponent("conversation-one-codex").path
        )
        let firstClaude = try await createWorkflowTerminal(
            transport: firstTerminal,
            context: firstContext,
            kind: .agent(.claude),
            executableBookmark: claudeBookmark,
            agentOutputPath: URL(
                fileURLWithPath: agentOutputDirectory,
                isDirectory: true
            ).appendingPathComponent("conversation-one-claude").path
        )
        let firstShell = try await createWorkflowTerminal(
            transport: firstTerminal,
            context: firstContext,
            kind: .shell,
            executableBookmark: nil,
            agentOutputPath: nil
        )
        let secondCodex = try await createWorkflowTerminal(
            transport: secondTerminal,
            context: secondContext,
            kind: .agent(.codex),
            executableBookmark: codexBookmark,
            agentOutputPath: URL(
                fileURLWithPath: agentOutputDirectory,
                isDirectory: true
            ).appendingPathComponent("conversation-two-codex").path
        )
        let exited = try await waitForWorkflowFinalSession(
            firstCodex.sessionID,
            transport: firstTerminal
        )
        guard exited.exitStatus == 0, exited.kind == .agent(.codex) else {
            throw ProbeError.terminalFailure("agent exit record mismatch")
        }
        _ = try await waitForWorkflowFinalSession(
            firstClaude.sessionID,
            transport: firstTerminal
        )
        _ = try await waitForWorkflowFinalSession(
            secondCodex.sessionID,
            transport: secondTerminal
        )
        let restarted = try await createWorkflowTerminal(
            transport: firstTerminal,
            context: firstContext,
            kind: .agent(.codex),
            executableBookmark: codexBookmark,
            agentOutputPath: URL(
                fileURLWithPath: agentOutputDirectory,
                isDirectory: true
            ).appendingPathComponent("conversation-one-codex-restart").path
        )
        _ = try await waitForWorkflowFinalSession(
            restarted.sessionID,
            transport: firstTerminal
        )

        let projectSessions = try await projectTerminal.list()
        let firstSessions = try await firstTerminal.list()
        let secondSessions = try await secondTerminal.list()
        guard projectSessions.map(\.sessionID) == [projectShell.sessionID],
              Set(firstSessions.map(\.sessionID)) == Set([
                  firstCodex.sessionID,
                  firstClaude.sessionID,
                  firstShell.sessionID,
                  restarted.sessionID,
              ]),
              secondSessions.map(\.sessionID) == [secondCodex.sessionID]
        else { throw ProbeError.terminalFailure("context terminal isolation mismatch") }
        let workspace = try await host.listWorkspace()
        guard workspace.count == 1,
              workspace[0].conversations.count == 2,
              workspace[0].conversations.first(where: { $0.id == conversationOne.id })?.title
                == "Task 18 One"
        else { throw ProbeError.terminalFailure("workspace workflow mismatch") }

        print([
            project.projectID.description,
            projectContext.environmentID.description,
            conversationOne.id.description,
            conversationTwo.id.description,
            projectShell.sessionID.description,
            firstCodex.sessionID.description,
            firstClaude.sessionID.description,
            firstShell.sessionID.description,
            secondCodex.sessionID.description,
            exited.sessionID.description,
            String(exited.exitStatus!),
            restarted.sessionID.description,
            String(projectSessions.count),
            String(firstSessions.count),
            String(secondSessions.count),
        ].joined(separator: "\t"))
    }

    private static func conversationDeletion(
        runtimeDirectory: String,
        projectRoot: String,
        agentExecutablePath: String
    ) async throws {
        let host = HostXPCClient()
        guard try await host.listWorkspace().isEmpty else {
            throw ProbeError.terminalFailure("workspace fixture is not empty")
        }
        let bookmark = try URL(
            fileURLWithPath: projectRoot,
            isDirectory: true
        ).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let project = try await host.addProject(
            bookmark: bookmark,
            displayName: "Task 19 Project"
        )
        let deletedConversation = try await host.createDirectConversation(
            projectID: project.projectID
        )
        let retainedConversation = try await host.createDirectConversation(
            projectID: project.projectID
        )
        let deletedContext = try await host.resolveContext(
            .conversation(deletedConversation.id)
        )
        let retainedContext = try await host.resolveContext(
            .conversation(retainedConversation.id)
        )
        let agentBookmark = try executableBookmark(path: agentExecutablePath)
        let targetAgentOutput = URL(
            fileURLWithPath: projectRoot,
            isDirectory: true
        ).appendingPathComponent("deletion-target-agent.log").path
        let retainedAgentOutput = URL(
            fileURLWithPath: projectRoot,
            isDirectory: true
        ).appendingPathComponent("deletion-retained-agent.log").path
        let deletedTerminals = HostTerminalControlTransport(
            client: host,
            contextID: deletedContext.contextID,
            environmentID: deletedContext.environmentID,
            runtimeDirectory: runtimeDirectory
        )
        let retainedTerminals = HostTerminalControlTransport(
            client: host,
            contextID: retainedContext.contextID,
            environmentID: retainedContext.environmentID,
            runtimeDirectory: runtimeDirectory
        )
        let deletedSession = try await createWorkflowTerminal(
            transport: deletedTerminals,
            context: deletedContext,
            kind: .agent(.codex),
            executableBookmark: agentBookmark,
            agentOutputPath: nil,
            arguments: [targetAgentOutput, "--wait-with-child"]
        )
        try await waitForWorkflowAgentMarker(
            path: targetAgentOutput,
            prefix: "child="
        )
        let retainedSession = try await createWorkflowTerminal(
            transport: retainedTerminals,
            context: retainedContext,
            kind: .agent(.codex),
            executableBookmark: agentBookmark,
            agentOutputPath: nil,
            arguments: [retainedAgentOutput]
        )
        _ = try await waitForWorkflowFinalSession(
            retainedSession.sessionID,
            transport: retainedTerminals
        )

        let deviceID = DeviceID()
        let windowID = WindowID()
        let projectState = try emptyClientState(
            deviceID: deviceID,
            windowID: windowID,
            contextID: project.resolvedContext.contextID
        )
        let deletedState = try emptyClientState(
            deviceID: deviceID,
            windowID: windowID,
            contextID: deletedContext.contextID
        )
        try await host.saveClientState(projectState)
        try await host.saveClientState(deletedState)

        let impact = try await host.deletionImpact(
            conversationID: deletedConversation.id
        )
        guard impact.dirtyDocuments.isEmpty else {
            throw ProbeError.terminalFailure("unexpected dirty deletion impact")
        }
        let operationID = DeletionOperationID()
        guard let preparationID = impact.preparationID else {
            throw ProbeError.terminalFailure("missing deletion preparation")
        }
        let firstProgress = try await host.beginConversationDeletion(
            conversationID: deletedConversation.id,
            operationID: operationID,
            preparationID: preparationID
        )
        guard case let .forceConfirmationRequired(returnedOperation, activeSessions)
            = firstProgress,
            returnedOperation == operationID,
            activeSessions == [deletedSession.sessionID]
        else {
            throw ProbeError.terminalFailure("normal termination did not require force")
        }

        let createBlocked: Bool
        do {
            _ = try await createWorkflowTerminal(
                transport: deletedTerminals,
                context: deletedContext,
                kind: .agent(.codex),
                executableBookmark: agentBookmark,
                agentOutputPath: nil,
                arguments: [
                    URL(
                        fileURLWithPath: projectRoot,
                        isDirectory: true
                    ).appendingPathComponent("deletion-blocked-agent.log").path,
                ]
            )
            createBlocked = false
        } catch {
            createBlocked = true
        }

        let finalProgress = try await host.resumeConversationDeletion(
            operationID: operationID,
            force: true
        )
        guard finalProgress == .deleted(
            projectContextID: project.resolvedContext.contextID
        ) else {
            throw ProbeError.terminalFailure("forced deletion did not complete")
        }

        let workspace = try await host.listWorkspace()
        guard workspace.count == 1,
              workspace[0].projectID == project.projectID,
              workspace[0].resolvedContext.environmentID == project.resolvedContext.environmentID,
              workspace[0].conversations.map(\.id) == [retainedConversation.id]
        else {
            throw ProbeError.terminalFailure("workspace deletion scope mismatch")
        }
        let supervisor = TerminalSupervisorControlTransport()
        let deletedRecords = try await supervisor.list(contextID: deletedContext.contextID)
        let retainedRecords = try await supervisor.list(contextID: retainedContext.contextID)
        guard deletedRecords.isEmpty,
              retainedRecords.map(\.sessionID) == [retainedSession.sessionID],
              try await host.loadClientState(deletedState.key) == nil,
              try await host.loadClientState(projectState.key) == projectState
        else {
            throw ProbeError.terminalFailure("durable deletion scope mismatch")
        }

        print([
            project.projectID.description,
            project.resolvedContext.environmentID.description,
            deletedConversation.id.description,
            retainedConversation.id.description,
            deletedSession.sessionID.description,
            retainedSession.sessionID.description,
            operationID.description,
            createBlocked ? "1" : "0",
            String(workspace[0].conversations.count),
            String(deletedRecords.count),
            String(retainedRecords.count),
        ].joined(separator: "\t"))
    }

    private static func createWorkflowTerminal(
        transport: HostTerminalControlTransport,
        context: ResolvedWorkspaceContext,
        kind: TerminalKind,
        executableBookmark: Data?,
        agentOutputPath: String?,
        arguments: [String]? = nil
    ) async throws -> ClientTerminalSession {
        let session = try await transport.create(TerminalCreateRequest(
            contextID: context.contextID,
            environmentID: context.environmentID,
            kind: kind,
            arguments: arguments ?? agentOutputPath.map { [$0] } ?? [],
            terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: [:],
            idempotencyKey: RequestID(),
            selectedExecutableBookmark: executableBookmark
        ))
        guard session.contextID == context.contextID,
              session.environmentID == context.environmentID,
              session.kind == kind
        else { throw ProbeError.terminalFailure("created terminal binding mismatch") }
        return session
    }

    private static func emptyClientState(
        deviceID: DeviceID,
        windowID: WindowID,
        contextID: WorkspaceContextID
    ) throws -> ClientWorkspaceState {
        try ClientWorkspaceState(
            validatingKey: ClientWorkspaceStateKey(
                deviceID: deviceID,
                windowID: windowID,
                workspaceContextID: contextID
            ),
            tabs: [],
            selectedTabID: nil,
            sidebar: SidebarState(isCollapsed: false),
            splitView: SplitViewState(
                validatingLeadingPaneWidth: 240,
                trailingPaneWidth: 300
            )
        )
    }

    private static func executableBookmark(path: String) throws -> Data {
        try URL(fileURLWithPath: path, isDirectory: false).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func testResolvedExecutableToken(path: String) -> Data {
        var data = Data("cockpit-test-resolved-executable-v1\0".utf8)
        data.append(Data(path.utf8))
        return data
    }

    private static func waitForWorkflowFinalSession(
        _ sessionID: TerminalSessionID,
        transport: HostTerminalControlTransport
    ) async throws -> ClientTerminalSession {
        var lastObserved: ClientTerminalSession?
        for _ in 0..<200 {
            if let session = try await transport.list().first(where: {
                $0.sessionID == sessionID
            }) {
                lastObserved = session
                switch session.lifecycleState {
                case .exited, .terminated, .interrupted:
                    return session
                case .preparing, .committed, .running:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProbeError.terminalFailure(
            "final session timeout: session=\(sessionID) lifecycle=\(String(describing: lastObserved?.lifecycleState)) exit=\(String(describing: lastObserved?.exitStatus))"
        )
    }

    private static func waitForWorkflowAgentMarker(
        path: String,
        prefix: String
    ) async throws {
        for _ in 0..<200 {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8),
               contents.split(separator: "\n").contains(where: {
                   $0.hasPrefix(prefix)
               }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProbeError.terminalFailure(
            "agent readiness timeout: path=\(path) prefix=\(prefix)"
        )
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
            try await terminalObservation(
                from: events,
                expectedText: marker.map { "CONSUMED:\($0)" }
            )
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
        expectedText: String?
    ) async throws -> TerminalProbeObservation {
        try await withThrowingTaskGroup(of: TerminalProbeObservation.self) { group in
            group.addTask {
                var text = ""
                for await event in events {
                    switch event {
                    case let .frame(_, frame):
                        text += terminalGraphemeText(frame)
                        if expectedText == nil || text.contains(expectedText!) {
                            return TerminalProbeObservation(
                                frame: frame,
                                foundMarker: expectedText != nil,
                                text: text
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
