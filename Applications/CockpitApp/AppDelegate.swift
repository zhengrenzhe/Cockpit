import AppKit
import Darwin
import Security
import CockpitClientCore
import CockpitLocalTransport
import CockpitProtocol
import CockpitTerminalClient
import CockpitTerminalCore
import CockpitTypes

private struct PhaseOneAppFixtureConfiguration {
    let keychainPath: String

    init?(environment: [String: String], namespace: XPCServiceNamespace) throws {
        guard !namespace.description.isEmpty else { return nil }
        guard let storageRoot = environment["COCKPIT_APPLICATION_SUPPORT_ROOT"],
              Self.isAbsoluteFixturePath(storageRoot),
              let home = environment["HOME"],
              Self.isAbsoluteFixturePath(home)
        else { throw CocoaError(.fileReadInvalidFileName) }
        let keychainURL = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(
                "Library/Keychains/cockpit-phase1.keychain-db",
                isDirectory: false
            )
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: keychainURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        keychainPath = keychainURL.path
    }

    private static func isAbsoluteFixturePath(_ path: String) -> Bool {
        path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.path != "/"
    }
}

private struct PhaseOneAppScenarioConfiguration {
    let receiptURL: URL
    let contextID: WorkspaceContextID
    let environmentID: EnvironmentID
    let terminalSessionID: TerminalSessionID
    let terminalKind: TerminalTabKind
    let closeTab: Bool
    let expectReconnected: Bool

    init?(environment: [String: String], namespace: XPCServiceNamespace) throws {
        guard !namespace.description.isEmpty else { return nil }
        guard let receipt = environment["COCKPIT_PHASE1_APP_RECEIPT_PATH"] else {
            return nil
        }
        guard receipt.hasPrefix("/"),
              let contextValue = environment["COCKPIT_PHASE1_APP_CONTEXT_ID"],
              let environmentValue = environment["COCKPIT_PHASE1_APP_ENVIRONMENT_ID"],
              let sessionValue = environment["COCKPIT_PHASE1_APP_TERMINAL_SESSION_ID"],
              let terminalKindValue = environment["COCKPIT_PHASE1_APP_TERMINAL_KIND"],
              let environmentUUID = UUID(uuidString: environmentValue),
              environmentUUID.uuidString.lowercased() == environmentValue,
              let sessionUUID = UUID(uuidString: sessionValue),
              sessionUUID.uuidString.lowercased() == sessionValue,
              let terminalKind = TerminalTabKind(rawValue: terminalKindValue)
        else { throw CocoaError(.coderInvalidValue) }
        let contextID: WorkspaceContextID
        if contextValue.hasPrefix("project:"),
           let uuid = UUID(uuidString: String(contextValue.dropFirst(8))) {
            contextID = .project(ProjectID(uuid))
        } else if contextValue.hasPrefix("conversation:"),
                  let uuid = UUID(uuidString: String(contextValue.dropFirst(13))) {
            contextID = .conversation(ConversationID(uuid))
        } else {
            throw CocoaError(.coderInvalidValue)
        }
        self.receiptURL = URL(fileURLWithPath: receipt)
        self.contextID = contextID
        self.environmentID = EnvironmentID(environmentUUID)
        self.terminalSessionID = TerminalSessionID(sessionUUID)
        self.terminalKind = terminalKind
        closeTab = environment["COCKPIT_PHASE1_APP_CLOSE_TAB"] == "1"
        expectReconnected = environment["COCKPIT_PHASE1_APP_EXPECT_RECONNECTED"] == "1"
    }
}

private struct PhaseOneAppReceipt: Codable {
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

private enum PhaseOneTerminalAttachmentObservationError: Error {
    case timedOut(tabID: TabID, sessionID: TerminalSessionID)
}

@MainActor
private final class PhaseOneTerminalAttachmentObservation {
    private let expectedTabID: TabID
    private let expectedSessionID: TerminalSessionID
    private var attached = false
    private var waiter: CheckedContinuation<Void, any Error>?

    init(tabID: TabID, sessionID: TerminalSessionID) {
        expectedTabID = tabID
        expectedSessionID = sessionID
    }

    func recordAttached(tabID: TabID, sessionID: TerminalSessionID) {
        guard tabID == expectedTabID,
              sessionID == expectedSessionID,
              !attached
        else { return }
        attached = true
        waiter?.resume()
        waiter = nil
    }

    func waitForAttachment(timeout: TimeInterval) async throws {
        guard !attached else { return }
        try await withCheckedThrowingContinuation { continuation in
            if attached {
                continuation.resume()
                return
            }
            precondition(waiter == nil, "Only one Phase 1 attachment waiter is supported")
            waiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.timeOut()
            }
        }
    }

    private func timeOut() {
        guard !attached, let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: PhaseOneTerminalAttachmentObservationError.timedOut(
            tabID: expectedTabID,
            sessionID: expectedSessionID
        ))
    }
}

private struct ExplicitKeychainClientIdentityKeychain: ClientIdentityKeychain {
    let path: String

    func load(service: String, account: String) throws -> Data? {
        var query = try baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClientIdentityStoreError.keychain(status)
        }
        return data
    }

    func save(_ data: Data, service: String, account: String) throws {
        var query = try baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ClientIdentityStoreError.keychain(status)
        }
    }

    private func baseQuery(service: String, account: String) throws -> [String: Any] {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw ClientIdentityStoreError.keychain(status)
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain,
            kSecMatchSearchList as String: [keychain],
        ]
    }
}

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedApplicationDelegate: AppDelegate?
    private var workspaceWindowController: WorkspaceWindowController?
    private var monacoController: MonacoEditorViewController?
    private var hostClient: HostXPCClient?
    private var phaseOneReceiptURL: URL?
    private var phaseOneReceipt: PhaseOneAppReceipt?
    private var phaseOneScenario: PhaseOneAppScenarioConfiguration?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedApplicationDelegate = delegate
        application.delegate = delegate
        application.mainMenu = makeCockpitMainMenu(
            application: application,
            applicationName: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleName"
            ) as? String ?? "Cockpit"
        )
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await self?.startWorkspace()
            } catch {
                if let self,
                   let scenario = self.phaseOneScenario {
                    let receipt = Self.phaseOneFailureReceipt(
                        error: error,
                        scenario: scenario,
                        pendingReceipt: self.phaseOneReceipt
                    )
                    let receiptURL = scenario.receiptURL
                    self.phaseOneReceiptURL = receiptURL
                    self.phaseOneReceipt = receipt
                    try? self.writePhaseOneReceipt(receipt, to: receiptURL)
                    NSApp.terminate(nil)
                    return
                }
                NSApp.presentError(error)
                NSApp.terminate(nil)
            }
        }
    }

    private func startWorkspace() async throws {
        let environment = ProcessInfo.processInfo.environment
        let serviceNamespace = try XPCServiceNamespace(
            environment["COCKPIT_SERVICE_NAMESPACE"] ?? ""
        )
        try registerProductionLaunchAgents(serviceNamespace: serviceNamespace)
        let phaseOneFixture = try PhaseOneAppFixtureConfiguration(
            environment: environment,
            namespace: serviceNamespace
        )
        let phaseOneScenario = try PhaseOneAppScenarioConfiguration(
            environment: environment,
            namespace: serviceNamespace
        )
        self.phaseOneScenario = phaseOneScenario
        let runtimeDirectory = environment["COCKPIT_TERMINAL_RUNTIME_ROOT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "/private/tmp/cockpit.\(geteuid())/terminal"
        let identityStore: ClientIdentityStore
        if serviceNamespace.description.isEmpty {
            identityStore = ClientIdentityStore()
        } else {
            guard let phaseOneFixture else { throw CocoaError(.coderInvalidValue) }
            let suiteName = "dev.cockpit.client-identity.\(serviceNamespace)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw CocoaError(.coderInvalidValue)
            }
            identityStore = ClientIdentityStore(
                keychain: ExplicitKeychainClientIdentityKeychain(
                    path: phaseOneFixture.keychainPath
                ),
                preferences: UserDefaultsClientIdentityPreferences(
                    userDefaults: defaults
                ),
                keychainService: suiteName
            )
        }
        let identity = try await identityStore.identity()
        let deviceID = identity.deviceID
        let windowID = identity.mainWindowID
        let clientInstanceID = identity.clientInstanceID
        let clientState = WorkspaceClientState()
        let activeContexts = ActiveContextController()
        let hostClient = HostXPCClient(serviceNamespace: serviceNamespace)
        let stateCoordinator = WorkspaceStateCoordinator(
            clientState: clientState,
            remote: hostClient
        )

        let resolver = MonacoWindowSessionResolver(
            clientInstanceID: clientInstanceID,
            loadViewState: { contextID, tabID, documentID in
                let key = ClientWorkspaceStateKey(
                    deviceID: deviceID,
                    windowID: windowID,
                    workspaceContextID: contextID
                )
                guard let state = try? await stateCoordinator.storedState(for: key),
                      let tab = state.tabs.first(where: { $0.id == tabID }),
                      tab.resource == .file(documentID)
                else { return nil }
                return tab.fileViewState
            },
            storeViewState: { contextID, tabID, documentID, viewState in
                try await stateCoordinator.updateFileViewState(
                    key: ClientWorkspaceStateKey(
                        deviceID: deviceID,
                        windowID: windowID,
                        workspaceContextID: contextID
                    ),
                    tabID: tabID,
                    documentID: documentID,
                    viewState: viewState
                )
            }
        )
        guard let runtimeBundleURL = Bundle.main.url(
            forResource: "MonacoRuntime",
            withExtension: "bundle"
        ) else { preconditionFailure("MonacoRuntime.bundle is missing") }
        let bridge = MonacoBridge(resolver: resolver)
        let monacoController = MonacoEditorViewController(
            bridge: bridge,
            runtimeBundleURL: runtimeBundleURL
        )
        let viewModel = WorkspaceViewModel(
            workspaceService: hostClient,
            stateCoordinator: stateCoordinator,
            activeContexts: activeContexts,
            deviceID: deviceID,
            windowID: windowID,
            clientInstanceID: clientInstanceID,
            commandDependencies: WorkspaceCommandDependencies(
                hostClient: hostClient,
                monacoBridge: bridge
            ),
            fileSelection: { contextID, tabID, documentID in
                try await bridge.select(
                    contextID: contextID,
                    tabID: tabID,
                    documentID: documentID
                )
            }
        )
        let phaseOneTabID = phaseOneScenario.map { _ in TabID() }
        let phaseOneAttachmentObservation: PhaseOneTerminalAttachmentObservation?
        if let phaseOneScenario, let phaseOneTabID {
            phaseOneAttachmentObservation = PhaseOneTerminalAttachmentObservation(
                tabID: phaseOneTabID,
                sessionID: phaseOneScenario.terminalSessionID
            )
            try await hostClient.saveClientState(try ClientWorkspaceState(
                validatingKey: ClientWorkspaceStateKey(
                    deviceID: deviceID,
                    windowID: windowID,
                    workspaceContextID: phaseOneScenario.contextID
                ),
                tabs: [try TabRecord(
                    validatingID: phaseOneTabID,
                    resource: .terminal(phaseOneScenario.terminalSessionID),
                    terminalKind: phaseOneScenario.terminalKind,
                    fileViewState: nil
                )],
                selectedTabID: phaseOneTabID,
                sidebar: SidebarState(isCollapsed: false),
                splitView: SplitViewState(
                    validatingLeadingPaneWidth: 240,
                    trailingPaneWidth: 300
                )
            ))
        } else {
            phaseOneAttachmentObservation = nil
        }
        let windowController = WorkspaceWindowController(
            viewModel: viewModel,
            monacoController: monacoController,
            relocationCoordinator: viewModel,
            fileTreeProviderFactory: { active in
                let binding = try! HostDataPlaneBinding(
                    validatingClientInstanceID: clientInstanceID,
                    windowID: windowID,
                    workspaceContextID: active.contextID,
                    environmentID: active.environmentID,
                    activeContextGeneration: active.generation
                )
                return FileTreeProviderBinding(
                    environmentID: active.environmentID,
                    provider: HostDataPlaneClient(
                        binding: binding,
                        xpcClient: hostClient
                    )
                )
            },
            terminalControllerFactory: { tab, active, clientInstanceID in
                guard let terminalSessionID = tab.kind.terminalSessionID else {
                    preconditionFailure("Terminal content requires a terminal tab")
                }
                let controlTransport = HostTerminalControlTransport(
                    client: hostClient,
                    contextID: active.contextID,
                    environmentID: active.environmentID,
                    runtimeDirectory: runtimeDirectory
                )
                let beforeHandlingAttached: (
                    @MainActor @Sendable (TerminalSessionID) async -> Void
                )?
                if let phaseOneAttachmentObservation {
                    beforeHandlingAttached = { attachedSessionID in
                        guard attachedSessionID == terminalSessionID else { return }
                        phaseOneAttachmentObservation.recordAttached(
                            tabID: tab.id,
                            sessionID: attachedSessionID
                        )
                    }
                } else {
                    beforeHandlingAttached = nil
                }
                return TerminalTabViewController(
                    attachmentController: TerminalAttachmentController(
                        clientInstanceID: clientInstanceID,
                        requestedCapabilities: .all,
                        controlTransport: controlTransport,
                        dataTransport: KeeperTerminalDataTransport()
                    ),
                    sessionList: { try await controlTransport.list() },
                    archiveOpen: {
                        try await controlTransport.openArchive(sessionID: $0)
                    },
                    restart: { [weak viewModel] sessionID, profileID in
                        guard let viewModel else { throw CancellationError() }
                        try await viewModel.restartTerminalTab(
                            tab.id,
                            replacing: sessionID,
                            switchingTo: profileID
                        )
                    },
                    requestContext: {
                        try RequestContext(
                            validating: .current,
                            clientInstanceID: clientInstanceID,
                            windowID: windowID,
                            workspaceContextID: active.contextID,
                            environmentID: active.environmentID,
                            activeContextGeneration: active.generation,
                            requestID: RequestID()
                        )
                    },
                    beforeHandlingAttached: beforeHandlingAttached
                )
            }
        )
        self.hostClient = hostClient
        self.monacoController = monacoController
        workspaceWindowController = windowController
        monacoController.loadRuntime()
        try await windowController.start()
        if let phaseOneScenario {
            guard let phaseOneTabID,
                  let phaseOneAttachmentObservation
            else { preconditionFailure("Phase 1 scenario attachment state is missing") }
            let selected = try await viewModel.selectContext(phaseOneScenario.contextID)
            guard selected.environmentID == phaseOneScenario.environmentID else {
                throw CocoaError(.coderInvalidValue)
            }
            let tabCountBefore = viewModel.currentTabs.count
            guard tabCountBefore == 1,
                  viewModel.currentTabs.first?.id == phaseOneTabID,
                  viewModel.currentTabs.first?.kind.terminalSessionID
                      == phaseOneScenario.terminalSessionID
            else { throw CocoaError(.coderInvalidValue) }
            let pendingReceipt = PhaseOneAppReceipt(
                schemaVersion: 1,
                appPID: getpid(),
                ready: false,
                closedTab: false,
                reconnected: false,
                applicationWillTerminate: false,
                workspaceContextID: Self.contextString(selected.contextID),
                environmentID: selected.environmentID.description,
                terminalSessionID: phaseOneScenario.terminalSessionID.description,
                tabID: phaseOneTabID.description,
                tabCountBefore: tabCountBefore,
                tabCountAfter: tabCountBefore,
                error: nil
            )
            phaseOneReceiptURL = phaseOneScenario.receiptURL
            phaseOneReceipt = pendingReceipt
            try writePhaseOneReceipt(pendingReceipt, to: phaseOneScenario.receiptURL)
            try await phaseOneAttachmentObservation.waitForAttachment(timeout: 12)

            let terminalTransport = HostTerminalControlTransport(
                client: hostClient,
                contextID: selected.contextID,
                environmentID: selected.environmentID,
                runtimeDirectory: runtimeDirectory
            )
            let sessions = try await terminalTransport.list()
            guard let session = sessions.first(where: {
                $0.sessionID == phaseOneScenario.terminalSessionID
            }), session.contextID == selected.contextID,
               session.environmentID == selected.environmentID
            else { throw CocoaError(.coderInvalidValue) }
            let expectedKind: TerminalKind = switch phaseOneScenario.terminalKind {
            case .shell: .shell
            case .codex: .agent(.codex)
            case .claude: .agent(.claude)
            }
            guard session.kind == expectedKind else { throw CocoaError(.coderInvalidValue) }
            let closedTab: Bool
            if phaseOneScenario.closeTab {
                closedTab = try await viewModel.closeTab(phaseOneTabID)
            } else {
                closedTab = false
            }
            let persisted = try await hostClient.loadClientState(ClientWorkspaceStateKey(
                deviceID: deviceID,
                windowID: windowID,
                workspaceContextID: selected.contextID
            ))
            let tabCountAfter = persisted?.tabs.count ?? 0
            guard tabCountAfter == (phaseOneScenario.closeTab ? 0 : 1),
                  !phaseOneScenario.closeTab || closedTab,
                  !phaseOneScenario.expectReconnected || sessions.contains(where: {
                      $0.sessionID == phaseOneScenario.terminalSessionID
                  })
            else { throw CocoaError(.coderInvalidValue) }
            let receipt = PhaseOneAppReceipt(
                schemaVersion: 1,
                appPID: getpid(),
                ready: true,
                closedTab: closedTab,
                reconnected: phaseOneScenario.expectReconnected,
                applicationWillTerminate: false,
                workspaceContextID: Self.contextString(selected.contextID),
                environmentID: selected.environmentID.description,
                terminalSessionID: phaseOneScenario.terminalSessionID.description,
                tabID: phaseOneTabID.description,
                tabCountBefore: tabCountBefore,
                tabCountAfter: tabCountAfter,
                error: nil
            )
            phaseOneReceipt = receipt
            try writePhaseOneReceipt(receipt, to: phaseOneScenario.receiptURL)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if var receipt = phaseOneReceipt, let receiptURL = phaseOneReceiptURL {
            receipt.applicationWillTerminate = true
            phaseOneReceipt = receipt
            try? writePhaseOneReceipt(receipt, to: receiptURL)
        }
        monacoController?.tearDown()
        let hostClient = hostClient
        Task { await hostClient?.disconnect() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func writePhaseOneReceipt(_ receipt: PhaseOneAppReceipt, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }

    private static func contextString(_ context: WorkspaceContextID) -> String {
        switch context {
        case let .project(id): "project:\(id)"
        case let .conversation(id): "conversation:\(id)"
        }
    }

    private static func phaseOneFailureReceipt(
        error: Error,
        scenario: PhaseOneAppScenarioConfiguration,
        pendingReceipt: PhaseOneAppReceipt?
    ) -> PhaseOneAppReceipt {
        PhaseOneAppReceipt(
            schemaVersion: 1,
            appPID: getpid(),
            ready: false,
            closedTab: false,
            reconnected: false,
            applicationWillTerminate: false,
            workspaceContextID: contextString(scenario.contextID),
            environmentID: scenario.environmentID.description,
            terminalSessionID: scenario.terminalSessionID.description,
            tabID: pendingReceipt?.tabID,
            tabCountBefore: pendingReceipt?.tabCountBefore ?? 0,
            tabCountAfter: pendingReceipt?.tabCountAfter ?? 0,
            error: String(reflecting: error)
        )
    }
}
