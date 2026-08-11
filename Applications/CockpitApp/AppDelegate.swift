import AppKit
import CockpitClientCore
import CockpitLocalTransport
import CockpitProtocol
import CockpitTypes

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceWindowController: WorkspaceWindowController?
    private var monacoController: MonacoEditorViewController?
    private var hostClient: HostXPCClient?
    private let identityStore = ClientIdentityStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            do {
                try await self?.startWorkspace()
            } catch {
                NSApp.presentError(error)
                NSApp.terminate(nil)
            }
        }
    }

    private func startWorkspace() async throws {
        let identity = try await identityStore.identity()
        let deviceID = identity.deviceID
        let windowID = identity.mainWindowID
        let clientInstanceID = identity.clientInstanceID
        let clientState = WorkspaceClientState()
        let activeContexts = ActiveContextController()
        let hostClient = HostXPCClient()
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
                guard tab.kind.terminalSessionID != nil else {
                    preconditionFailure("Terminal content requires a terminal tab")
                }
                return TerminalTabViewController(
                    contextID: active.contextID,
                    environmentID: active.environmentID,
                    clientInstanceID: clientInstanceID,
                    hostClient: hostClient,
                    restart: { [weak viewModel] sessionID, profileID in
                        guard let viewModel else { throw CancellationError() }
                        try await viewModel.restartTerminalTab(
                            tab.id,
                            replacing: sessionID,
                            switchingTo: profileID
                        )
                    }
                )
            }
        )
        self.hostClient = hostClient
        self.monacoController = monacoController
        workspaceWindowController = windowController
        monacoController.loadRuntime()
        try await windowController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monacoController?.tearDown()
        let hostClient = hostClient
        Task { await hostClient?.disconnect() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
