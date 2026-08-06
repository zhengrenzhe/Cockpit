import Foundation
import Testing
@testable import CockpitTypes

private func terminalUUID(_ suffix: Int) throws -> UUID {
    try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)))
}

@Test func terminalKeyValuesAndValidationAreFrozen() throws {
    #expect(TerminalKeyAction.press.rawValue == 1)
    #expect(TerminalKeyAction.repeat.rawValue == 2)
    #expect(TerminalKeyAction.release.rawValue == 3)
    #expect(try TerminalKeyEvent(validatingLogicalKey: 0x41, physicalKey: 0x04, modifiers: 0x3FF, action: .press).logicalKey == 0x41)
    #expect(throws: CockpitDomainValidationError.invalidTerminalKeyIdentity) {
        _ = try TerminalKeyEvent(validatingLogicalKey: 0, physicalKey: 0, modifiers: 0, action: .press)
    }
    for scalar: UInt32 in [0xD800, 0x10FFFF + 1] {
        #expect(throws: CockpitDomainValidationError.invalidTerminalLogicalKey) {
            _ = try TerminalKeyEvent(validatingLogicalKey: scalar, physicalKey: 1, modifiers: 0, action: .press)
        }
    }
    #expect(throws: CockpitDomainValidationError.invalidTerminalModifiers) {
        _ = try TerminalKeyEvent(validatingLogicalKey: 1, physicalKey: 1, modifiers: 1 << 10, action: .press)
    }
}

@Test func terminalMouseValuesAndWheelRulesAreFrozen() throws {
    #expect([
        TerminalMouseAction.press.rawValue,
        TerminalMouseAction.release.rawValue,
        TerminalMouseAction.motion.rawValue,
        TerminalMouseAction.scroll.rawValue,
    ] == [1, 2, 3, 4])
    let scroll = try TerminalMouseEvent(
        validatingCellX: -1, cellY: 2, buttons: 0x7FF, wheelX: 65_536,
        wheelY: 0, modifiers: 0, action: .scroll
    )
    #expect(scroll.cellX == -1)
    #expect(throws: CockpitDomainValidationError.invalidTerminalMouseButtons) {
        _ = try TerminalMouseEvent(validatingCellX: 0, cellY: 0, buttons: 1 << 11, wheelX: 0, wheelY: 0, modifiers: 0, action: .motion)
    }
    #expect(throws: CockpitDomainValidationError.invalidTerminalMouseWheel) {
        _ = try TerminalMouseEvent(validatingCellX: 0, cellY: 0, buttons: 0, wheelX: 1, wheelY: 0, modifiers: 0, action: .motion)
    }
    #expect(throws: CockpitDomainValidationError.invalidTerminalMouseWheel) {
        _ = try TerminalMouseEvent(validatingCellX: 0, cellY: 0, buttons: 0, wheelX: 0, wheelY: 0, modifiers: 0, action: .scroll)
    }
}

@Test func terminalResizeAndSignalValuesAreFrozen() throws {
    #expect(try TerminalResize(validatingColumns: 65_535, rows: 1).columns == 65_535)
    for value in [UInt32(0), 65_536] {
        #expect(throws: CockpitDomainValidationError.invalidTerminalResize) {
            _ = try TerminalResize(validatingColumns: value, rows: 1)
        }
    }
    #expect([
        TerminalSignal.interrupt.rawValue,
        TerminalSignal.quit.rawValue,
        TerminalSignal.suspend.rawValue,
        TerminalSignal.continue.rawValue,
    ] == [1, 2, 3, 4])
}

@Test func terminalInputValidatesSequenceAndTextPasteByteBoundaries() throws {
    let context = try makeTerminalRequestContext()
    let terminalID = TerminalSessionID(try terminalUUID(20))
    let leaseID = InputLeaseID(try terminalUUID(21))
    #expect(throws: CockpitDomainValidationError.zeroInputSequence) {
        _ = try TerminalInput(validatingContext: context, terminalSessionID: terminalID, inputLeaseID: leaseID, inputSequence: 0, payload: .text("x"))
    }
    #expect(throws: CockpitDomainValidationError.emptyTerminalText) {
        _ = try TerminalInput(validatingContext: context, terminalSessionID: terminalID, inputLeaseID: leaseID, inputSequence: 1, payload: .text(""))
    }
    #expect(throws: CockpitDomainValidationError.emptyTerminalPaste) {
        _ = try TerminalInput(validatingContext: context, terminalSessionID: terminalID, inputLeaseID: leaseID, inputSequence: 1, payload: .paste(""))
    }
    let exact = String(repeating: "a", count: TerminalInput.maximumTextOrPasteUTF8Bytes)
    #expect(try TerminalInput(validatingContext: context, terminalSessionID: terminalID, inputLeaseID: leaseID, inputSequence: 1, payload: .text(exact)).inputSequence == 1)
    #expect(throws: CockpitDomainValidationError.terminalTextOrPasteTooLarge) {
        _ = try TerminalInput(validatingContext: context, terminalSessionID: terminalID, inputLeaseID: leaseID, inputSequence: 1, payload: .paste(exact + "b"))
    }
}

@Test func archiveValuesValidateHashExitStatusNamesAndRanges() throws {
    #expect(throws: CockpitDomainValidationError.invalidSHA256DigestLength) {
        _ = try SHA256Digest(validating: Data(repeating: 0, count: 31))
    }
    let digest = try SHA256Digest(validating: Data(repeating: 0xAB, count: 32))
    #expect(digest.bytes.count == 32)
    #expect(throws: CockpitDomainValidationError.invalidTerminalExitStatus) {
        _ = try TerminalExitStatus.signaled(0).validated()
    }
    #expect(try TerminalExitStatus.signaled(31).validated() == .signaled(31))
    #expect(throws: CockpitDomainValidationError.invalidTerminalArchiveChunkName) {
        _ = try TerminalArchiveChunk(validatingName: "../1.ckgs", firstOutputSequence: 1, lastOutputSequence: 1, sha256: digest)
    }
    #expect(throws: CockpitDomainValidationError.invalidTerminalArchiveChunkRange) {
        _ = try TerminalArchiveChunk(validatingName: "00000000000000000002.ckgs", firstOutputSequence: 2, lastOutputSequence: 1, sha256: digest)
    }

    let chunk1 = try TerminalArchiveChunk(validatingName: "00000000000000000001.ckgs", firstOutputSequence: 1, lastOutputSequence: 10, sha256: digest)
    let chunk2 = try TerminalArchiveChunk(validatingName: "00000000000000000021.ckgs", firstOutputSequence: 21, lastOutputSequence: 25, sha256: digest)
    let manifest = try TerminalArchiveManifest(
        validatingTerminalSessionID: TerminalSessionID(try terminalUUID(30)),
        workerInstanceID: WorkerInstanceID(try terminalUUID(31)), firstOutputSequence: 1,
        latestOutputSequence: 30, chunks: [chunk1, chunk2], finalSnapshotSHA256: digest,
        exitStatus: .exited(0), completedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(manifest.chunks.count == 2)
    #expect(throws: CockpitDomainValidationError.invalidTerminalArchiveChunks) {
        _ = try TerminalArchiveManifest(
            validatingTerminalSessionID: manifest.terminalSessionID, workerInstanceID: manifest.workerInstanceID,
            firstOutputSequence: 1, latestOutputSequence: 30, chunks: [chunk1, chunk1],
            finalSnapshotSHA256: digest, exitStatus: .exited(0), completedAt: manifest.completedAt
        )
    }
    #expect(throws: CockpitDomainValidationError.invalidTerminalArchiveChunks) {
        _ = try TerminalArchiveManifest(
            validatingTerminalSessionID: manifest.terminalSessionID,
            workerInstanceID: manifest.workerInstanceID, firstOutputSequence: 0,
            latestOutputSequence: 0, chunks: [chunk1], finalSnapshotSHA256: digest,
            exitStatus: .exited(0), completedAt: manifest.completedAt
        )
    }
    #expect(throws: CockpitDomainValidationError.invalidTerminalArchiveCompletionDate) {
        _ = try TerminalArchiveManifest(
            validatingTerminalSessionID: manifest.terminalSessionID,
            workerInstanceID: manifest.workerInstanceID, firstOutputSequence: 0,
            latestOutputSequence: 0, chunks: [], finalSnapshotSHA256: digest,
            exitStatus: .exited(0),
            completedAt: Date(timeIntervalSince1970: 253_402_300_800)
        )
    }
}

private func makeTerminalRequestContext() throws -> RequestContext {
    try RequestContext(
        validating: .init(major: 1, minor: 1), clientInstanceID: ClientInstanceID(try terminalUUID(1)),
        windowID: WindowID(try terminalUUID(2)), workspaceContextID: .project(ProjectID(try terminalUUID(3))),
        environmentID: EnvironmentID(try terminalUUID(4)), activeContextGeneration: 17,
        requestID: RequestID(try terminalUUID(5))
    )
}
