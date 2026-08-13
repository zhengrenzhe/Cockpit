import CryptoKit
import Foundation
import ServiceManagement
import CockpitLocalTransport

protocol LaunchAgentService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
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
    private let currentRevision: (() throws -> String)?
    private let registeredRevision: (() -> String?)?
    private let storeRegisteredRevision: ((String) -> Void)?

    init(
        serviceFactory: @escaping (String) throws -> any LaunchAgentService = {
            SMAppService.agent(plistName: $0)
        }
    ) {
        self.serviceFactory = serviceFactory
        currentRevision = nil
        registeredRevision = nil
        storeRegisteredRevision = nil
    }

    init(
        currentRevision: @escaping () throws -> String,
        registeredRevision: @escaping () -> String?,
        storeRegisteredRevision: @escaping (String) -> Void,
        serviceFactory: @escaping (String) throws -> any LaunchAgentService
    ) {
        self.serviceFactory = serviceFactory
        self.currentRevision = currentRevision
        self.registeredRevision = registeredRevision
        self.storeRegisteredRevision = storeRegisteredRevision
    }

    static func production() -> Self {
        Self(
            currentRevision: ProductionLaunchAgentRevision.current,
            registeredRevision: {
                UserDefaults.standard.string(
                    forKey: ProductionLaunchAgentRevision.preferencesKey
                )
            },
            storeRegisteredRevision: {
                UserDefaults.standard.set(
                    $0,
                    forKey: ProductionLaunchAgentRevision.preferencesKey
                )
            },
            serviceFactory: { SMAppService.agent(plistName: $0) }
        )
    }

    func registerRequiredServices() throws {
        let revision = try currentRevision?()
        let refreshEnabledServices = revision.map { registeredRevision?() != $0 } ?? false
        for plistName in Self.requiredPlistNames {
            let service = try serviceFactory(plistName)
            let status = service.status
            switch status {
            case .enabled:
                guard refreshEnabledServices else { continue }
                try service.unregister()
                try register(service, plistName: plistName)
            case .notRegistered, .notFound:
                try register(service, plistName: plistName)
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
        if let revision {
            storeRegisteredRevision?(revision)
        }
    }

    private func register(
        _ service: any LaunchAgentService,
        plistName: String
    ) throws {
        try service.register()
        let registeredStatus = service.status
        guard registeredStatus == .enabled else {
            throw ProductionLaunchAgentRegistrationError.unavailable(
                plistName: plistName,
                status: registeredStatus
            )
        }
    }
}

private enum ProductionLaunchAgentRevision {
    static let preferencesKey = "ProductionLaunchAgentExecutableRevision.v1"
    private static let artifactRelativePaths = [
        "Contents/Library/LaunchAgents/dev.cockpit.host.plist",
        "Contents/Library/LaunchAgents/dev.cockpit.terminal.plist",
        "Contents/Resources/CockpitHost",
        "Contents/Resources/CockpitPTYKeeper",
        "Contents/Resources/CockpitTerminalSupervisor",
    ]

    static func current() throws -> String {
        var hasher = SHA256()
        for relativePath in artifactRelativePaths {
            let artifactURL = Bundle.main.bundleURL.appendingPathComponent(relativePath)
            let artifact = try Data(contentsOf: artifactURL, options: .mappedIfSafe)
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: artifact)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

func registerProductionLaunchAgents(
    serviceNamespace: XPCServiceNamespace,
    registration: () throws -> Void = {
        try ProductionLaunchAgentRegistrar.production().registerRequiredServices()
    }
) throws {
    guard serviceNamespace.description.isEmpty else { return }
    try registration()
}
