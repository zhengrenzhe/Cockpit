import Foundation
import CoreFoundation
import Darwin
import CockpitHostCore
import CockpitLocalTransport
import CockpitPersistence
import CockpitWorkspace

private func parkHostProcess(retaining graph: [Any]) {
    withExtendedLifetime(graph) {
        let processLifetime = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 3_153_600_000,
            0,
            0,
            0
        ) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), processLifetime, .defaultMode)
        CFRunLoopRun()
    }
}

signal(SIGTERM, SIG_IGN)
let storage: CockpitStorageLocations
if let configuredRoot = ProcessInfo.processInfo.environment[
    "COCKPIT_APPLICATION_SUPPORT_ROOT"
], !configuredRoot.isEmpty {
    storage = try CockpitStorageLocations.under(
        URL(fileURLWithPath: configuredRoot, isDirectory: true)
    )
} else {
    storage = try CockpitStorageLocations.production()
}
let repository = try await SQLiteWorkspaceRepository(databaseURL: storage.workspaceDatabase)
let registry = WorkspaceKernelRegistry(
    documentLocatorUpdater: repository,
    documentMetadataRepository: repository,
    documentRecoveryRoot: storage.documentRecoveryRoot
)
let projectRootResolver = SecurityScopedProjectRootResolver()
let service = WorkspaceService(
    repository: repository,
    rootResolver: projectRootResolver,
    kernelRegistry: registry
)
let router = WorkspaceCommandRouter(service: service)
let ticketStore = HostDataPlaneTicketStore()
let dataPlaneService = WorkspaceHostDataPlaneService(
    workspaceService: service,
    kernelRegistry: registry
)
let dataPlaneServer = HostDataPlaneServer(
    service: dataPlaneService,
    ticketStore: ticketStore
)
try await dataPlaneServer.start()
let ticketIssuer = HostDataPlaneTicketIssuer(
    server: dataPlaneServer,
    store: ticketStore,
    effectiveUserID: geteuid()
)
let terminalSupervisor = TerminalSupervisorControlTransport()
let terminalService = WorkspaceTerminalService(
    resolveContext: { try await service.resolveContext($0) },
    resolveWorkspaceRoot: { context in
        guard let project = try await repository.listProjects().first(where: {
            $0.id == context.projectID
        }) else { throw WorkspaceRepositoryError.projectNotFound }
        let root = try projectRootResolver.resolve(bookmark: project.rootBookmark)
        guard root.canonicalRootIdentity == context.workspaceRootIdentity else {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
        return root.canonicalAbsolutePath
    },
    supervisor: terminalSupervisor
)
let exported = HostXPCExport(
    handshakeHandler: { try HostHandshakeHandler().handle($0) },
    workspaceRouter: router,
    hostDataPlaneTicketIssuer: ticketIssuer,
    workspaceTerminalService: terminalService
)
let delegate = MachServiceListenerDelegate(
    exportedObject: exported,
    exportedInterface: NSXPCInterface(with: HostXPCProtocol.self)
)
let listener = NSXPCListener(machServiceName: "dev.cockpit.host")
listener.delegate = delegate
listener.resume()

guard let mainRunLoop = CFRunLoopGetMain() else {
    throw CocoaError(.coderInvalidValue)
}
let terminationSignal = DispatchSource.makeSignalSource(
    signal: SIGTERM,
    queue: DispatchQueue(label: "dev.cockpit.host.shutdown")
)
private let shutdownCoordinator = HostShutdownCoordinator(
    ticketIssuer: ticketIssuer,
    dataPlaneServer: dataPlaneServer,
    invalidateListener: { listener.invalidate() },
    stopProcess: { CFRunLoopStop(mainRunLoop) }
)
terminationSignal.setEventHandler(handler: shutdownCoordinator.eventHandler)
terminationSignal.resume()
parkHostProcess(
    retaining: [
        repository, registry, service, router, ticketStore, dataPlaneService,
        dataPlaneServer, ticketIssuer, terminalSupervisor, terminalService,
        exported, delegate, listener,
        shutdownCoordinator, terminationSignal,
    ]
)
