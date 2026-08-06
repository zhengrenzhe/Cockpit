import Foundation
import CockpitHostCore
import CockpitLocalTransport
import CockpitPersistence
import CockpitWorkspace

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
await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
