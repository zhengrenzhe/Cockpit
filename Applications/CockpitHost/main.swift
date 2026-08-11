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

private let testResolvedExecutablePrefix = Data(
    "cockpit-test-resolved-executable-v1\0".utf8
)

private func testResolvedExecutablePath(
    bookmark: Data,
    serviceNamespace: XPCServiceNamespace,
    fixtureRootPath: String?
) throws -> String? {
    guard !serviceNamespace.description.isEmpty,
          bookmark.starts(with: testResolvedExecutablePrefix) else {
        return nil
    }
    guard let fixtureRootPath, !fixtureRootPath.isEmpty,
          let path = String(
            data: bookmark.dropFirst(testResolvedExecutablePrefix.count),
            encoding: .utf8
          ), path.hasPrefix("/") else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    let fixtureRoot = URL(
        fileURLWithPath: fixtureRootPath,
        isDirectory: true
    ).resolvingSymlinksInPath().standardizedFileURL
    let executable = URL(fileURLWithPath: path, isDirectory: false)
        .resolvingSymlinksInPath().standardizedFileURL
    let fixturePrefix = fixtureRoot.path.hasSuffix("/")
        ? fixtureRoot.path
        : "\(fixtureRoot.path)/"
    let values = try executable.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard executable.path.hasPrefix(fixturePrefix),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw CocoaError(.fileReadNoPermission)
    }
    return executable.path
}

signal(SIGTERM, SIG_IGN)
let serviceNamespace = try XPCServiceNamespace(
    ProcessInfo.processInfo.environment["COCKPIT_SERVICE_NAMESPACE"] ?? ""
)
let storage: CockpitStorageLocations
let configuredRoot = ProcessInfo.processInfo.environment[
    "COCKPIT_APPLICATION_SUPPORT_ROOT"
]
if !serviceNamespace.description.isEmpty {
    guard let configuredRoot, configuredRoot.hasPrefix("/") else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    storage = try CockpitStorageLocations.under(
        URL(fileURLWithPath: configuredRoot, isDirectory: true)
    )
} else if let configuredRoot, !configuredRoot.isEmpty {
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
let terminalSupervisorClient = TerminalSupervisorXPCClient(
    serviceNamespace: serviceNamespace
)
let terminalSupervisor = TerminalSupervisorControlTransport(
    client: terminalSupervisorClient
)
let terminalDeletion = ContextTerminalDeletionTransport(
    client: terminalSupervisorClient
)
let service = WorkspaceService(
    repository: repository,
    rootResolver: projectRootResolver,
    kernelRegistry: registry,
    terminalDeletion: terminalDeletion
)
let agentExecutableBookmarkResolver = SecurityScopedExecutableBookmarkResolver()
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
    resolveAgentExecutableBookmark: { bookmark in
        if let resolved = try testResolvedExecutablePath(
            bookmark: bookmark,
            serviceNamespace: serviceNamespace,
            fixtureRootPath: ProcessInfo.processInfo.environment[
                "COCKPIT_PHASE1_EXECUTABLE_FIXTURE_ROOT"
            ]
        ) {
            return resolved
        }
        return try agentExecutableBookmarkResolver.resolve(bookmark: bookmark)
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
let listener = NSXPCListener(
    machServiceName: XPCServiceEndpoint.host.machServiceName(in: serviceNamespace)
)
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
        dataPlaneServer, ticketIssuer, terminalSupervisorClient,
        terminalSupervisor, terminalDeletion, terminalService,
        exported, delegate, listener,
        shutdownCoordinator, terminationSignal,
    ]
)
