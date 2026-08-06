import Foundation
import CoreFoundation
import CockpitHostCore
import CockpitLocalTransport
import CockpitPersistence
import CockpitWorkspace

private func parkHostProcess(retaining graph: [Any]) -> Never {
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
    fatalError("CockpitHost process run loop stopped")
}

let storage = try CockpitStorageLocations.production()
let repository = try await SQLiteWorkspaceRepository(databaseURL: storage.workspaceDatabase)
let registry = WorkspaceKernelRegistry()
let service = WorkspaceService(
    repository: repository,
    rootResolver: SecurityScopedProjectRootResolver(),
    kernelRegistry: registry
)
let router = WorkspaceCommandRouter(service: service)
let exported = HostXPCExport(
    handshakeHandler: { try HostHandshakeHandler().handle($0) },
    workspaceRouter: router
)
let delegate = MachServiceListenerDelegate(
    exportedObject: exported,
    exportedInterface: NSXPCInterface(with: HostXPCProtocol.self)
)
let listener = NSXPCListener(machServiceName: "dev.cockpit.host")
listener.delegate = delegate
listener.resume()
parkHostProcess(
    retaining: [repository, registry, service, router, exported, delegate, listener]
)
