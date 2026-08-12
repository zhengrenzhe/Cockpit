import Foundation
import ServiceManagement
import CockpitLocalTransport

protocol LaunchAgentService {
    var status: SMAppService.Status { get }
    func register() throws
}

extension SMAppService: LaunchAgentService {}

enum ProductionLaunchAgentRegistrationError: LocalizedError {
    case unavailable(plistName: String, status: SMAppService.Status)

    var errorDescription: String? {
        switch self {
        case let .unavailable(plistName, status):
            switch status {
            case .requiresApproval:
                return "\(Self.displayName(for: plistName)) requires approval in System Settings."
            case .notFound:
                return "\(Self.displayName(for: plistName)) is missing from the app bundle."
            case .notRegistered:
                return "\(Self.displayName(for: plistName)) did not register."
            case .enabled:
                return "\(Self.displayName(for: plistName)) is unavailable."
            @unknown default:
                return "\(Self.displayName(for: plistName)) is unavailable."
            }
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case let .unavailable(_, status) where status == .requiresApproval:
            return "Open System Settings > General > Login Items & Extensions, "
                + "enable Cockpit, then relaunch Cockpit."
        case .unavailable:
            return "Reinstall Cockpit, then relaunch it."
        }
    }

    private static func displayName(for plistName: String) -> String {
        switch plistName {
        case "dev.cockpit.terminal.plist":
            return "Cockpit Terminal"
        case "dev.cockpit.host.plist":
            return "Cockpit Host"
        default:
            return plistName
        }
    }
}

struct ProductionLaunchAgentRegistrar {
    private static let requiredPlistNames = [
        "dev.cockpit.terminal.plist",
        "dev.cockpit.host.plist",
    ]

    private let serviceFactory: (String) throws -> any LaunchAgentService

    init(
        serviceFactory: @escaping (String) throws -> any LaunchAgentService = {
            SMAppService.agent(plistName: $0)
        }
    ) {
        self.serviceFactory = serviceFactory
    }

    func registerRequiredServices() throws {
        for plistName in Self.requiredPlistNames {
            let service = try serviceFactory(plistName)
            let status = service.status
            switch status {
            case .enabled:
                continue
            case .notRegistered, .notFound:
                try service.register()
                let registeredStatus = service.status
                guard registeredStatus == .enabled else {
                    throw ProductionLaunchAgentRegistrationError.unavailable(
                        plistName: plistName,
                        status: registeredStatus
                    )
                }
            case .requiresApproval:
                throw ProductionLaunchAgentRegistrationError.unavailable(
                    plistName: plistName,
                    status: status
                )
            @unknown default:
                throw ProductionLaunchAgentRegistrationError.unavailable(
                    plistName: plistName,
                    status: status
                )
            }
        }
    }
}

func registerProductionLaunchAgents(
    serviceNamespace: XPCServiceNamespace,
    registration: () throws -> Void = {
        try ProductionLaunchAgentRegistrar().registerRequiredServices()
    }
) throws {
    guard serviceNamespace.description.isEmpty else { return }
    try registration()
}
