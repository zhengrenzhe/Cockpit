import ServiceManagement
import XCTest
import CockpitLocalTransport
@testable import Cockpit

final class ProductionLaunchAgentRegistrarTests: XCTestCase {
    func testRegistersTerminalBeforeHostAndRequiresBothToBecomeEnabled() throws {
        let events = RegistrationEvents()
        let terminal = RecordingLaunchAgent(
            plistName: "dev.cockpit.terminal.plist",
            events: events
        )
        let host = RecordingLaunchAgent(
            plistName: "dev.cockpit.host.plist",
            events: events
        )
        let services: [String: RecordingLaunchAgent] = [
            terminal.plistName: terminal,
            host.plistName: host,
        ]
        let registrar = ProductionLaunchAgentRegistrar { plistName in
            try XCTUnwrap(services[plistName])
        }

        try registrar.registerRequiredServices()

        XCTAssertEqual(
            events.values,
            [
                .status(terminal.plistName),
                .register(terminal.plistName),
                .status(terminal.plistName),
                .status(host.plistName),
                .register(host.plistName),
                .status(host.plistName),
            ]
        )
    }

    func testRequiredApprovalFailsBeforeHostWithActionableRecovery() throws {
        let events = RegistrationEvents()
        let terminal = RecordingLaunchAgent(
            plistName: "dev.cockpit.terminal.plist",
            status: .requiresApproval,
            events: events
        )
        let host = RecordingLaunchAgent(
            plistName: "dev.cockpit.host.plist",
            events: events
        )
        let services: [String: RecordingLaunchAgent] = [
            terminal.plistName: terminal,
            host.plistName: host,
        ]
        let registrar = ProductionLaunchAgentRegistrar { plistName in
            try XCTUnwrap(services[plistName])
        }

        XCTAssertThrowsError(try registrar.registerRequiredServices()) { error in
            guard let registrationError = error
                as? ProductionLaunchAgentRegistrationError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                registrationError.errorDescription,
                "Cockpit Terminal requires approval in System Settings."
            )
            XCTAssertEqual(
                registrationError.recoverySuggestion,
                "Open System Settings > General > Login Items & Extensions, "
                    + "enable Cockpit, then relaunch Cockpit."
            )
        }
        XCTAssertEqual(events.values, [.status(terminal.plistName)])
    }

    func testMissingRegistrationRecordAttemptsRegistration() throws {
        let events = RegistrationEvents()
        let terminal = RecordingLaunchAgent(
            plistName: "dev.cockpit.terminal.plist",
            status: .notFound,
            events: events
        )
        let host = RecordingLaunchAgent(
            plistName: "dev.cockpit.host.plist",
            status: .enabled,
            events: events
        )
        let services: [String: RecordingLaunchAgent] = [
            terminal.plistName: terminal,
            host.plistName: host,
        ]
        let registrar = ProductionLaunchAgentRegistrar { plistName in
            try XCTUnwrap(services[plistName])
        }

        try registrar.registerRequiredServices()

        XCTAssertEqual(
            events.values,
            [
                .status(terminal.plistName),
                .register(terminal.plistName),
                .status(terminal.plistName),
                .status(host.plistName),
            ]
        )
    }

    func testProductionNamespaceRegistersRequiredLaunchAgents() throws {
        var registrationCount = 0

        try registerProductionLaunchAgents(serviceNamespace: .production) {
            registrationCount += 1
        }

        XCTAssertEqual(registrationCount, 1)
    }

    func testFixtureNamespaceDoesNotRegisterProductionLaunchAgents() throws {
        var registrationCount = 0

        try registerProductionLaunchAgents(
            serviceNamespace: XPCServiceNamespace("p1-fixture")
        ) {
            registrationCount += 1
        }

        XCTAssertEqual(registrationCount, 0)
    }
}

private final class RegistrationEvents {
    enum Event: Equatable {
        case status(String)
        case register(String)
    }

    var values: [Event] = []
}

private final class RecordingLaunchAgent: LaunchAgentService {
    let plistName: String
    private let events: RegistrationEvents
    private var currentStatus = SMAppService.Status.notRegistered

    init(plistName: String, events: RegistrationEvents) {
        self.plistName = plistName
        self.events = events
    }

    init(
        plistName: String,
        status: SMAppService.Status,
        events: RegistrationEvents
    ) {
        self.plistName = plistName
        currentStatus = status
        self.events = events
    }

    var status: SMAppService.Status {
        events.values.append(.status(plistName))
        return currentStatus
    }

    func register() throws {
        events.values.append(.register(plistName))
        currentStatus = .enabled
    }
}
