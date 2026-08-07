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

private final class HostShutdownCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let ticketIssuer: HostDataPlaneTicketIssuer
    private let dataPlaneServer: HostDataPlaneServer
    private let listener: NSXPCListener
    private let runLoop: CFRunLoop

    init(
        ticketIssuer: HostDataPlaneTicketIssuer,
        dataPlaneServer: HostDataPlaneServer,
        listener: NSXPCListener,
        runLoop: CFRunLoop
    ) {
        self.ticketIssuer = ticketIssuer
        self.dataPlaneServer = dataPlaneServer
        self.listener = listener
        self.runLoop = runLoop
    }

    func handleTermination() {
        let begins = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard begins else { return }
        Task {
            await ticketIssuer.stopIssuingTickets()
            await dataPlaneServer.shutdown()
            listener.invalidate()
            CFRunLoopStop(runLoop)
        }
    }

    var eventHandler: @Sendable () -> Void {
        { [weak self] in self?.handleTermination() }
    }
}

signal(SIGTERM, SIG_IGN)
let storage = try CockpitStorageLocations.production()
let repository = try await SQLiteWorkspaceRepository(databaseURL: storage.workspaceDatabase)
let registry = WorkspaceKernelRegistry(
    documentLocatorUpdater: repository,
    documentMetadataRepository: repository,
    documentRecoveryRoot: storage.documentRecoveryRoot
)
let service = WorkspaceService(
    repository: repository,
    rootResolver: SecurityScopedProjectRootResolver(),
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
let exported = HostXPCExport(
    handshakeHandler: { try HostHandshakeHandler().handle($0) },
    workspaceRouter: router,
    hostDataPlaneTicketIssuer: ticketIssuer
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
    listener: listener,
    runLoop: mainRunLoop
)
terminationSignal.setEventHandler(handler: shutdownCoordinator.eventHandler)
terminationSignal.resume()
parkHostProcess(
    retaining: [
        repository, registry, service, router, ticketStore, dataPlaneService,
        dataPlaneServer, ticketIssuer, exported, delegate, listener,
        shutdownCoordinator, terminationSignal,
    ]
)
