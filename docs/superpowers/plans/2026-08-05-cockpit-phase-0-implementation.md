# Cockpit Phase 0 Engineering Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible macOS foundation in which Cockpit.app, CockpitHost, CockpitTerminalSupervisor, and per-session CockpitPTYKeeper processes share stable identities and one versioned protocol, while launchd and process tests prove that a detached Keeper survives a Supervisor crash.

**Architecture:** A root Swift Package owns stable value types, protobuf messages, frame codecs, client state, host negotiation, terminal lifecycle values, and transport adapters. An XcodeGen project assembles one AppKit application, two launchd-managed services, and an embedded PTYKeeper executable. Phase 0 uses a no-PTY Keeper probe to verify `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`, bootstrap-FD isolation, Supervisor crash survival, and launchd restart; real PTY creation, Ghostty VT state, attach tickets, and session recovery arrive in Phase 1.

**Tech Stack:** Xcode 26.6 (17F113), Swift 6.3.3, Swift tools 6.3, AppKit, Darwin POSIX spawn APIs, NSXPCConnection, Network.framework, Security.framework, SwiftProtobuf 1.38.1, XcodeGen 2.46.0, Node 26.7.0, Monaco 0.56.0, esbuild 0.28.1, pnpm 11.20.0, Ghostty v1.3.1, Zig 0.15.2.

## Global Constraints

- The repository is currently empty except for design artifacts; preserve `.superpowers/` and do not commit it.
- Phase 0 targets arm64 macOS and uses the macOS 15.0 deployment floor.
- Swift language mode is Swift 6 with strict concurrency checking.
- Development product identifiers are exactly `dev.cockpit.Cockpit`, `dev.cockpit.CockpitHost`, `dev.cockpit.CockpitTerminalSupervisor`, and `dev.cockpit.CockpitPTYKeeper`.
- Mach service names are exactly `dev.cockpit.host` and `dev.cockpit.terminal`.
- CockpitPTYKeeper is never a LaunchAgent and exposes no Mach service or network listener.
- Every Keeper starts with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`; bootstrap data crosses inherited file descriptor `3`, never argv or environment variables.
- CockpitTerminalSupervisor discards Keeper child exit status with `SIGCHLD` ignored so exited Keepers never become zombies; CockpitPTYKeeper restores the default `SIGCHLD` disposition before Phase 1 adds its own CLI child.
- Phase 0 Keeper probes do not create a PTY or child CLI. The probe exists only to prove process ownership and crash isolation before Phase 1.
- CockpitClientCore must not import AppKit, WebKit, NSXPCConnection, NWConnection, or filesystem APIs.
- CockpitHostCore must not import NSXPCConnection or NWConnection.
- Protocol major version is `1`; protocol minor version is `0`.
- The binary frame magic is `0x434B5054` (`CKPT`) and the frame header is exactly 32 bytes.
- SwiftProtobuf is pinned exactly to 1.38.1.
- Monaco is pinned exactly to 0.56.0; esbuild is pinned exactly to 0.28.1.
- Ghostty is pinned to commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` and built with Zig 0.15.2.
- Zig is a build tool only; no Zig compiler or source tree is copied into a Cockpit application bundle.
- Phase 0 uses ad-hoc local signing and launchctl integration fixtures. Developer Team signing, SMAppService approval UX, Hardened Runtime, and notarization belong to Phase 6.
- Every task follows test-first development and ends in a reviewable commit.

## Terminal Resilience Specification Coverage

Phase 0 implements and verifies these foundations from the approved terminal resilience specification:

- Stable TerminalSessionID and WorkerInstanceID types.
- Separate CockpitTerminalSupervisor and CockpitPTYKeeper executable boundaries.
- A user LaunchAgent with `KeepAlive` for CockpitTerminalSupervisor.
- Keeper spawn with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`.
- Bootstrap transfer through inherited file descriptor `3` rather than argv or environment variables.
- Effective-user validation on the local XPC control boundary.
- A process integration test that kills the Supervisor, proves the Keeper remains alive in its own process group, and proves launchd restores the Supervisor control endpoint.

Phase 1 implements the remaining live-terminal behavior: terminal.sqlite, two-phase launch commit, authenticated runtime descriptors, Keychain-derived worker secrets, per-Keeper UDS endpoints, single-use attach tickets, PTY and Agent CLI launch, Ghostty VT state, scrollback, input leases, snapshot/delta reconnection, final archives, and App quit/reopen reattachment. Phase 0 completion makes no claim that these behaviors exist.

---

## File Structure Locked by This Plan

```text
Cockpit/
├── .gitignore
├── Package.swift
├── Package.resolved
├── project.yml
├── Cockpit.xcworkspace/contents.xcworkspacedata
├── Config/
│   ├── Build/Base.xcconfig
│   ├── LaunchAgents/dev.cockpit.host.plist
│   ├── LaunchAgents/dev.cockpit.terminal.plist
│   └── Toolchains/ghostty.env
├── Applications/
│   ├── CockpitApp/AppDelegate.swift
│   ├── CockpitApp/ServiceStatusViewModel.swift
│   ├── CockpitHost/main.swift
│   ├── CockpitTerminalSupervisor/main.swift
│   ├── CockpitPTYKeeper/main.swift
│   └── CockpitProbe/main.swift
├── Sources/
│   ├── CockpitTypes/
│   ├── CockpitProtocol/
│   ├── CockpitClientCore/
│   ├── CockpitHostCore/
│   ├── CockpitTerminalCore/
│   │   ├── KeeperBootstrap.swift
│   │   └── TerminalLifecycle.swift
│   ├── CockpitLocalTransport/
│   └── CockpitRemoteTransport/
├── Tests/
│   ├── CockpitTypesTests/
│   ├── CockpitProtocolTests/
│   ├── CockpitClientCoreTests/
│   ├── CockpitHostCoreTests/
│   ├── CockpitTerminalCoreTests/
│   ├── CockpitLocalTransportTests/
│   ├── CockpitRemoteTransportTests/
│   ├── ProcessIntegrationTests/
│   └── ToolingTests/
├── EditorRuntime/
│   ├── package.json
│   ├── pnpm-lock.yaml
│   ├── build.mjs
│   ├── src/index.html
│   ├── src/bootstrap.ts
│   └── test/build.test.mjs
├── ThirdParty/ghostty/
└── Tools/
    ├── bootstrap-zig.zsh
    ├── phase0-services.zsh
    ├── test-remote-tls.zsh
    ├── verify-ghostty.zsh
    └── verify-phase0.zsh
```

The Xcode executable targets are composition roots. All reusable behavior remains in Swift Package targets.

---

### Task 1: Establish CockpitTypes and the root Swift package

**Files:**
- Create: `.gitignore`
- Create: `Package.swift`
- Create: `Sources/CockpitTypes/Identifiers.swift`
- Create: `Sources/CockpitTypes/ProtocolVersion.swift`
- Create: `Sources/CockpitTypes/RelativePath.swift`
- Create: `Tests/CockpitTypesTests/IdentifiersTests.swift`
- Create: `Tests/CockpitTypesTests/RelativePathTests.swift`

**Interfaces:**
- Consumes: no earlier task.
- Produces: `CockpitID<Scope>`, all stable ID aliases, `ProtocolVersion.current`, `ProtocolFeature`, and validated `RelativePath`.

- [ ] **Step 1: Create the package manifest and failing identifier tests**

Create `Package.swift`:

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CockpitKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CockpitTypes", targets: ["CockpitTypes"]),
    ],
    targets: [
        .target(name: "CockpitTypes"),
        .testTarget(name: "CockpitTypesTests", dependencies: ["CockpitTypes"]),
    ],
    swiftLanguageModes: [.v6]
)
```

Create `Sources/CockpitTypes/Identifiers.swift` with only `import Foundation`, then create `Tests/CockpitTypesTests/IdentifiersTests.swift`:

```swift
import Foundation
import Testing
@testable import CockpitTypes

@Test func stableIdentifierRoundTripsThroughCodable() throws {
    let uuid = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    )
    let original = ProjectID(uuid)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProjectID.self, from: data)
    #expect(decoded == original)
    #expect(decoded.description == "00000000-0000-0000-0000-000000000001")
}

@Test func identifierScopesRemainTypeSafe() throws {
    let raw = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let project = ProjectID(raw)
    let conversation = ConversationID(raw)
    #expect(project.rawValue == conversation.rawValue)
}
```

- [ ] **Step 2: Run the identifier test and verify failure**

Run:

```bash
swift test --filter CockpitTypesTests.stableIdentifierRoundTripsThroughCodable
```

Expected: compilation fails because `ProjectID` and `ConversationID` do not exist.

- [ ] **Step 3: Implement stable identifiers and protocol versions**

Replace `Sources/CockpitTypes/Identifiers.swift` with:

```swift
import Foundation

public struct CockpitID<Scope>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum ProjectScope: Sendable {}
public enum ConversationScope: Sendable {}
public enum EnvironmentScope: Sendable {}
public enum TerminalSessionScope: Sendable {}
public enum WorkerInstanceScope: Sendable {}
public enum DocumentSessionScope: Sendable {}
public enum TabScope: Sendable {}
public enum DeviceScope: Sendable {}
public enum ConnectionScope: Sendable {}
public enum RequestScope: Sendable {}

public typealias ProjectID = CockpitID<ProjectScope>
public typealias ConversationID = CockpitID<ConversationScope>
public typealias EnvironmentID = CockpitID<EnvironmentScope>
public typealias TerminalSessionID = CockpitID<TerminalSessionScope>
public typealias WorkerInstanceID = CockpitID<WorkerInstanceScope>
public typealias DocumentSessionID = CockpitID<DocumentSessionScope>
public typealias TabID = CockpitID<TabScope>
public typealias DeviceID = CockpitID<DeviceScope>
public typealias ConnectionID = CockpitID<ConnectionScope>
public typealias RequestID = CockpitID<RequestScope>

public struct ChannelID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 0)
}
```

Create `Sources/CockpitTypes/ProtocolVersion.swift`:

```swift
public struct ProtocolVersion: Hashable, Codable, Sendable, Comparable {
    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public static let current = ProtocolVersion(major: 1, minor: 0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public struct ProtocolFeature: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let workspaceControl = Self(rawValue: "workspace-control")
    public static let terminalControl = Self(rawValue: "terminal-control")
    public static let terminalFrames = Self(rawValue: "terminal-frames")
    public static let remoteDirect = Self(rawValue: "remote-direct")
}
```

- [ ] **Step 4: Write failing RelativePath tests**

Create `Tests/CockpitTypesTests/RelativePathTests.swift`:

```swift
import Testing
@testable import CockpitTypes

@Test func relativePathNormalizesComponents() throws {
    let path = try RelativePath("Sources//CockpitTypes/./Identifiers.swift")
    #expect(path.string == "Sources/CockpitTypes/Identifiers.swift")
}

@Test(arguments: ["/tmp/file", "../secret", "Sources/../../secret", ""])
func relativePathRejectsEscapes(value: String) {
    #expect(throws: RelativePath.Error.self) {
        try RelativePath(value)
    }
}
```

- [ ] **Step 5: Run the RelativePath tests and verify failure**

Run:

```bash
swift test --filter CockpitTypesTests.relativePath
```

Expected: compilation fails because `RelativePath` does not exist.

- [ ] **Step 6: Implement RelativePath**

Create `Sources/CockpitTypes/RelativePath.swift`:

```swift
public struct RelativePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Error: Swift.Error, Equatable {
        case empty
        case absolute
        case parentTraversal
    }

    public let string: String

    public init(_ input: String) throws {
        guard !input.isEmpty else { throw Error.empty }
        guard !input.hasPrefix("/") else { throw Error.absolute }

        var normalized: [Substring] = []
        for component in input.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { throw Error.parentTraversal }
            normalized.append(component)
        }

        guard !normalized.isEmpty else { throw Error.empty }
        string = normalized.joined(separator: "/")
    }

    public var description: String { string }
}
```

- [ ] **Step 7: Add repository ignores and run the complete target tests**

Create `.gitignore`:

```gitignore
.DS_Store
.build/
.swiftpm/
DerivedData/
build/
.tools/
EditorRuntime/node_modules/
EditorRuntime/dist/
Tests/Fixtures/TLS/generated/
.superpowers/
```

Run:

```bash
swift test --filter CockpitTypesTests
git diff --check
```

Expected: all CockpitTypes tests pass and `git diff --check` exits 0.

- [ ] **Step 8: Commit CockpitTypes**

```bash
git add .gitignore Package.swift Sources/CockpitTypes Tests/CockpitTypesTests
git commit -m "feat: establish cockpit core types"
```

---

### Task 2: Add the versioned protobuf handshake schema

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CockpitProtocol/Proto/cockpit.proto`
- Create: `Sources/CockpitProtocol/Proto/swift-protobuf-config.json`
- Create: `Sources/CockpitProtocol/Handshake.swift`
- Create: `Tests/CockpitProtocolTests/HandshakeCodecTests.swift`

**Interfaces:**
- Consumes: `ProtocolVersion`, `ProtocolFeature`, `DeviceID`, and `ConnectionID` from CockpitTypes.
- Produces: generated `CPHandshakeRequest`, `CPHandshakeResponse`, `CPProtocolError`, plus `HandshakeCodec` and typed conversion helpers.

- [ ] **Step 1: Add the package dependency and an intentionally incomplete proto**

Add this package dependency to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
],
```

Add the product and targets:

```swift
.library(name: "CockpitProtocol", targets: ["CockpitProtocol"]),
```

```swift
.target(
    name: "CockpitProtocol",
    dependencies: [
        "CockpitTypes",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    ],
    plugins: [
        .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
    ]
),
.testTarget(
    name: "CockpitProtocolTests",
    dependencies: ["CockpitProtocol"]
),
```

Create `Sources/CockpitProtocol/Proto/cockpit.proto`:

```proto
syntax = "proto3";
package cockpit.protocol.v1;
option swift_prefix = "CP";
```

Create `Sources/CockpitProtocol/Proto/swift-protobuf-config.json`:

```json
{
  "invocations": [
    {
      "protoFiles": ["cockpit.proto"],
      "visibility": "public",
      "fileNaming": "dropPath"
    }
  ]
}
```

Create `Tests/CockpitProtocolTests/HandshakeCodecTests.swift`:

```swift
import Testing
@testable import CockpitProtocol

@Test func handshakeRequestRoundTrips() throws {
    var request = CPHandshakeRequest()
    request.protocolMajor = 1
    request.protocolMinor = 0
    request.deviceID = "00000000-0000-0000-0000-000000000010"
    request.requestedFeatures = ["workspace-control", "terminal-frames"]

    let data = try HandshakeCodec.encode(request)
    let decoded = try HandshakeCodec.decodeRequest(data)
    #expect(decoded == request)
}
```

- [ ] **Step 2: Run the protocol test and verify failure**

Run:

```bash
swift test --filter CockpitProtocolTests.handshakeRequestRoundTrips
```

Expected: compilation fails because `CPHandshakeRequest` and `HandshakeCodec` do not exist.

- [ ] **Step 3: Define handshake and error messages**

Replace `Sources/CockpitProtocol/Proto/cockpit.proto` with:

```proto
syntax = "proto3";
package cockpit.protocol.v1;
option swift_prefix = "CP";

message HandshakeRequest {
  uint32 protocol_major = 1;
  uint32 protocol_minor = 2;
  string device_id = 3;
  repeated string requested_features = 4;
}

message HandshakeResponse {
  uint32 protocol_major = 1;
  uint32 protocol_minor = 2;
  string connection_id = 3;
  repeated string accepted_features = 4;
  string service_kind = 5;
}

message ProtocolError {
  enum Code {
    UNSPECIFIED = 0;
    INCOMPATIBLE_MAJOR_VERSION = 1;
    INVALID_IDENTITY = 2;
    MALFORMED_MESSAGE = 3;
    UNAUTHORIZED = 4;
  }

  Code code = 1;
  string message = 2;
}
```

Create `Sources/CockpitProtocol/Handshake.swift`:

```swift
import Foundation
import SwiftProtobuf
import CockpitTypes

public enum HandshakeCodec {
    public static func encode(_ request: CPHandshakeRequest) throws -> Data {
        try request.serializedData()
    }

    public static func encode(_ response: CPHandshakeResponse) throws -> Data {
        try response.serializedData()
    }

    public static func decodeRequest(_ data: Data) throws -> CPHandshakeRequest {
        try CPHandshakeRequest(serializedBytes: data)
    }

    public static func decodeResponse(_ data: Data) throws -> CPHandshakeResponse {
        try CPHandshakeResponse(serializedBytes: data)
    }
}

public extension CPHandshakeRequest {
    static func cockpit(
        version: ProtocolVersion = .current,
        deviceID: DeviceID,
        features: Set<ProtocolFeature>
    ) -> Self {
        var value = Self()
        value.protocolMajor = UInt32(version.major)
        value.protocolMinor = UInt32(version.minor)
        value.deviceID = deviceID.description
        value.requestedFeatures = features.map(\.rawValue).sorted()
        return value
    }
}
```

- [ ] **Step 4: Run protocol generation and tests**

Run:

```bash
swift package resolve
swift test --filter CockpitProtocolTests
```

Expected: SwiftProtobuf 1.38.1 resolves exactly and the handshake round-trip test passes.

- [ ] **Step 5: Verify the dependency pin**

Run:

```bash
/usr/bin/grep -En '1\.38\.1' Package.swift Package.resolved
```

Expected: both manifest and resolved file identify SwiftProtobuf 1.38.1.

- [ ] **Step 6: Commit the protocol schema**

```bash
git add Package.swift Package.resolved Sources/CockpitProtocol Tests/CockpitProtocolTests
git commit -m "feat: define cockpit handshake protocol"
```

---

### Task 3: Implement the fixed binary frame codec

**Files:**
- Create: `Sources/CockpitProtocol/Frame.swift`
- Create: `Sources/CockpitProtocol/FrameDecoder.swift`
- Create: `Tests/CockpitProtocolTests/FrameCodecTests.swift`

**Interfaces:**
- Consumes: `ChannelID` and CockpitProtocol module.
- Produces: `FrameHeader`, `Frame`, `FrameCodecError`, and incremental `FrameDecoder.append(_:)`.

- [ ] **Step 1: Write frame round-trip and fragmentation tests**

Create `Tests/CockpitProtocolTests/FrameCodecTests.swift`:

```swift
import Foundation
import Testing
import CockpitTypes
@testable import CockpitProtocol

@Test func frameHeaderIsExactlyThirtyTwoBytes() throws {
    let header = FrameHeader(
        flags: 2,
        channel: ChannelID(rawValue: 7),
        sequence: 11,
        acknowledgement: 9,
        payloadLength: 3
    )
    let encoded = header.encoded()
    #expect(encoded.count == 32)
    #expect(try FrameHeader(decoding: encoded) == header)
}

@Test func decoderHandlesArbitraryFragmentation() throws {
    let frame = try Frame(
        header: FrameHeader(
            flags: 0,
            channel: ChannelID(rawValue: 2),
            sequence: 1,
            acknowledgement: 0,
            payloadLength: 5
        ),
        payload: Data("hello".utf8)
    )
    let bytes = frame.encoded()
    var decoder = FrameDecoder()
    var output: [Frame] = []
    for byte in bytes {
        output += try decoder.append(Data([byte]))
    }
    #expect(output == [frame])
}

@Test func decoderRejectsOversizedPayload() {
    let header = FrameHeader(
        flags: 0,
        channel: ChannelID(rawValue: 1),
        sequence: 0,
        acknowledgement: 0,
        payloadLength: 16_777_217
    )
    #expect(throws: FrameCodecError.payloadTooLarge(16_777_217)) {
        _ = try FrameHeader(decoding: header.encoded())
    }
}

@Test func frameRejectsPayloadLengthMismatch() {
    let header = FrameHeader(
        flags: 0,
        channel: .control,
        sequence: 0,
        acknowledgement: 0,
        payloadLength: 4
    )
    #expect(throws: FrameCodecError.payloadLengthMismatch(expected: 4, actual: 3)) {
        _ = try Frame(header: header, payload: Data("bad".utf8))
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
swift test --filter CockpitProtocolTests.frame
swift test --filter CockpitProtocolTests.decoder
```

Expected: compilation fails because the frame types do not exist.

- [ ] **Step 3: Implement FrameHeader and Frame**

Create `Sources/CockpitProtocol/Frame.swift`:

```swift
import Foundation
import CockpitTypes

public enum FrameCodecError: Error, Equatable {
    case invalidHeaderLength(Int)
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt16)
    case payloadTooLarge(UInt32)
    case payloadLengthMismatch(expected: UInt32, actual: Int)
}

public struct FrameHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x434B5054
    public static let version: UInt16 = 1
    public static let encodedLength = 32
    public static let maximumPayloadLength: UInt32 = 16 * 1_024 * 1_024

    public let flags: UInt16
    public let channel: ChannelID
    public let sequence: UInt64
    public let acknowledgement: UInt64
    public let payloadLength: UInt32

    public init(
        flags: UInt16,
        channel: ChannelID,
        sequence: UInt64,
        acknowledgement: UInt64,
        payloadLength: UInt32
    ) {
        self.flags = flags
        self.channel = channel
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.payloadLength = payloadLength
    }

    public init(decoding data: Data) throws {
        guard data.count == Self.encodedLength else {
            throw FrameCodecError.invalidHeaderLength(data.count)
        }
        try self.init(decoding: data, at: 0)
    }

    init(decoding data: Data, at offset: Int) throws {
        guard
            offset >= 0,
            offset <= data.count,
            data.count - offset >= Self.encodedLength
        else {
            throw FrameCodecError.invalidHeaderLength(data.count - offset)
        }

        let magic = Self.read(UInt32.self, from: data, at: offset)
        guard magic == Self.magic else { throw FrameCodecError.invalidMagic(magic) }
        let version = Self.read(UInt16.self, from: data, at: offset + 4)
        guard version == Self.version else { throw FrameCodecError.unsupportedVersion(version) }

        flags = Self.read(UInt16.self, from: data, at: offset + 6)
        channel = ChannelID(
            rawValue: Self.read(UInt32.self, from: data, at: offset + 8)
        )
        sequence = Self.read(UInt64.self, from: data, at: offset + 12)
        acknowledgement = Self.read(UInt64.self, from: data, at: offset + 20)
        payloadLength = Self.read(UInt32.self, from: data, at: offset + 28)
        guard payloadLength <= Self.maximumPayloadLength else { throw FrameCodecError.payloadTooLarge(payloadLength) }
    }

    public func encoded() -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.encodedLength)
        Self.append(Self.magic, to: &bytes)
        Self.append(Self.version, to: &bytes)
        Self.append(flags, to: &bytes)
        Self.append(channel.rawValue, to: &bytes)
        Self.append(sequence, to: &bytes)
        Self.append(acknowledgement, to: &bytes)
        Self.append(payloadLength, to: &bytes)
        return Data(bytes)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { bytes.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(
        _ type: T.Type,
        from data: Data,
        at offset: Int
    ) -> T {
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(bigEndian: raw)
    }
}

public struct Frame: Equatable, Sendable {
    public let header: FrameHeader
    public let payload: Data

    public init(header: FrameHeader, payload: Data) throws {
        guard header.payloadLength <= FrameHeader.maximumPayloadLength else {
            throw FrameCodecError.payloadTooLarge(header.payloadLength)
        }
        guard payload.count == Int(header.payloadLength) else {
            throw FrameCodecError.payloadLengthMismatch(
                expected: header.payloadLength,
                actual: payload.count
            )
        }
        self.header = header
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }
}
```

- [ ] **Step 4: Implement the incremental decoder**

Create `Sources/CockpitProtocol/FrameDecoder.swift`:

```swift
import Foundation

public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private var readOffset = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []

        while buffer.count - readOffset >= FrameHeader.encodedLength {
            let header = try FrameHeader(decoding: buffer, at: readOffset)
            let totalLength = FrameHeader.encodedLength + Int(header.payloadLength)
            guard buffer.count - readOffset >= totalLength else { break }

            let payloadStart = readOffset + FrameHeader.encodedLength
            let payloadEnd = readOffset + totalLength
            let payload = Data(buffer[payloadStart..<payloadEnd])
            guard payload.count == Int(header.payloadLength) else {
                throw FrameCodecError.payloadLengthMismatch(expected: header.payloadLength, actual: payload.count)
            }
            frames.append(try Frame(header: header, payload: payload))
            readOffset += totalLength
        }

        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 64 * 1_024 {
            buffer = Data(buffer[readOffset...])
            readOffset = 0
        }

        return frames
    }
}
```

- [ ] **Step 5: Run codec tests**

Run:

```bash
swift test --filter CockpitProtocolTests
```

Expected: all handshake, header, fragmentation, and size-limit tests pass.

- [ ] **Step 6: Commit the frame codec**

```bash
git add Sources/CockpitProtocol Tests/CockpitProtocolTests
git commit -m "feat: add framed cockpit data protocol"
```

---

### Task 4: Build transport-independent ClientCore, HostCore, and TerminalCore negotiation

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CockpitClientCore/CockpitTransport.swift`
- Create: `Sources/CockpitClientCore/ConnectionController.swift`
- Create: `Sources/CockpitHostCore/HostHandshakeHandler.swift`
- Create: `Sources/CockpitTerminalCore/TerminalSupervisorHandshakeHandler.swift`
- Create: `Sources/CockpitTerminalCore/TerminalLifecycle.swift`
- Create: `Sources/CockpitTerminalCore/KeeperBootstrap.swift`
- Create: `Sources/CockpitProtocol/ProtocolNegotiator.swift`
- Create: `Tests/CockpitClientCoreTests/ConnectionControllerTests.swift`
- Create: `Tests/CockpitHostCoreTests/HostHandshakeHandlerTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/TerminalSupervisorHandshakeHandlerTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/KeeperBootstrapTests.swift`

**Interfaces:**
- Consumes: protobuf handshake messages and CockpitTypes.
- Produces: `CockpitTransport`, `ConnectionController`, `NegotiatedSession`, `ProtocolNegotiator`, `HostHandshakeHandler`, `TerminalSupervisorHandshakeHandler`, `TerminalLifecycleState`, `KeeperBootstrap`, `KeeperProbeRequest`, `KeeperLaunchReceipt`, and `KeeperRuntimeDescriptor`.

- [ ] **Step 1: Add package products and targets**

Add these products to `Package.swift`:

```swift
.library(name: "CockpitClientCore", targets: ["CockpitClientCore"]),
.library(name: "CockpitHostCore", targets: ["CockpitHostCore"]),
.library(name: "CockpitTerminalCore", targets: ["CockpitTerminalCore"]),
```

Add these targets:

```swift
.target(name: "CockpitClientCore", dependencies: ["CockpitTypes", "CockpitProtocol"]),
.target(name: "CockpitHostCore", dependencies: ["CockpitTypes", "CockpitProtocol"]),
.target(name: "CockpitTerminalCore", dependencies: ["CockpitTypes", "CockpitProtocol"]),
.testTarget(
    name: "CockpitClientCoreTests",
    dependencies: ["CockpitClientCore", "CockpitTypes", "CockpitProtocol"]
),
.testTarget(
    name: "CockpitHostCoreTests",
    dependencies: ["CockpitHostCore", "CockpitTypes", "CockpitProtocol"]
),
.testTarget(
    name: "CockpitTerminalCoreTests",
    dependencies: ["CockpitTerminalCore", "CockpitTypes", "CockpitProtocol"]
),
```

- [ ] **Step 2: Write failing negotiation tests**

Create `Tests/CockpitHostCoreTests/HostHandshakeHandlerTests.swift`:

```swift
import Testing
import Foundation
import CockpitTypes
import CockpitProtocol
@testable import CockpitHostCore

@Test func hostAcceptsIntersectionOfFeatures() throws {
    let handler = HostHandshakeHandler()
    let deviceUUID = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000020")
    )
    let request = CPHandshakeRequest.cockpit(
        deviceID: DeviceID(deviceUUID),
        features: [.workspaceControl, .terminalFrames]
    )
    let response = try handler.handle(request)
    #expect(response.serviceKind == "host")
    #expect(response.acceptedFeatures == ["workspace-control"])
}

@Test func hostRejectsAnotherMajorVersion() {
    var request = CPHandshakeRequest()
    request.protocolMajor = 2
    request.protocolMinor = 0
    request.deviceID = UUID().uuidString
    #expect(throws: ProtocolNegotiationError.incompatibleMajor(client: 2, service: 1)) {
        _ = try HostHandshakeHandler().handle(request)
    }
}
```

Create `Tests/CockpitTerminalCoreTests/TerminalSupervisorHandshakeHandlerTests.swift`:

```swift
import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
@testable import CockpitTerminalCore

@Test func terminalAdvertisesTerminalFeaturesOnly() throws {
    let request = CPHandshakeRequest.cockpit(
        deviceID: DeviceID(),
        features: [.workspaceControl, .terminalControl, .terminalFrames]
    )
    let response = try TerminalSupervisorHandshakeHandler().handle(request)
    #expect(response.serviceKind == "terminal")
    #expect(response.acceptedFeatures == ["terminal-control", "terminal-frames"])
}
```

Create `Tests/CockpitTerminalCoreTests/KeeperBootstrapTests.swift`:

```swift
import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Test func terminalLifecycleRawValuesRemainStable() {
    #expect(TerminalLifecycleState.allCases.map(\.rawValue) == [
        "preparing", "committed", "running", "exited", "terminated", "interrupted",
    ])
}

@Test func keeperBootstrapRoundTripsWithoutArgvState() throws {
    let sessionUUID = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000031")
    )
    let workerUUID = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000032")
    )
    let bootstrap = KeeperBootstrap(
        sessionID: TerminalSessionID(sessionUUID),
        workerInstanceID: WorkerInstanceID(workerUUID),
        runtimeDirectory: "/private/tmp/cockpit.501/terminal"
    )
    let encoded = try JSONEncoder().encode(bootstrap)
    #expect(try JSONDecoder().decode(KeeperBootstrap.self, from: encoded) == bootstrap)
    #expect(KeeperBootstrap.inheritedFileDescriptor == 3)
    #expect(KeeperBootstrap.bootstrapTimeoutNanoseconds == 30_000_000_000)
}
```

- [ ] **Step 3: Run the handler tests and verify failure**

Run:

```bash
swift test --filter CockpitHostCoreTests
swift test --filter CockpitTerminalCoreTests
```

Expected: compilation fails because the negotiation handlers do not exist.

- [ ] **Step 4: Implement generic protocol negotiation**

Create `Sources/CockpitProtocol/ProtocolNegotiator.swift`:

```swift
import Foundation
import CockpitTypes

public enum ProtocolNegotiationError: Error, Equatable {
    case incompatibleMajor(client: UInt32, service: UInt16)
    case invalidDeviceID(String)
    case invalidConnectionID(String)
    case invalidProtocolVersion(major: UInt32, minor: UInt32)
}

public struct ProtocolNegotiator: Sendable {
    public let serviceKind: String
    public let supportedVersion: ProtocolVersion
    public let supportedFeatures: Set<ProtocolFeature>

    public init(serviceKind: String, supportedVersion: ProtocolVersion = .current, supportedFeatures: Set<ProtocolFeature>) {
        self.serviceKind = serviceKind
        self.supportedVersion = supportedVersion
        self.supportedFeatures = supportedFeatures
    }

    public func negotiate(_ request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        guard request.protocolMajor == UInt32(supportedVersion.major) else {
            throw ProtocolNegotiationError.incompatibleMajor(
                client: request.protocolMajor,
                service: supportedVersion.major
            )
        }
        guard UUID(uuidString: request.deviceID) != nil else {
            throw ProtocolNegotiationError.invalidDeviceID(request.deviceID)
        }

        let requested = Set(request.requestedFeatures.map { ProtocolFeature(rawValue: $0) })
        let clientMinor = UInt16(clamping: request.protocolMinor)
        var response = CPHandshakeResponse()
        response.protocolMajor = UInt32(supportedVersion.major)
        response.protocolMinor = UInt32(min(clientMinor, supportedVersion.minor))
        response.connectionID = ConnectionID().description
        response.acceptedFeatures = requested.intersection(supportedFeatures).map(\.rawValue).sorted()
        response.serviceKind = serviceKind
        return response
    }
}
```

Create `Sources/CockpitHostCore/HostHandshakeHandler.swift`:

```swift
import CockpitProtocol
import CockpitTypes

public struct HostHandshakeHandler: Sendable {
    private let negotiator = ProtocolNegotiator(
        serviceKind: "host",
        supportedFeatures: [.workspaceControl, .remoteDirect]
    )

    public init() {}

    public func handle(_ request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        try negotiator.negotiate(request)
    }
}
```

Create `Sources/CockpitTerminalCore/TerminalSupervisorHandshakeHandler.swift`:

```swift
import CockpitProtocol
import CockpitTypes

public struct TerminalSupervisorHandshakeHandler: Sendable {
    private let negotiator = ProtocolNegotiator(
        serviceKind: "terminal",
        supportedFeatures: [.terminalControl, .terminalFrames]
    )

    public init() {}

    public func handle(_ request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        try negotiator.negotiate(request)
    }
}
```

Create `Sources/CockpitTerminalCore/TerminalLifecycle.swift`:

```swift
public enum TerminalLifecycleState: String, Codable, CaseIterable, Sendable {
    case preparing
    case committed
    case running
    case exited
    case terminated
    case interrupted
}
```

Create `Sources/CockpitTerminalCore/KeeperBootstrap.swift`:

```swift
import Foundation
import CockpitTypes

public struct KeeperBootstrap: Codable, Equatable, Sendable {
    public static let inheritedFileDescriptor: Int32 = 3
    public static let bootstrapTimeoutNanoseconds: UInt64 = 30_000_000_000

    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let runtimeDirectory: String

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        runtimeDirectory: String
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.runtimeDirectory = runtimeDirectory
    }

    public var runtimeDescriptorPath: String {
        URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionID).\(workerInstanceID).json")
            .path
    }
}

public struct KeeperProbeRequest: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID

    public init(sessionID: TerminalSessionID, workerInstanceID: WorkerInstanceID) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
    }
}

public struct KeeperLaunchReceipt: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let processID: Int32
    public let runtimeDescriptorPath: String

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        processID: Int32,
        runtimeDescriptorPath: String
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.processID = processID
        self.runtimeDescriptorPath = runtimeDescriptorPath
    }
}

public struct KeeperRuntimeDescriptor: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let processID: Int32
    public let processGroupID: Int32

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        processID: Int32,
        processGroupID: Int32
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.processID = processID
        self.processGroupID = processGroupID
    }
}
```

- [ ] **Step 5: Run terminal lifecycle and negotiation tests**

Run:

```bash
swift test --filter CockpitTerminalCoreTests
```

Expected: the handshake, stable lifecycle raw-value, and bootstrap round-trip tests pass.

- [ ] **Step 6: Write the failing ClientCore state-machine test**

Create `Tests/CockpitClientCoreTests/ConnectionControllerTests.swift`:

```swift
import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
@testable import CockpitClientCore

private actor FakeTransport: CockpitTransport {
    let response: Data
    private(set) var disconnected = false

    init(response: Data) { self.response = response }
    func connect() async throws {}
    func exchangeHandshake(_ request: Data) async throws -> Data { response }
    func disconnect() async { disconnected = true }
}

@Test func controllerReachesReadyWithNegotiatedSession() async throws {
    let request = CPHandshakeRequest.cockpit(deviceID: DeviceID(), features: [.workspaceControl])
    let response = try HostHandshakeHandlerFixture.response(for: request)
    let transport = FakeTransport(response: try HandshakeCodec.encode(response))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    let session = try await controller.connect(requestedFeatures: [.workspaceControl])
    #expect(session.serviceKind == "host")
    #expect(session.acceptedFeatures == [.workspaceControl])
    let state = await controller.state
    #expect(state == .ready(session))
}

private enum HostHandshakeHandlerFixture {
    static func response(for request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        try ProtocolNegotiator(serviceKind: "host", supportedFeatures: [.workspaceControl]).negotiate(request)
    }
}
```

- [ ] **Step 7: Run the ClientCore test and verify failure**

Run:

```bash
swift test --filter CockpitClientCoreTests
```

Expected: compilation fails because `CockpitTransport`, `ConnectionController`, and `NegotiatedSession` do not exist.

- [ ] **Step 8: Implement CockpitTransport and ConnectionController**

Create `Sources/CockpitClientCore/CockpitTransport.swift`:

```swift
import Foundation
import CockpitTypes

public protocol CockpitTransport: Sendable {
    func connect() async throws
    func exchangeHandshake(_ request: Data) async throws -> Data
    func disconnect() async
}

public struct NegotiatedSession: Equatable, Sendable {
    public let connectionID: ConnectionID
    public let version: ProtocolVersion
    public let acceptedFeatures: Set<ProtocolFeature>
    public let serviceKind: String

    public init(connectionID: ConnectionID, version: ProtocolVersion, acceptedFeatures: Set<ProtocolFeature>, serviceKind: String) {
        self.connectionID = connectionID
        self.version = version
        self.acceptedFeatures = acceptedFeatures
        self.serviceKind = serviceKind
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready(NegotiatedSession)
}
```

Create `Sources/CockpitClientCore/ConnectionController.swift`:

```swift
import Foundation
import CockpitTypes
import CockpitProtocol

public actor ConnectionController {
    public private(set) var state: ConnectionState = .disconnected
    private let transport: any CockpitTransport
    private let deviceID: DeviceID

    public init(transport: any CockpitTransport, deviceID: DeviceID) {
        self.transport = transport
        self.deviceID = deviceID
    }

    public func connect(requestedFeatures: Set<ProtocolFeature>) async throws -> NegotiatedSession {
        state = .connecting
        do {
            try await transport.connect()
            let request = CPHandshakeRequest.cockpit(deviceID: deviceID, features: requestedFeatures)
            let responseData = try await transport.exchangeHandshake(HandshakeCodec.encode(request))
            let response = try HandshakeCodec.decodeResponse(responseData)
            guard let uuid = UUID(uuidString: response.connectionID) else {
                throw ProtocolNegotiationError.invalidConnectionID(response.connectionID)
            }
            guard
                response.protocolMajor <= UInt32(UInt16.max),
                response.protocolMinor <= UInt32(UInt16.max)
            else {
                throw ProtocolNegotiationError.invalidProtocolVersion(
                    major: response.protocolMajor,
                    minor: response.protocolMinor
                )
            }
            let negotiatedVersion = ProtocolVersion(
                major: UInt16(response.protocolMajor),
                minor: UInt16(response.protocolMinor)
            )
            guard negotiatedVersion.major == ProtocolVersion.current.major else {
                throw ProtocolNegotiationError.incompatibleMajor(
                    client: response.protocolMajor,
                    service: ProtocolVersion.current.major
                )
            }
            let session = NegotiatedSession(
                connectionID: ConnectionID(uuid),
                version: negotiatedVersion,
                acceptedFeatures: Set(response.acceptedFeatures.map { ProtocolFeature(rawValue: $0) }),
                serviceKind: response.serviceKind
            )
            state = .ready(session)
            return session
        } catch {
            state = .disconnected
            await transport.disconnect()
            throw error
        }
    }
}
```

- [ ] **Step 9: Run all negotiation tests**

Run:

```bash
swift test --filter CockpitClientCoreTests
swift test --filter CockpitHostCoreTests
swift test --filter CockpitTerminalCoreTests
```

Expected: all three test targets pass.

- [ ] **Step 10: Commit core negotiation and terminal lifecycle values**

```bash
git add Package.swift Sources/CockpitClientCore Sources/CockpitHostCore Sources/CockpitTerminalCore Sources/CockpitProtocol Tests/CockpitClientCoreTests Tests/CockpitHostCoreTests Tests/CockpitTerminalCoreTests
git commit -m "feat: add transport independent negotiation cores"
```

---

### Task 5: Implement local XPC control adapters

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CockpitLocalTransport/XPCHandshakeProtocol.swift`
- Create: `Sources/CockpitLocalTransport/XPCHandshakeExport.swift`
- Create: `Sources/CockpitLocalTransport/XPCHandshakeClient.swift`
- Create: `Sources/CockpitLocalTransport/XPCPeerValidator.swift`
- Create: `Sources/CockpitLocalTransport/MachServiceListenerDelegate.swift`
- Create: `Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift`
- Create: `Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift`
- Create: `Sources/CockpitLocalTransport/TerminalSupervisorXPCClient.swift`
- Create: `Tests/CockpitLocalTransportTests/XPCHandshakeExportTests.swift`

**Interfaces:**
- Consumes: `CockpitTransport`, `HandshakeCodec`, `HostHandshakeHandler`, `TerminalSupervisorHandshakeHandler`, `KeeperProbeRequest`, and `KeeperLaunchReceipt`.
- Produces: `XPCHandshakeProtocol`, `XPCHandshakeExport`, `XPCHandshakeClient`, `TerminalSupervisorXPCProtocol`, `TerminalSupervisorXPCExport`, and `TerminalSupervisorXPCClient`.

- [ ] **Step 1: Add the local transport product and test target**

Add products:

```swift
.library(name: "CockpitLocalTransport", targets: ["CockpitLocalTransport"]),
```

Add targets:

```swift
.target(
    name: "CockpitLocalTransport",
    dependencies: [
        "CockpitClientCore",
        "CockpitProtocol",
        "CockpitTerminalCore",
    ]
),
.testTarget(
    name: "CockpitLocalTransportTests",
    dependencies: [
        "CockpitLocalTransport",
        "CockpitHostCore",
        "CockpitProtocol",
        "CockpitTerminalCore",
        "CockpitTypes",
    ]
),
```

- [ ] **Step 2: Write failing XPC boundary tests**

Create `Tests/CockpitLocalTransportTests/XPCHandshakeExportTests.swift`:

```swift
import Foundation
import Testing
import CockpitProtocol
import CockpitTypes
import CockpitHostCore
@testable import CockpitLocalTransport

@Test func exportedObjectReturnsEncodedHandshake() async throws {
    let exported = XPCHandshakeExport { request in
        try HostHandshakeHandler().handle(request)
    }
    let request = CPHandshakeRequest.cockpit(
        deviceID: DeviceID(),
        features: [.workspaceControl]
    )

    let encodedRequest = try HandshakeCodec.encode(request)
    let responseData: Data = try await withCheckedThrowingContinuation { continuation in
        exported.exchangeHandshake(encodedRequest) { data, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: CocoaError(.coderInvalidValue))
            }
        }
    }

    let response = try HandshakeCodec.decodeResponse(responseData)
    #expect(response.serviceKind == "host")
}

@Test func peerValidatorAcceptsOnlyTheConfiguredEffectiveUser() {
    let validator = XPCPeerValidator(expectedEffectiveUserIdentifier: 501)
    #expect(validator.accepts(effectiveUserIdentifier: 501))
    #expect(!validator.accepts(effectiveUserIdentifier: 502))
}
```

- [ ] **Step 3: Run the local transport tests and verify failure**

Run:

```bash
swift test --filter CockpitLocalTransportTests
```

Expected: compilation fails because `XPCHandshakeExport` does not exist.

- [ ] **Step 4: Implement the shared XPC handshake boundary**

Create `Sources/CockpitLocalTransport/XPCHandshakeProtocol.swift`:

```swift
import Foundation

@objc public protocol XPCHandshakeProtocol {
    func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}
```

Create `Sources/CockpitLocalTransport/XPCHandshakeExport.swift`:

```swift
import Foundation
import CockpitProtocol

public final class XPCHandshakeExport: NSObject, XPCHandshakeProtocol, @unchecked Sendable {
    public typealias Handler = @Sendable (CPHandshakeRequest) throws -> CPHandshakeResponse

    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let decoded = try HandshakeCodec.decodeRequest(request)
            reply(try HandshakeCodec.encode(handler(decoded)), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}
```

Create `Sources/CockpitLocalTransport/XPCHandshakeClient.swift`:

```swift
import Foundation
import CockpitClientCore

public actor XPCHandshakeClient: CockpitTransport {
    private let serviceName: String
    private var connection: NSXPCConnection?

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    public func connect() async throws {
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: XPCHandshakeProtocol.self)
        connection.resume()
        self.connection = connection
    }

    public func exchangeHandshake(_ request: Data) async throws -> Data {
        guard let connection else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let proxy = remote as? XPCHandshakeProtocol else {
                continuation.resume(throwing: CocoaError(.coderInvalidValue))
                return
            }
            proxy.exchangeHandshake(request) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CocoaError(.coderInvalidValue))
                }
            }
        }
    }

    public func disconnect() async {
        connection?.invalidate()
        connection = nil
    }
}
```

Create `Sources/CockpitLocalTransport/XPCPeerValidator.swift`:

```swift
import Darwin

public struct XPCPeerValidator: Sendable {
    public let expectedEffectiveUserIdentifier: uid_t

    public init(expectedEffectiveUserIdentifier: uid_t) {
        self.expectedEffectiveUserIdentifier = expectedEffectiveUserIdentifier
    }

    public static let currentUser = Self(expectedEffectiveUserIdentifier: geteuid())

    public func accepts(effectiveUserIdentifier: uid_t) -> Bool {
        effectiveUserIdentifier == expectedEffectiveUserIdentifier
    }
}
```

Create `Sources/CockpitLocalTransport/MachServiceListenerDelegate.swift`:

```swift
import Foundation

public final class MachServiceListenerDelegate:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    private let exportedObject: Any
    private let exportedInterface: NSXPCInterface
    private let peerValidator: XPCPeerValidator

    public init(
        exportedObject: Any,
        exportedInterface: NSXPCInterface,
        peerValidator: XPCPeerValidator = .currentUser
    ) {
        self.exportedObject = exportedObject
        self.exportedInterface = exportedInterface
        self.peerValidator = peerValidator
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard peerValidator.accepts(
            effectiveUserIdentifier: connection.effectiveUserIdentifier
        ) else {
            return false
        }
        connection.exportedInterface = exportedInterface
        connection.exportedObject = exportedObject
        connection.resume()
        return true
    }
}
```

- [ ] **Step 5: Implement the Supervisor-only XPC control boundary**

Create `Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift`:

```swift
import Foundation

@objc public protocol TerminalSupervisorXPCProtocol: XPCHandshakeProtocol {
    func spawnKeeperProbe(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}
```

Create `Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift`:

```swift
import Foundation
import CockpitProtocol
import CockpitTerminalCore

public final class TerminalSupervisorXPCExport:
    NSObject,
    TerminalSupervisorXPCProtocol,
    @unchecked Sendable
{
    public typealias HandshakeHandler =
        @Sendable (CPHandshakeRequest) throws -> CPHandshakeResponse
    public typealias SpawnHandler =
        @Sendable (KeeperProbeRequest) throws -> KeeperLaunchReceipt

    private let handshakeHandler: HandshakeHandler
    private let spawnHandler: SpawnHandler

    public init(
        handshakeHandler: @escaping HandshakeHandler,
        spawnHandler: @escaping SpawnHandler
    ) {
        self.handshakeHandler = handshakeHandler
        self.spawnHandler = spawnHandler
    }

    public func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let decoded = try HandshakeCodec.decodeRequest(request)
            reply(try HandshakeCodec.encode(handshakeHandler(decoded)), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    public func spawnKeeperProbe(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let decoded = try JSONDecoder().decode(KeeperProbeRequest.self, from: request)
            reply(try JSONEncoder().encode(spawnHandler(decoded)), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}
```

Create `Sources/CockpitLocalTransport/TerminalSupervisorXPCClient.swift`:

```swift
import Foundation
import CockpitTerminalCore

public actor TerminalSupervisorXPCClient {
    private let serviceName: String
    private var connection: NSXPCConnection?

    public init(serviceName: String = "dev.cockpit.terminal") {
        self.serviceName = serviceName
    }

    public func connect() {
        guard connection == nil else { return }
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: TerminalSupervisorXPCProtocol.self
        )
        connection.resume()
        self.connection = connection
    }

    public func spawnKeeperProbe(
        _ request: KeeperProbeRequest
    ) async throws -> KeeperLaunchReceipt {
        connect()
        guard let connection else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let proxy = remote as? TerminalSupervisorXPCProtocol else {
                continuation.resume(throwing: CocoaError(.coderInvalidValue))
                return
            }
            proxy.spawnKeeperProbe(data) { data, error in
                do {
                    if let error { throw error }
                    guard let data else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    continuation.resume(
                        returning: try JSONDecoder().decode(
                            KeeperLaunchReceipt.self,
                            from: data
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }
}
```

- [ ] **Step 6: Run all local XPC tests**

Run:

```bash
swift test --filter CockpitLocalTransportTests
```

Expected: XPC encoding, effective-user validation, and Supervisor control-boundary compilation all pass.

- [ ] **Step 7: Commit the local XPC control plane**

```bash
git add Package.swift Sources/CockpitLocalTransport Tests/CockpitLocalTransportTests/XPCHandshakeExportTests.swift
git commit -m "feat: add local xpc control transport"
```

---

### Task 6: Establish the isolated PTYKeeper process boundary

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CockpitLocalTransport/KeeperProcessLauncher.swift`
- Create: `Applications/CockpitHost/main.swift`
- Create: `Applications/CockpitTerminalSupervisor/main.swift`
- Create: `Applications/CockpitPTYKeeper/main.swift`
- Create: `Applications/CockpitProbe/main.swift`
- Create: `Config/LaunchAgents/dev.cockpit.host.local.plist.template`
- Create: `Config/LaunchAgents/dev.cockpit.terminal.local.plist.template`
- Create: `Tools/phase0-services.zsh`
- Create: `Tests/CockpitLocalTransportTests/KeeperProcessLauncherTests.swift`
- Create: `Tests/ProcessIntegrationTests/service-keeper-foundation.zsh`

**Interfaces:**
- Consumes: the Task 5 XPC adapters plus `KeeperProbeRequest`, `KeeperBootstrap`, `KeeperLaunchReceipt`, and `KeeperRuntimeDescriptor` from CockpitTerminalCore.
- Produces: `KeeperProcessLauncher.launch(_:)`, three service executable composition roots, one diagnostic Probe executable, two development LaunchAgent fixtures, and the process-isolation integration gate.
- Phase boundary: CockpitPTYKeeper reads bootstrap data from inherited file descriptor `3` and writes a readiness descriptor; it does not create a PTY or Agent CLI in Phase 0.

- [ ] **Step 1: Add three service executables and one diagnostic Probe target**

Add products:

```swift
.executable(name: "CockpitHost", targets: ["CockpitHost"]),
.executable(name: "CockpitTerminalSupervisor", targets: ["CockpitTerminalSupervisor"]),
.executable(name: "CockpitPTYKeeper", targets: ["CockpitPTYKeeper"]),
.executable(name: "CockpitProbe", targets: ["CockpitProbe"]),
```

Add targets:

```swift
.executableTarget(
    name: "CockpitHost",
    dependencies: ["CockpitHostCore", "CockpitLocalTransport"],
    path: "Applications/CockpitHost"
),
.executableTarget(
    name: "CockpitTerminalSupervisor",
    dependencies: ["CockpitTerminalCore", "CockpitLocalTransport"],
    path: "Applications/CockpitTerminalSupervisor"
),
.executableTarget(
    name: "CockpitPTYKeeper",
    dependencies: ["CockpitTerminalCore"],
    path: "Applications/CockpitPTYKeeper"
),
.executableTarget(
    name: "CockpitProbe",
    dependencies: [
        "CockpitClientCore",
        "CockpitLocalTransport",
        "CockpitTerminalCore",
        "CockpitTypes",
    ],
    path: "Applications/CockpitProbe"
),
```

- [ ] **Step 2: Write the failing Keeper spawn-policy test**

Create `Tests/CockpitLocalTransportTests/KeeperProcessLauncherTests.swift`:

```swift
import Darwin
import Testing
@testable import CockpitLocalTransport

@Test func keeperSpawnFlagsCreateIndependentSessionAndCloseUndeclaredDescriptors() {
    #expect(
        KeeperProcessLauncher.spawnFlags
            == Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
    )
}
```

- [ ] **Step 3: Run the spawn-policy test and verify failure**

Run:

```bash
swift test --filter CockpitLocalTransportTests.keeperSpawnFlagsCreateIndependentSessionAndCloseUndeclaredDescriptors
```

Expected: compilation fails because `KeeperProcessLauncher` does not exist.

- [ ] **Step 4: Implement the detached Keeper launcher**

Create `Sources/CockpitLocalTransport/KeeperProcessLauncher.swift`:

```swift
import Darwin
import Foundation
import CockpitTerminalCore

public struct KeeperLaunchFailure: Error, Equatable, Sendable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

public struct KeeperProcessLauncher: Sendable {
    public static let spawnFlags =
        Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)

    public let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    public func launch(_ bootstrap: KeeperBootstrap) throws -> KeeperLaunchReceipt {
        let payload = try JSONEncoder().encode(bootstrap)

        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = pipeDescriptors.withUnsafeMutableBufferPointer {
            Darwin.pipe($0.baseAddress)
        }
        guard pipeResult == 0 else {
            throw KeeperLaunchFailure(operation: "pipe", code: errno)
        }

        var readDescriptor = pipeDescriptors[0]
        let writeDescriptor = pipeDescriptors[1]

        if readDescriptor == KeeperBootstrap.inheritedFileDescriptor {
            let duplicated = fcntl(readDescriptor, F_DUPFD_CLOEXEC, 4)
            guard duplicated >= 0 else {
                let code = errno
                Darwin.close(readDescriptor)
                Darwin.close(writeDescriptor)
                throw KeeperLaunchFailure(operation: "fcntl", code: code)
            }
            Darwin.close(readDescriptor)
            readDescriptor = duplicated
        }

        let readHandle = FileHandle(
            fileDescriptor: readDescriptor,
            closeOnDealloc: true
        )
        let writeHandle = FileHandle(
            fileDescriptor: writeDescriptor,
            closeOnDealloc: true
        )

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?

        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else {
            throw KeeperLaunchFailure(
                operation: "posix_spawn_file_actions_init",
                code: result
            )
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawnattr_init", code: result)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        result = posix_spawn_file_actions_adddup2(
            &actions,
            readDescriptor,
            KeeperBootstrap.inheritedFileDescriptor
        )
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawn_file_actions_adddup2", code: result)
        }

        result = posix_spawn_file_actions_addclose(&actions, readDescriptor)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawn_file_actions_addclose(read)", code: result)
        }

        result = posix_spawn_file_actions_addclose(&actions, writeDescriptor)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawn_file_actions_addclose(write)", code: result)
        }

        result = posix_spawnattr_setflags(&attributes, Self.spawnFlags)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawnattr_setflags", code: result)
        }

        var processID: pid_t = 0
        result = executablePath.withCString { executable in
            var arguments: [UnsafeMutablePointer<CChar>?] = [
                UnsafeMutablePointer(mutating: executable),
                nil,
            ]
            return arguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    &attributes,
                    buffer.baseAddress,
                    environ
                )
            }
        }

        try readHandle.close()

        guard result == 0 else {
            try? writeHandle.close()
            throw KeeperLaunchFailure(operation: "posix_spawn", code: result)
        }

        do {
            try writeHandle.write(contentsOf: payload)
            try writeHandle.close()
        } catch {
            Darwin.kill(processID, SIGKILL)
            throw error
        }

        return KeeperLaunchReceipt(
            sessionID: bootstrap.sessionID,
            workerInstanceID: bootstrap.workerInstanceID,
            processID: processID,
            runtimeDescriptorPath: bootstrap.runtimeDescriptorPath
        )
    }
}
```

Run:

```bash
swift test --filter CockpitLocalTransportTests
```

Expected: both local transport tests pass, including the exact Darwin spawn flags.

- [ ] **Step 5: Implement the three service composition roots and diagnostic Probe**

Create `Applications/CockpitHost/main.swift`:

```swift
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
```

Create `Applications/CockpitTerminalSupervisor/main.swift`:

```swift
import Darwin
import Foundation
import CockpitLocalTransport
import CockpitTerminalCore

func optionalValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func setOwnerOnlyDirectoryMode(_ path: String) throws {
    let result = path.withCString { chmod($0, S_IRWXU) }
    guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
}

let arguments = CommandLine.arguments
_ = signal(SIGCHLD, SIG_IGN)
_ = umask(S_IRWXG | S_IRWXO)
let ownExecutable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let keeperExecutable = optionalValue(after: "--keeper-executable", in: arguments)
    ?? ownExecutable.deletingLastPathComponent()
        .appendingPathComponent("CockpitPTYKeeper").path
let runtimeDirectory = optionalValue(after: "--runtime-directory", in: arguments)
    ?? "/private/tmp/cockpit.\(geteuid())/terminal"

try FileManager.default.createDirectory(
    atPath: runtimeDirectory,
    withIntermediateDirectories: true
)
try setOwnerOnlyDirectoryMode(runtimeDirectory)

let launcher = KeeperProcessLauncher(executablePath: keeperExecutable)
let exported = TerminalSupervisorXPCExport(
    handshakeHandler: { try TerminalSupervisorHandshakeHandler().handle($0) },
    spawnHandler: { request in
        try launcher.launch(
            KeeperBootstrap(
                sessionID: request.sessionID,
                workerInstanceID: request.workerInstanceID,
                runtimeDirectory: runtimeDirectory
            )
        )
    }
)
let delegate = MachServiceListenerDelegate(
    exportedObject: exported,
    exportedInterface: NSXPCInterface(with: TerminalSupervisorXPCProtocol.self)
)
let listener = NSXPCListener(machServiceName: "dev.cockpit.terminal")
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
```

Create `Applications/CockpitPTYKeeper/main.swift`:

```swift
import Darwin
import Dispatch
import Foundation
import CockpitTerminalCore

_ = signal(SIGCHLD, SIG_DFL)
_ = umask(S_IRWXG | S_IRWXO)

func setOwnerOnlyMode(_ path: String, _ mode: mode_t) throws {
    let result = path.withCString { chmod($0, mode) }
    guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
}

let bootstrapHandle = FileHandle(
    fileDescriptor: KeeperBootstrap.inheritedFileDescriptor,
    closeOnDealloc: true
)
guard
    let bootstrapData = try bootstrapHandle.readToEnd(),
    !bootstrapData.isEmpty
else {
    throw CocoaError(.fileReadCorruptFile)
}

let bootstrap = try JSONDecoder().decode(KeeperBootstrap.self, from: bootstrapData)
try FileManager.default.createDirectory(
    atPath: bootstrap.runtimeDirectory,
    withIntermediateDirectories: true
)
try setOwnerOnlyMode(bootstrap.runtimeDirectory, S_IRWXU)

let descriptor = KeeperRuntimeDescriptor(
    sessionID: bootstrap.sessionID,
    workerInstanceID: bootstrap.workerInstanceID,
    processID: getpid(),
    processGroupID: getpgrp()
)
let descriptorURL = URL(fileURLWithPath: bootstrap.runtimeDescriptorPath)
try JSONEncoder().encode(descriptor).write(to: descriptorURL, options: .atomic)
try setOwnerOnlyMode(descriptorURL.path, S_IRUSR | S_IWUSR)

dispatchMain()
```

Create `Applications/CockpitProbe/main.swift`:

```swift
import Foundation
import CockpitClientCore
import CockpitLocalTransport
import CockpitTerminalCore
import CockpitTypes

enum ProbeError: Error {
    case invalidCommand
}

@main
enum CockpitProbe {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first {
        case "services":
            try await probeServices()
        case "spawn-keeper":
            try await spawnKeeper()
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func probeServices() async throws {
        for service in ["dev.cockpit.host", "dev.cockpit.terminal"] {
            let controller = ConnectionController(
                transport: XPCHandshakeClient(serviceName: service),
                deviceID: DeviceID()
            )
            let session = try await controller.connect(
                requestedFeatures: [
                    .workspaceControl,
                    .terminalControl,
                    .terminalFrames,
                ]
            )
            print(
                "\(service) \(session.serviceKind) "
                    + "\(session.version.major).\(session.version.minor)"
            )
        }
    }

    private static func spawnKeeper() async throws {
        let client = TerminalSupervisorXPCClient()
        let receipt = try await client.spawnKeeperProbe(
            KeeperProbeRequest(
                sessionID: TerminalSessionID(),
                workerInstanceID: WorkerInstanceID()
            )
        )
        await client.disconnect()
        print(
            [
                String(receipt.processID),
                receipt.sessionID.description,
                receipt.workerInstanceID.description,
                receipt.runtimeDescriptorPath,
            ].joined(separator: "\t")
        )
    }
}
```

- [ ] **Step 6: Create launchd fixtures and the local service harness**

Create `Config/LaunchAgents/dev.cockpit.host.local.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.cockpit.host.local</string>
  <key>ProgramArguments</key>
  <array><string>__EXECUTABLE__</string></array>
  <key>MachServices</key>
  <dict><key>dev.cockpit.host</key><true/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
```

Create `Config/LaunchAgents/dev.cockpit.terminal.local.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.cockpit.terminal.local</string>
  <key>ProgramArguments</key>
  <array>
    <string>__EXECUTABLE__</string>
    <string>--keeper-executable</string>
    <string>__KEEPER_EXECUTABLE__</string>
    <string>--runtime-directory</string>
    <string>__RUNTIME_DIRECTORY__</string>
  </array>
  <key>MachServices</key>
  <dict><key>dev.cockpit.terminal</key><true/></dict>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
```

Create `Tools/phase0-services.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
fixture_dir="$repo_root/.build/phase0-launchagents"
runtime_dir="$repo_root/.build/phase0-runtime"
domain="gui/$(id -u)"

stop_service() {
  /bin/launchctl bootout "$domain/$1" >/dev/null 2>&1 || true
}

render_host() {
  /usr/bin/sed \
    "s|__EXECUTABLE__|$1|g" \
    "$repo_root/Config/LaunchAgents/dev.cockpit.host.local.plist.template" \
    > "$fixture_dir/host.plist"
}

render_terminal() {
  /usr/bin/sed \
    -e "s|__EXECUTABLE__|$1|g" \
    -e "s|__KEEPER_EXECUTABLE__|$2|g" \
    -e "s|__RUNTIME_DIRECTORY__|$runtime_dir|g" \
    "$repo_root/Config/LaunchAgents/dev.cockpit.terminal.local.plist.template" \
    > "$fixture_dir/terminal.plist"
}

case "${1:-}" in
  start)
    swift build
    /bin/mkdir -p "$fixture_dir" "$runtime_dir"
    /bin/chmod 700 "$runtime_dir"

    host="$repo_root/.build/debug/CockpitHost"
    terminal="$repo_root/.build/debug/CockpitTerminalSupervisor"
    keeper="$repo_root/.build/debug/CockpitPTYKeeper"
    probe="$repo_root/.build/debug/CockpitProbe"

    /usr/bin/codesign --force --sign - "$host"
    /usr/bin/codesign --force --sign - "$terminal"
    /usr/bin/codesign --force --sign - "$keeper"
    /usr/bin/codesign --force --sign - "$probe"

    render_host "$host"
    render_terminal "$terminal" "$keeper"

    stop_service dev.cockpit.host.local
    stop_service dev.cockpit.terminal.local
    /bin/launchctl bootstrap "$domain" "$fixture_dir/host.plist"
    /bin/launchctl bootstrap "$domain" "$fixture_dir/terminal.plist"
    ;;
  stop)
    stop_service dev.cockpit.host.local
    stop_service dev.cockpit.terminal.local
    ;;
  probe)
    "$repo_root/.build/debug/CockpitProbe" services
    ;;
  spawn-keeper)
    "$repo_root/.build/debug/CockpitProbe" spawn-keeper
    ;;
  *)
    print -u2 "usage: Tools/phase0-services.zsh start|stop|probe|spawn-keeper"
    exit 64
    ;;
esac
```

Run:

```bash
chmod +x Tools/phase0-services.zsh
```

- [ ] **Step 7: Prove the service/Keeper crash boundary**

Create `Tests/ProcessIntegrationTests/service-keeper-foundation.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
domain="gui/$(id -u)"
keeper_pid=""

cleanup() {
  if [[ -n "$keeper_pid" ]]; then
    /bin/kill -TERM "$keeper_pid" >/dev/null 2>&1 || true
  fi
  "$repo_root/Tools/phase0-services.zsh" stop
}
trap cleanup EXIT

"$repo_root/Tools/phase0-services.zsh" start

service_output=$("$repo_root/Tools/phase0-services.zsh" probe)
[[ "$service_output" == *"dev.cockpit.host host 1.0"* ]]
[[ "$service_output" == *"dev.cockpit.terminal terminal 1.0"* ]]

receipt=$("$repo_root/Tools/phase0-services.zsh" spawn-keeper)
IFS=$'\t' read -r keeper_pid session_id worker_id descriptor_path <<< "$receipt"

for _ in {1..100}; do
  [[ -f "$descriptor_path" ]] && break
  /bin/sleep 0.05
done

[[ -f "$descriptor_path" ]]
/usr/bin/grep -q "$session_id" "$descriptor_path"
/usr/bin/grep -q "$worker_id" "$descriptor_path"
/bin/kill -0 "$keeper_pid"

keeper_pgid=$(/bin/ps -o pgid= -p "$keeper_pid" | /usr/bin/tr -d ' ')
[[ "$keeper_pgid" == "$keeper_pid" ]]

/bin/launchctl kill SIGKILL "$domain/dev.cockpit.terminal.local"
/bin/kill -0 "$keeper_pid"

supervisor_ready=0
for _ in {1..120}; do
  if "$repo_root/Tools/phase0-services.zsh" probe >/dev/null 2>&1; then
    supervisor_ready=1
    break
  fi
  /bin/sleep 0.25
done

[[ "$supervisor_ready" == 1 ]]
/bin/kill -0 "$keeper_pid"

/bin/kill -TERM "$keeper_pid"
for _ in {1..100}; do
  /bin/kill -0 "$keeper_pid" >/dev/null 2>&1 || break
  /bin/sleep 0.05
done
! /bin/kill -0 "$keeper_pid" >/dev/null 2>&1
keeper_pid=""
```

Run:

```bash
chmod +x Tests/ProcessIntegrationTests/service-keeper-foundation.zsh
Tests/ProcessIntegrationTests/service-keeper-foundation.zsh
```

Expected:

- both Mach services negotiate protocol `1.0`;
- the Keeper writes a descriptor containing the exact TerminalSessionID and WorkerInstanceID;
- Keeper PID equals Keeper process-group ID;
- killing CockpitTerminalSupervisor does not kill the Keeper;
- launchd restarts CockpitTerminalSupervisor and its XPC handshake succeeds again;
- terminating the Keeper while the replacement Supervisor is alive removes the PID instead of leaving a zombie;
- the test exits `0` and cleans up the isolated Keeper.

- [ ] **Step 8: Commit the Keeper process boundary**

```bash
git add Package.swift Sources/CockpitLocalTransport Applications Config/LaunchAgents Tools/phase0-services.zsh Tests/CockpitLocalTransportTests Tests/ProcessIntegrationTests
git commit -m "feat: establish isolated terminal process boundary"
```

---

### Task 7: Assemble the native AppKit application and helper bundles

**Files:**
- Create: `project.yml`
- Create: `Config/Build/Base.xcconfig`
- Create: `Config/LaunchAgents/dev.cockpit.host.plist`
- Create: `Config/LaunchAgents/dev.cockpit.terminal.plist`
- Create: `Applications/CockpitApp/AppDelegate.swift`
- Create: `Applications/CockpitApp/ServiceStatusViewModel.swift`
- Create: `Cockpit.xcworkspace/contents.xcworkspacedata`
- Create: `Tests/ProcessIntegrationTests/app-bundle-layout.zsh`

**Interfaces:**
- Consumes: CockpitClientCore, CockpitTerminalCore, and CockpitLocalTransport.
- Produces: a native `Cockpit.app` bundle containing CockpitHost, CockpitTerminalSupervisor, and CockpitPTYKeeper executables plus the two LaunchAgent plists at ServiceManagement-compatible paths. CockpitPTYKeeper remains an embedded executable, not a LaunchAgent.

- [ ] **Step 1: Install and verify the pinned XcodeGen tool**

Run:

```bash
brew install xcodegen
xcodegen --version
```

Expected: output is `Version: 2.46.0`.

- [ ] **Step 2: Write the failing bundle-layout test**

Create `Tests/ProcessIntegrationTests/app-bundle-layout.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h:h}
app="$repo_root/build/Debug/Cockpit.app"
test -x "$app/Contents/MacOS/Cockpit"
test -x "$app/Contents/Resources/CockpitHost"
test -x "$app/Contents/Resources/CockpitTerminalSupervisor"
test -x "$app/Contents/Resources/CockpitPTYKeeper"
test -f "$app/Contents/Library/LaunchAgents/dev.cockpit.host.plist"
test -f "$app/Contents/Library/LaunchAgents/dev.cockpit.terminal.plist"
/usr/bin/codesign --verify --deep --strict "$app"
```

Run:

```bash
chmod +x Tests/ProcessIntegrationTests/app-bundle-layout.zsh
Tests/ProcessIntegrationTests/app-bundle-layout.zsh
```

Expected: fails because `build/Debug/Cockpit.app` does not exist.

- [ ] **Step 3: Create build settings and product LaunchAgent plists**

Create `Config/Build/Base.xcconfig`:

```xcconfig
MACOSX_DEPLOYMENT_TARGET = 15.0
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
CODE_SIGNING_REQUIRED = YES
ENABLE_HARDENED_RUNTIME = NO
```

Create `Config/LaunchAgents/dev.cockpit.host.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.cockpit.host</string>
  <key>BundleProgram</key><string>Contents/Resources/CockpitHost</string>
  <key>MachServices</key><dict><key>dev.cockpit.host</key><true/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
```

Create `Config/LaunchAgents/dev.cockpit.terminal.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.cockpit.terminal</string>
  <key>BundleProgram</key><string>Contents/Resources/CockpitTerminalSupervisor</string>
  <key>MachServices</key><dict><key>dev.cockpit.terminal</key><true/></dict>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
```

- [ ] **Step 4: Implement the AppKit status window**

Create `Applications/CockpitApp/ServiceStatusViewModel.swift`:

```swift
import Foundation
import CockpitClientCore
import CockpitLocalTransport
import CockpitTypes

@MainActor
final class ServiceStatusViewModel {
    func statusText() async -> String {
        var rows: [String] = []
        for service in ["dev.cockpit.host", "dev.cockpit.terminal"] {
            do {
                let controller = ConnectionController(
                    transport: XPCHandshakeClient(serviceName: service),
                    deviceID: DeviceID()
                )
                let session = try await controller.connect(
                    requestedFeatures: [.workspaceControl, .terminalControl, .terminalFrames]
                )
                rows.append("\(session.serviceKind): protocol \(session.version.major).\(session.version.minor)")
            } catch {
                rows.append("\(service): unavailable")
            }
        }
        return rows.joined(separator: "\n")
    }
}
```

Create `Applications/CockpitApp/AppDelegate.swift`:

```swift
import AppKit

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "Connecting…")
    private let viewModel = ServiceStatusViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cockpit"
        label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        Task { label.stringValue = await viewModel.statusText() }
    }
}
```

- [ ] **Step 5: Define the XcodeGen project**

Create `project.yml`:

```yaml
name: Cockpit
options:
  bundleIdPrefix: dev.cockpit
  deploymentTarget:
    macOS: "15.0"
configs:
  Debug: debug
  Release: release
packages:
  CockpitKit:
    path: .
settings:
  base:
    PRODUCT_NAME: $(TARGET_NAME)
  configs:
    Debug:
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG
configFiles:
  Debug: Config/Build/Base.xcconfig
  Release: Config/Build/Base.xcconfig
targets:
  CockpitHost:
    type: tool
    platform: macOS
    sources: [Applications/CockpitHost]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.cockpit.CockpitHost
    dependencies:
      - package: CockpitKit
        product: CockpitHostCore
      - package: CockpitKit
        product: CockpitLocalTransport
  CockpitTerminalSupervisor:
    type: tool
    platform: macOS
    sources: [Applications/CockpitTerminalSupervisor]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.cockpit.CockpitTerminalSupervisor
    dependencies:
      - package: CockpitKit
        product: CockpitTerminalCore
      - package: CockpitKit
        product: CockpitLocalTransport
  CockpitPTYKeeper:
    type: tool
    platform: macOS
    sources: [Applications/CockpitPTYKeeper]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.cockpit.CockpitPTYKeeper
    dependencies:
      - package: CockpitKit
        product: CockpitTerminalCore
  Cockpit:
    type: application
    platform: macOS
    sources: [Applications/CockpitApp]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.cockpit.Cockpit
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: Cockpit
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.developer-tools
    dependencies:
      - package: CockpitKit
        product: CockpitClientCore
      - package: CockpitKit
        product: CockpitLocalTransport
      - package: CockpitKit
        product: CockpitTypes
      - target: CockpitHost
      - target: CockpitTerminalSupervisor
      - target: CockpitPTYKeeper
    postBuildScripts:
      - name: Embed LaunchAgents
        script: |
          set -euo pipefail
          resources="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
          agents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchAgents"
          mkdir -p "$resources" "$agents"
          cp "$BUILT_PRODUCTS_DIR/CockpitHost" "$resources/CockpitHost"
          cp "$BUILT_PRODUCTS_DIR/CockpitTerminalSupervisor" "$resources/CockpitTerminalSupervisor"
          cp "$BUILT_PRODUCTS_DIR/CockpitPTYKeeper" "$resources/CockpitPTYKeeper"
          cp "$SRCROOT/Config/LaunchAgents/dev.cockpit.host.plist" "$agents/"
          cp "$SRCROOT/Config/LaunchAgents/dev.cockpit.terminal.plist" "$agents/"
schemes:
  Cockpit:
    build:
      targets:
        Cockpit: all
        CockpitHost: all
        CockpitTerminalSupervisor: all
        CockpitPTYKeeper: all
    run:
      config: Debug
```

- [ ] **Step 6: Generate and build the workspace**

Create `Cockpit.xcworkspace/contents.xcworkspacedata`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="group:Cockpit.xcodeproj"></FileRef>
</Workspace>
```

Run:

```bash
xcodegen generate
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData CONFIGURATION_BUILD_DIR="$PWD/build/Debug" build
Tests/ProcessIntegrationTests/app-bundle-layout.zsh
```

Expected: `** BUILD SUCCEEDED **`, followed by a successful bundle-layout test.

- [ ] **Step 7: Commit the native product shell**

```bash
git add project.yml Cockpit.xcodeproj Cockpit.xcworkspace Config/Build Config/LaunchAgents Applications/CockpitApp Tests/ProcessIntegrationTests/app-bundle-layout.zsh
git commit -m "feat: assemble native cockpit app and agents"
```

---

### Task 8: Prove the RemoteDirectTransport TLS loopback path

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CockpitRemoteTransport/TLSOptionsFactory.swift`
- Create: `Sources/CockpitRemoteTransport/NWConnectionByteStream.swift`
- Create: `Sources/CockpitRemoteTransport/RemoteDirectTransport.swift`
- Create: `Tests/CockpitRemoteTransportTests/RemoteTLSLoopbackTests.swift`
- Create: `Tests/CockpitRemoteTransportTests/TLSFixture.swift`
- Create: `Tests/Fixtures/TLS/generate.zsh`
- Create: `Tools/test-remote-tls.zsh`

**Interfaces:**
- Consumes: CockpitTransport and the protobuf handshake codec.
- Produces: `TLSOptionsFactory`, `NWConnectionByteStream`, and `RemoteDirectTransport` over a TLS 1.3 Network.framework connection.

- [ ] **Step 1: Add the remote transport target**

Add product:

```swift
.library(name: "CockpitRemoteTransport", targets: ["CockpitRemoteTransport"]),
```

Add targets:

```swift
.target(
    name: "CockpitRemoteTransport",
    dependencies: ["CockpitClientCore", "CockpitProtocol"]
),
.testTarget(
    name: "CockpitRemoteTransportTests",
    dependencies: [
        "CockpitRemoteTransport",
        "CockpitHostCore",
        "CockpitProtocol",
        "CockpitTypes",
    ]
),
```

- [ ] **Step 2: Generate a disposable TLS fixture**

Create `Tests/Fixtures/TLS/generate.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail
output=${0:A:h}/generated
rm -rf "$output"
mkdir -p "$output"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$output/key.pem" \
  -out "$output/certificate.pem" \
  -days 2 -subj '/CN=localhost'
/usr/bin/openssl pkcs12 -export \
  -inkey "$output/key.pem" \
  -in "$output/certificate.pem" \
  -out "$output/identity.p12" \
  -passout pass:cockpit-test
```

Run:

```bash
chmod +x Tests/Fixtures/TLS/generate.zsh
Tests/Fixtures/TLS/generate.zsh
```

Expected: `identity.p12` and `certificate.pem` exist under the ignored `generated` directory.

- [ ] **Step 3: Write the failing TLS loopback test**

Create `Tests/CockpitRemoteTransportTests/RemoteTLSLoopbackTests.swift`:

```swift
import Foundation
import Network
import Security
import Testing
import CockpitTypes
import CockpitProtocol
import CockpitHostCore
@testable import CockpitRemoteTransport

@Test func remoteTransportNegotiatesOverTLS13() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity)
    try await server.start()
    defer { server.stop() }
    let serverPort = try #require(server.port)

    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: serverPort.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data
    )
    try await transport.connect()
    let request = CPHandshakeRequest.cockpit(deviceID: DeviceID(), features: [.workspaceControl, .remoteDirect])
    let responseData = try await transport.exchangeHandshake(HandshakeCodec.encode(request))
    let response = try HandshakeCodec.decodeResponse(responseData)

    #expect(response.serviceKind == "host")
    #expect(response.acceptedFeatures == ["remote-direct", "workspace-control"])
    await transport.disconnect()
}

@Test func remoteTransportRejectsPortZero() {
    #expect(throws: RemoteTransportError.invalidPort(0)) {
        _ = try RemoteDirectTransport(
            host: "127.0.0.1",
            port: 0,
            pinnedCertificateDER: Data()
        )
    }
}

private final class RemoteHandshakeLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cockpit.tests.remote-listener")

    var port: NWEndpoint.Port? { listener.port }

    init(identity: SecIdentity) throws {
        let parameters = NWParameters(tls: try TLSOptionsFactory.server(identity: identity))
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handle(connection) }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) async {
        let stream = NWConnectionByteStream(connection: connection)
        do {
            try await stream.start()
            let requestData = try await stream.receiveLengthPrefixed()
            let request = try HandshakeCodec.decodeRequest(requestData)
            let response = try HostHandshakeHandler().handle(request)
            try await stream.sendLengthPrefixed(HandshakeCodec.encode(response))
            await stream.cancel()
        } catch {
            await stream.cancel()
        }
    }
}
```

- [ ] **Step 4: Run the TLS test and verify failure**

Run:

```bash
COCKPIT_TLS_FIXTURE_DIR="$PWD/Tests/Fixtures/TLS/generated" swift test --filter CockpitRemoteTransportTests.remoteTransportNegotiatesOverTLS13
```

Expected: compilation fails because TLSFixture and remote transport types do not exist.

- [ ] **Step 5: Implement TLS fixture loading and pinned trust**

Create `Tests/CockpitRemoteTransportTests/TLSFixture.swift`:

```swift
import Foundation
import Security

enum TLSFixtureError: Error {
    case missingDirectory
    case importFailed(OSStatus)
    case missingIdentity
    case missingCertificate
}

struct TLSFixture {
    let identity: SecIdentity
    let certificate: SecCertificate

    static func load() throws -> Self {
        guard let directory = ProcessInfo.processInfo.environment["COCKPIT_TLS_FIXTURE_DIR"] else {
            throw TLSFixtureError.missingDirectory
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("identity.p12"))
        let options = [kSecImportExportPassphrase as String: "cockpit-test"] as CFDictionary
        var imported: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &imported)
        guard status == errSecSuccess else { throw TLSFixtureError.importFailed(status) }
        guard
            let item = (imported as? [[String: Any]])?.first,
            let identity = item[kSecImportItemIdentity as String] as? SecIdentity
        else {
            throw TLSFixtureError.missingIdentity
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw TLSFixtureError.missingCertificate
        }
        return Self(identity: identity, certificate: certificate)
    }
}
```

Create `Sources/CockpitRemoteTransport/TLSOptionsFactory.swift`:

```swift
import Foundation
import Network
import Security

public enum TLSOptionsError: Error {
    case identityConversionFailed
}

public enum TLSOptionsFactory {
    public static func server(identity: SecIdentity) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        guard let converted = sec_identity_create(identity) else {
            throw TLSOptionsError.identityConversionFailed
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, converted)
        return options
    }

    public static func client(pinnedCertificateDER: Data) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        let queue = DispatchQueue(label: "dev.cockpit.remote.tls-verify")

        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard
                let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                let leaf = chain.first
            else {
                complete(false)
                return
            }
            complete((SecCertificateCopyData(leaf) as Data) == pinnedCertificateDER)
        }, queue)
        return options
    }
}
```

- [ ] **Step 6: Implement the Network.framework byte stream and transport**

Create `Sources/CockpitRemoteTransport/NWConnectionByteStream.swift`:

```swift
import Foundation
import Network

public enum NetworkByteStreamError: Error, Equatable {
    case closed
    case invalidLength(UInt32)
}

public actor NWConnectionByteStream {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.cockpit.remote.connection")

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    connection?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection?.stateUpdateHandler = nil
                    continuation.resume(throwing: NetworkByteStreamError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func sendLengthPrefixed(_ data: Data) async throws {
        guard data.count <= Int(UInt32.max) else {
            throw NetworkByteStreamError.invalidLength(UInt32.max)
        }
        var length = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(data)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    public func receiveLengthPrefixed(maximumLength: Int = 16 * 1_024 * 1_024) async throws -> Data {
        let lengthData = try await receiveExactly(4)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumLength) else { throw NetworkByteStreamError.invalidLength(length) }
        return try await receiveExactly(Int(length))
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if complete {
                        continuation.resume(throwing: NetworkByteStreamError.closed)
                    } else {
                        continuation.resume(throwing: NetworkByteStreamError.closed)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }
}
```

Create `Sources/CockpitRemoteTransport/RemoteDirectTransport.swift`:

```swift
import Foundation
import Network
import Security
import CockpitClientCore

public enum RemoteTransportError: Error, Equatable {
    case notConnected
    case invalidPort(UInt16)
}

public actor RemoteDirectTransport: CockpitTransport {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let pinnedCertificateDER: Data
    private var stream: NWConnectionByteStream?

    public init(host: String, port: UInt16, pinnedCertificateDER: Data) throws {
        guard port != 0, let resolvedPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteTransportError.invalidPort(port)
        }
        self.host = NWEndpoint.Host(host)
        self.port = resolvedPort
        self.pinnedCertificateDER = pinnedCertificateDER
    }

    public func connect() async throws {
        let parameters = NWParameters(tls: TLSOptionsFactory.client(pinnedCertificateDER: pinnedCertificateDER))
        let stream = NWConnectionByteStream(connection: NWConnection(host: host, port: port, using: parameters))
        try await stream.start()
        self.stream = stream
    }

    public func exchangeHandshake(_ request: Data) async throws -> Data {
        guard let stream else { throw RemoteTransportError.notConnected }
        try await stream.sendLengthPrefixed(request)
        return try await stream.receiveLengthPrefixed()
    }

    public func disconnect() async {
        await stream?.cancel()
        stream = nil
    }
}
```

- [ ] **Step 7: Run the complete TLS loopback test**

Run:

```bash
COCKPIT_TLS_FIXTURE_DIR="$PWD/Tests/Fixtures/TLS/generated" swift test --filter CockpitRemoteTransportTests
```

Expected: the TLS 1.3 pinned-certificate handshake test passes.

- [ ] **Step 8: Add the deterministic remote test wrapper**

Create `Tools/test-remote-tls.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
"$repo_root/Tests/Fixtures/TLS/generate.zsh"
cd "$repo_root"
COCKPIT_TLS_FIXTURE_DIR="$repo_root/Tests/Fixtures/TLS/generated" swift test --filter CockpitRemoteTransportTests
```

Run `chmod +x Tools/test-remote-tls.zsh` and then:

```bash
Tools/test-remote-tls.zsh
```

Expected: all remote transport tests pass.

- [ ] **Step 9: Commit remote transport conformance**

```bash
git add Package.swift Sources/CockpitRemoteTransport Tests/CockpitRemoteTransportTests Tests/Fixtures/TLS/generate.zsh Tools/test-remote-tls.zsh
git commit -m "feat: prove remote tls transport handshake"
```

---

### Task 9: Pin and build the isolated Monaco runtime

**Files:**
- Create: `EditorRuntime/package.json`
- Create: `EditorRuntime/build.mjs`
- Create: `EditorRuntime/src/index.html`
- Create: `EditorRuntime/src/bootstrap.ts`
- Create: `EditorRuntime/test/build.test.mjs`

**Interfaces:**
- Consumes: Node 26.7.0 and pnpm 11.20.0.
- Produces: `EditorRuntime/dist/MonacoRuntime.bundle/index.html` and `editor.js`; no application networking or web UI modules.

- [ ] **Step 1: Write the package manifest and failing build test**

Create `EditorRuntime/package.json`:

```json
{
  "name": "cockpit-editor-runtime",
  "private": true,
  "version": "0.0.1",
  "packageManager": "pnpm@11.20.0",
  "type": "module",
  "scripts": {
    "build": "node build.mjs",
    "test": "node --test test/*.test.mjs"
  },
  "dependencies": {
    "monaco-editor": "0.56.0"
  },
  "devDependencies": {
    "esbuild": "0.28.1"
  }
}
```

Create `EditorRuntime/test/build.test.mjs`:

```javascript
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('build emits a self-contained local editor bundle', async () => {
  const html = await readFile(new URL('../dist/MonacoRuntime.bundle/index.html', import.meta.url), 'utf8');
  const js = await readFile(new URL('../dist/MonacoRuntime.bundle/editor.js', import.meta.url), 'utf8');
  const css = await readFile(new URL('../dist/MonacoRuntime.bundle/editor.css', import.meta.url), 'utf8');
  const source = await readFile(new URL('../src/bootstrap.ts', import.meta.url), 'utf8');
  assert.match(html, /editor\.js/);
  assert.match(html, /editor\.css/);
  assert.match(js, /cockpitEditorProtocol/);
  assert.ok(css.length > 0);
  assert.doesNotMatch(html, /(?:src|href)=["']https?:/);
  assert.doesNotMatch(source, /\bfetch\s*\(|\bWebSocket\s*\(/);
});
```

- [ ] **Step 2: Install dependencies and verify test failure**

Run:

```bash
test "$(pnpm --version)" = "11.20.0"
pnpm --dir EditorRuntime install --frozen-lockfile=false
pnpm --dir EditorRuntime test
```

Expected: test fails with ENOENT for `dist/MonacoRuntime.bundle/index.html`.

- [ ] **Step 3: Implement the minimal Monaco bootstrap**

Create `EditorRuntime/src/index.html`:

```html
<!doctype html>
<html><head><meta charset="utf-8"><meta name="color-scheme" content="dark light"><link rel="stylesheet" href="./editor.css"></head>
<body><div id="editor"></div><script type="module" src="./editor.js"></script></body></html>
```

Create `EditorRuntime/src/bootstrap.ts`:

```typescript
import * as monaco from 'monaco-editor/editor/editor.api';
import 'monaco-editor/editor/contrib/find/browser/findController';

declare global {
  interface Window {
    cockpitEditorProtocol: {
      version: 1;
      openText(uri: string, text: string, language: string): void;
    };
  }
}

const root = document.getElementById('editor');
if (!(root instanceof HTMLElement)) throw new Error('missing editor root');
Object.assign(document.body.style, { margin: '0', overflow: 'hidden' });
Object.assign(root.style, { position: 'fixed', inset: '0' });

const editor = monaco.editor.create(root, {
  value: '',
  language: 'plaintext',
  automaticLayout: true,
  minimap: { enabled: false },
});

window.cockpitEditorProtocol = {
  version: 1,
  openText(uri, text, language) {
    const modelURI = monaco.Uri.parse(uri);
    const model = monaco.editor.getModel(modelURI) ?? monaco.editor.createModel(text, language, modelURI);
    if (model.getValue() !== text) model.setValue(text);
    editor.setModel(model);
  },
};
```

- [ ] **Step 4: Implement deterministic bundling**

Create `EditorRuntime/build.mjs`:

```javascript
import { build } from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';

const output = new URL('./dist/MonacoRuntime.bundle/', import.meta.url);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(new URL('./src/index.html', import.meta.url), new URL('./index.html', output));
await build({
  entryPoints: [new URL('./src/bootstrap.ts', import.meta.url).pathname],
  outfile: new URL('./editor.js', output).pathname,
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: 'safari18',
  minify: true,
  sourcemap: true,
  logLevel: 'info',
});
```

- [ ] **Step 5: Build and test the editor runtime**

Run:

```bash
pnpm --dir EditorRuntime build
pnpm --dir EditorRuntime test
```

Expected: esbuild emits `editor.js`; the Node test passes; no output contains an HTTP URL.

- [ ] **Step 6: Commit Monaco source and lockfile**

```bash
git add EditorRuntime/package.json EditorRuntime/pnpm-lock.yaml EditorRuntime/build.mjs EditorRuntime/src EditorRuntime/test
git commit -m "build: pin isolated monaco runtime"
```

---

### Task 10: Pin Ghostty and provision the required Zig toolchain

**Files:**
- Create: `.gitmodules`
- Create: `ThirdParty/ghostty/` as a submodule
- Create: `Config/Toolchains/ghostty.env`
- Create: `Tools/bootstrap-zig.zsh`
- Create: `Tools/verify-ghostty.zsh`
- Create: `Tests/ToolingTests/ghostty-toolchain.zsh`

**Interfaces:**
- Consumes: official Ghostty v1.3.1 source and the official Zig 0.15.2 macOS arm64 archive.
- Produces: an exact Ghostty source pin and a repository-local `.tools/zig/0.15.2/zig` compiler verified by SHA-256.

- [ ] **Step 1: Write the failing toolchain verification test**

Create `Tests/ToolingTests/ghostty-toolchain.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h:h}
source "$repo_root/Config/Toolchains/ghostty.env"
[[ "$(git -C "$repo_root/ThirdParty/ghostty" rev-parse HEAD)" == "$GHOSTTY_COMMIT" ]]
[[ "$("$repo_root/.tools/zig/$ZIG_VERSION/zig" version)" == "$ZIG_VERSION" ]]
```

Run:

```bash
chmod +x Tests/ToolingTests/ghostty-toolchain.zsh
Tests/ToolingTests/ghostty-toolchain.zsh
```

Expected: fails because the manifest, submodule, and Zig binary do not exist.

- [ ] **Step 2: Add and pin the Ghostty submodule**

Run:

```bash
git submodule add https://github.com/ghostty-org/ghostty.git ThirdParty/ghostty
git -C ThirdParty/ghostty checkout 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
```

Expected: `git -C ThirdParty/ghostty rev-parse HEAD` prints the exact pinned commit.

- [ ] **Step 3: Record the source and compiler manifest**

Create `Config/Toolchains/ghostty.env`:

```zsh
GHOSTTY_VERSION=1.3.1
GHOSTTY_COMMIT=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
ZIG_VERSION=0.15.2
ZIG_AARCH64_MACOS_URL=https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz
ZIG_AARCH64_MACOS_SHA256=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b
```

- [ ] **Step 4: Implement the repository-local Zig bootstrap**

Create `Tools/bootstrap-zig.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
source "$repo_root/Config/Toolchains/ghostty.env"
[[ "$(uname -m)" == arm64 ]] || { print -u2 "Phase 0 Zig bootstrap supports arm64 macOS only"; exit 1; }

install_root="$repo_root/.tools/zig/$ZIG_VERSION"
[[ -x "$install_root/zig" ]] && exit 0

temp_dir=$(mktemp -d /tmp/cockpit-zig.XXXXXX)
trap 'rm -rf "$temp_dir"' EXIT
archive="$temp_dir/zig.tar.xz"
curl -fL "$ZIG_AARCH64_MACOS_URL" -o "$archive"
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
[[ "$actual" == "$ZIG_AARCH64_MACOS_SHA256" ]] || { print -u2 "Zig SHA-256 mismatch"; exit 1; }
tar -xf "$archive" -C "$temp_dir"
mkdir -p "${install_root:h}"
mv "$temp_dir/zig-aarch64-macos-$ZIG_VERSION" "$install_root"
[[ "$("$install_root/zig" version)" == "$ZIG_VERSION" ]]
```

Run `chmod +x Tools/bootstrap-zig.zsh`.

- [ ] **Step 5: Implement and run Ghostty verification**

Create `Tools/verify-ghostty.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
source "$repo_root/Config/Toolchains/ghostty.env"
"$repo_root/Tools/bootstrap-zig.zsh"
actual_commit=$(git -C "$repo_root/ThirdParty/ghostty" rev-parse HEAD)
[[ "$actual_commit" == "$GHOSTTY_COMMIT" ]] || { print -u2 "Ghostty commit mismatch: $actual_commit"; exit 1; }
[[ "$("$repo_root/.tools/zig/$ZIG_VERSION/zig" version)" == "$ZIG_VERSION" ]]
```

Run:

```bash
chmod +x Tools/verify-ghostty.zsh
Tools/verify-ghostty.zsh
Tests/ToolingTests/ghostty-toolchain.zsh
```

Expected: both scripts exit 0 and report no commit or compiler mismatch.

- [ ] **Step 6: Commit the Ghostty build inputs**

```bash
git add .gitmodules ThirdParty/ghostty Config/Toolchains Tools/bootstrap-zig.zsh Tools/verify-ghostty.zsh Tests/ToolingTests
git commit -m "build: pin ghostty and zig toolchain"
```

---

### Task 11: Add one Phase 0 verification command and document the handoff

**Files:**
- Create: `Tools/verify-phase0.zsh`
- Create: `README.md`

**Interfaces:**
- Consumes: every Phase 0 build and test command.
- Produces: one deterministic verification entrypoint and concise contributor instructions.

- [ ] **Step 1: Write the aggregate verification script**

Create `Tools/verify-phase0.zsh`:

```zsh
#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
cd "$repo_root"

cockpit_xcode_version=$(xcodebuild -version)
[[ "$cockpit_xcode_version" == $'Xcode 26.6\nBuild version 17F113' ]]
[[ "$(swift --version)" == *"Swift version 6.3.3"* ]]
[[ "$(node --version)" == "v26.7.0" ]]
[[ "$(pnpm --version)" == "11.20.0" ]]
[[ "$(xcodegen --version)" == "Version: 2.46.0" ]]

swift build
swift test
pnpm --dir EditorRuntime install --frozen-lockfile
[[ "$(node -p "require('./EditorRuntime/node_modules/monaco-editor/package.json').version")" == "0.56.0" ]]
[[ "$(pnpm --dir EditorRuntime exec esbuild --version)" == "0.28.1" ]]
/usr/bin/grep -Eq '"version"[[:space:]]*:[[:space:]]*"1\.38\.1"' Package.resolved
pnpm --dir EditorRuntime build
pnpm --dir EditorRuntime test
Tools/verify-ghostty.zsh
Tools/test-remote-tls.zsh
Tests/ProcessIntegrationTests/service-keeper-foundation.zsh
xcodegen generate
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData CONFIGURATION_BUILD_DIR="$repo_root/build/Debug" build
Tests/ProcessIntegrationTests/app-bundle-layout.zsh
git diff --check
```

Run `chmod +x Tools/verify-phase0.zsh`.

- [ ] **Step 2: Document exact bootstrap and verification commands**

Create `README.md`:

```markdown
# Cockpit

Cockpit is a native macOS agent development environment. The Mac owns projects, worktrees, files, Git, language servers, and terminal processes; Apple-platform clients consume the same versioned protocol locally or remotely.

## Phase 0 prerequisites

- macOS on Apple Silicon
- Xcode 26.6 (17F113)
- Swift 6.3.3
- Node 26.7.0
- pnpm 11.20.0
- XcodeGen 2.46.0

Zig 0.15.2 is installed repository-locally by `Tools/bootstrap-zig.zsh`.

## Verify

```bash
Tools/verify-phase0.zsh
```

Architecture: `docs/design/2026-08-05-cockpit-architecture.md`
Terminal resilience specification: `docs/superpowers/specs/2026-08-05-terminal-session-resilience-design.md`
Implementation plan: `docs/superpowers/plans/2026-08-05-cockpit-phase-0-implementation.md`
```

- [ ] **Step 3: Run the complete Phase 0 gate**

Run:

```bash
Tools/verify-phase0.zsh
```

Expected results:

- `swift build` succeeds.
- Every Swift test target passes.
- Monaco build and Node test pass.
- Ghostty commit and Zig SHA/version checks pass.
- TLS 1.3 loopback test passes.
- Host and TerminalSupervisor both report protocol 1.0 through separate XPC processes.
- The detached Keeper probe remains alive after a forced TerminalSupervisor crash.
- launchd starts a new TerminalSupervisor and restores its XPC control endpoint.
- Xcode prints `** BUILD SUCCEEDED **`.
- The app bundle layout and ad-hoc signature test passes.
- `git diff --check` exits 0.

- [ ] **Step 4: Re-run the architecture dependency audit**

Run:

```bash
! /usr/bin/grep -ERn 'import (AppKit|WebKit|Network|Security)' Sources/CockpitClientCore
! /usr/bin/grep -ERn 'import (Network|Security)' Sources/CockpitHostCore
! /usr/bin/grep -ERn '(^|[^[:alnum:]_])(fetch|WebSocket)[[:space:]]*\(' EditorRuntime/src
```

Expected: every command exits 0 because no forbidden import or URL exists.

- [ ] **Step 5: Commit the Phase 0 verification gate**

```bash
git add README.md Tools/verify-phase0.zsh
git commit -m "docs: finalize cockpit phase zero foundation"
```

---

## Phase 0 Completion Evidence

The implementation is complete only when the following evidence is captured in the final handoff:

1. `git status --short` contains no unintended files.
2. `git log --oneline --max-count=10` shows one reviewable commit per task.
3. `Tools/verify-phase0.zsh` exits 0 in one uninterrupted run.
4. The exact Xcode, Swift, Node, pnpm, XcodeGen, Zig, Ghostty, Monaco, esbuild, and SwiftProtobuf versions are listed.
5. The local process test shows Host and TerminalSupervisor negotiate protocol 1.0 through separate Mach services.
6. The same test proves Keeper PID equals its process-group ID, survives a forced Supervisor crash, and remains alive after launchd starts the replacement Supervisor.
7. The remote loopback test proves TLS 1.3 and pinned-certificate verification.
8. `Cockpit.app` contains CockpitHost, CockpitTerminalSupervisor, CockpitPTYKeeper, and both LaunchAgent plists at the documented bundle paths.
9. No Phase 1 Project, Conversation, editor persistence, real PTY, attach ticket, file-tree, Git, or LSP behavior is claimed as implemented.
