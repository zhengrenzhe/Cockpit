import Foundation
import CockpitHostCore
import CockpitLocalTransport

let exported = XPCHandshakeExport { try HostHandshakeHandler().handle($0) }
let delegate = MachServiceListenerDelegate(
    exportedObject: exported,
    exportedInterface: NSXPCInterface(with: XPCHandshakeProtocol.self)
)
let listener = NSXPCListener(machServiceName: "dev.cockpit.host")
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
