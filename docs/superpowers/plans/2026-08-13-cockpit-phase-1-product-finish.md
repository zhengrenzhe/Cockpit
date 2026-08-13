# Cockpit Phase 1 Product Finish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the seven approved Phase 1 product-finish requirements: recover persisted Monaco tabs, make terminal tabs interactive with fixed 13pt cells, ship the approved native three-column workbench/Welcome experience, and preserve window geometry.

**Architecture:** Keep the existing AppKit controller tree and existing Host/Terminal protocols. Restore file sessions in `TabCommandController` before Monaco selection, normalize AppKit terminal events in `GhosttyTerminalView` and serialize them through `TerminalTabViewController`, and make the Ghostty renderer return a fixed-font grid. Build the Welcome and column chrome as small AppKit controllers/views without adding Host wire fields, XPC methods, database migrations, or third-party UI dependencies.

**Tech Stack:** Swift 6.3, AppKit, XCTest, Swift Testing, CockpitTerminalClient/Core, C ABI, patched Ghostty Zig/Objective-C renderer, XcodeGen, Monaco TypeScript runtime.

## Global Constraints

- Implement only the seven requirements in `Docs/superpowers/specs/2026-08-13-cockpit-phase-1-product-finish-design.md`; do not add Phase 2 features.
- Keep pure AppKit. Do not migrate the window or workspace controllers to SwiftUI.
- Keep exactly one titlebar-integrated three-column layout: 48pt independent headers and 24pt independent footers; the center tab strip must not cross the right Files column.
- Window default content size is exactly 1440x900; minimum content size is exactly 960x640; autosave key remains `Cockpit.WorkspaceWindow`.
- Terminal font is exactly system monospaced 13pt; resize changes PTY rows/columns and never stretches glyphs.
- Reuse existing `TerminalInput`, document snapshot, viewer retention, edit lease, and client workspace state contracts. Add no Host wire field, XPC method, or database migration.
- Welcome never auto-opens `NSOpenPanel`; only the explicit `Open Project…` action invokes `ProjectCommandController.appKitDirectoryPicker()`.
- Use semantic AppKit colors/materials, SF Symbols, and system fonts. Add no UI package, SVG theme, or hard-coded full palette.
- Every behavior change follows RED -> GREEN -> focused regression tests before the next task.
- Do not accept historic gate output. Completion requires a fresh `Tools/verify-phase1.zsh` exit 0 with final line `Phase 1 unified gate: PASS`.

---

## File Map

- `Sources/CockpitClientCore/DocumentClientController.swift`: reconstruct an existing document session from a persisted `DocumentID` snapshot.
- `Sources/CockpitTerminalClient/TerminalAttachmentController.swift`: accept a payload plus validated request context and construct the lease-bound, sequenced `TerminalInput` internally.
- `Applications/CockpitApp/TabCommandController.swift`: idempotently restore a persisted file reference and select it through Monaco.
- `Applications/CockpitApp/WorkspaceViewModel.swift`: route all file-tab selection through the restore-aware command boundary and remove stale file records only for an explicit missing-document error.
- `Applications/CockpitApp/Terminal/GhosttyTerminalView.swift`: become first responder/NSTextInputClient, normalize keyboard/IME/paste, and publish fixed-grid resize changes.
- `Applications/CockpitApp/Terminal/TerminalTabViewController.swift`: serialize terminal payloads, construct request contexts, de-duplicate resize, and show one inline input error.
- `Native/CockpitGhosttyBridge/include/cockpit_ghostty.h`: expose fixed-cell layout results from renderer resize.
- `Patches/ghostty/0001-cockpit-external-vt-renderer.patch`: render with cached 13pt monospaced cell metrics instead of viewport-derived font size.
- `Applications/CockpitApp/WorkspaceChromeView.swift`: reusable semantic 48pt header/24pt footer primitives and draggable background view.
- `Applications/CockpitApp/WelcomeViewController.swift`: zero-project Welcome and explicit Open Project action.
- `Applications/CockpitApp/WorkspaceWindowController.swift`: full-size integrated titlebar and validated frame autosave/default geometry.
- `Applications/CockpitApp/WorkspaceSplitViewController.swift`: switch center content and side states between Welcome and active workspace.
- `Applications/CockpitApp/WorkspaceSidebarController.swift`, `TabStripController.swift`, `FileTreeViewController.swift`: own independent column chrome.
- Existing focused test files under `Tests/CockpitClientCoreTests`, `Tests/CockpitTerminalClientTests`, and `Tests/CockpitAppTests`: real behavior regressions.
- `Tests/ToolingTests/ghostty-bridge.zsh`: compile/run the renderer ABI harness and prove fixed cell size across viewport changes.

---

### Task 1: Restore persisted Monaco file tabs before selection

**Files:**
- Modify: `Sources/CockpitClientCore/DocumentClientController.swift`
- Test: `Tests/CockpitClientCoreTests/DocumentClientControllerTests.swift`
- Modify: `Applications/CockpitApp/TabCommandController.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Test: `Tests/CockpitAppTests/TabCommandControllerTests.swift`
- Test: `Tests/CockpitAppTests/WorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: `DocumentClientController.restore(documentID:in:requestWriteAccess:) async throws -> DocumentSnapshot`.
- Produces: `TabCommanding.selectFileTab(_ tab: WorkspaceTab, in active: ActiveContext) async throws`.
- Consumes: existing `DocumentDataTransport.snapshot`, `retainViewer`, `acquireEditLease`, `MonacoWindowSessionResolver.retain`, and `MonacoBridge.select`.

- [ ] **Step 1: Write a failing controller restore test**

Add a test that starts with a closed controller, configures the real test transport with a literal snapshot, calls the wished-for restore API, and asserts `.ready`, the exact `DocumentID`, environment, path, and acquired lease. The production mutation it catches is deleting the snapshot-based restore path and reverting to path-based open.

```swift
func testRestoreExistingDocumentUsesSnapshotAndRebuildsWritableState() async throws {
    let transport = RecordingDocumentTransport(snapshot: literalSnapshot)
    let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)

    let restored = try await controller.restore(
        documentID: literalSnapshot.documentID,
        in: literalSnapshot.environmentID,
        requestWriteAccess: true
    )

    XCTAssertEqual(restored.documentID, literalSnapshot.documentID)
    XCTAssertEqual(transport.snapshotRequests, [literalSnapshot.documentID])
    XCTAssertEqual(transport.openRequests, [])
    XCTAssertEqual(await controller.state, .ready(snapshotWithLiteralLease))
}
```

- [ ] **Step 2: Run the exact client-core test and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update \
  --filter DocumentClientControllerTests/testRestoreExistingDocumentUsesSnapshotAndRebuildsWritableState
```

Expected: compile failure because `restore(documentID:in:requestWriteAccess:)` does not exist.

- [ ] **Step 3: Implement the minimal snapshot restore**

Inside the actor, acquire the existing control gate, fetch `transport.snapshot(documentID:)`, reject a mismatched `documentID` or `environmentID` with `DocumentProtocolError.invalidValue`, set `path/environmentID/authoritativeSnapshot`, then acquire an edit lease only when requested. Reuse `snapshotWithLease` and the same state transitions as `open`.

```swift
@discardableResult
public func restore(
    documentID: DocumentID,
    in environmentID: EnvironmentID,
    requestWriteAccess: Bool
) async throws -> DocumentSnapshot
```

- [ ] **Step 4: Run the exact client-core test and the complete controller suite GREEN**

Run the exact filter, then:

```bash
swift test --disable-automatic-resolution --skip-update \
  --filter DocumentClientControllerTests
```

- [ ] **Step 5: Write failing App tests for persisted file restoration and A/B/A cancellation**

Add `TabCommandControllerTests` with a persisted `WorkspaceTab(kind: .file(documentID))` that has no in-memory resolver session. Assert one snapshot fetch, one viewer retain, one resolver reference, and successful bridge selection. Add `WorkspaceViewModelTests` that rebuild state with a selected file tab and proves `selectContext` calls `selectFileTab`; a rapid A/B/A sequence must leave only the final A selected and earlier calls end with `CancellationError`. The production mutation these tests catch is directly calling `MonacoBridge.select` before restoration.

```swift
try await commands.selectFileTab(persistedTab, in: fixture.project)
XCTAssertEqual(document.snapshotRequests, [documentID])
XCTAssertEqual(bridge.selectedReferences, [
    .init(contextID: fixture.project.contextID, tabID: tabID, documentID: documentID),
])
```

- [ ] **Step 6: Run the App tests and verify RED**

Run:

```bash
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/TabCommandControllerTests \
  -only-testing:CockpitAppTests/WorkspaceViewModelTests test
```

Expected: compile failure because `selectFileTab` is absent, followed by behavior failures once the test double is updated.

- [ ] **Step 7: Implement idempotent restore-aware selection**

Add `selectFileTab` to `TabCommanding`. Under the existing file lifecycle gate:

1. If the exact resolver reference already exists and the controller/environment match, call `bridge.select` only.
2. Otherwise construct a transport/controller, call `restore`, derive language from the snapshot path using the same path-to-language helper used by file open, retain the viewer, retain the resolver reference, register the viewer/controller caches, and call `bridge.select`.
3. On failure, release only resources acquired by that attempt.
4. In `WorkspaceViewModel.selectContext` and `selectTab`, replace raw `fileSelection` with `tabCommands.selectFileTab` when command dependencies exist; keep injected `fileSelection` only for existing isolated tests without command dependencies.
5. Check the selection request generation after each await so stale A/B/A work throws `CancellationError` before publishing state.

- [ ] **Step 8: Add explicit stale-document cleanup and readable state test**

Use the concrete `DocumentProtocolError.fileMissing` already returned by the data transport. Only that error removes the persisted tab through existing state mutation and throws a new localized `WorkspaceViewModelError.fileMissing(path:)` whose description is `The file no longer exists in this project.`; all validation/data corruption errors still throw. Test both branches.

- [ ] **Step 9: Run focused App tests GREEN and commit**

Run the two suites from Step 6 and `MonacoBridgeTests`, then:

```bash
git add Sources/CockpitClientCore/DocumentClientController.swift \
  Tests/CockpitClientCoreTests/DocumentClientControllerTests.swift \
  Applications/CockpitApp/TabCommandController.swift \
  Applications/CockpitApp/WorkspaceViewModel.swift \
  Tests/CockpitAppTests/TabCommandControllerTests.swift \
  Tests/CockpitAppTests/WorkspaceViewModelTests.swift
git commit -m "fix: restore persisted editor tabs"
```

---

### Task 2: Make terminal views accept real AppKit input in order

**Files:**
- Modify: `Sources/CockpitTerminalClient/TerminalAttachmentController.swift`
- Test: `Tests/CockpitTerminalClientTests/TerminalAttachmentControllerTests.swift`
- Modify: `Applications/CockpitApp/Terminal/GhosttyTerminalView.swift`
- Modify: `Applications/CockpitApp/Terminal/TerminalTabViewController.swift`
- Modify: `Applications/CockpitApp/AppDelegate.swift`
- Test: `Tests/CockpitAppTests/GhosttyTerminalViewTests.swift`

**Interfaces:**
- Produces SPI: `TerminalAttachmentController.send(_ payload: TerminalInput.Payload, context: RequestContext) async throws`.
- Produces: `GhosttyTerminalView.inputHandler: (TerminalInput.Payload) -> Void` and `gridHandler: (TerminalResize) -> Void`.
- Produces: `TerminalTabViewController` initializer input `requestContext: @MainActor @Sendable () throws -> RequestContext`.

- [ ] **Step 1: Write failing terminal-client payload test**

Attach with the real test control/data transports, call the payload overload, and assert the sent frame uses the active session, actual lease ID, and current sequence rather than caller-provided placeholders.

```swift
try await controller.send(.text("echo cockpit\n"), context: literalContext)
let sent = try XCTUnwrap(connection.sentInputs.first)
XCTAssertEqual(sent.terminalSessionID, sessionID)
XCTAssertEqual(sent.inputLeaseID, lease.leaseID)
XCTAssertEqual(sent.inputSequence, lease.sequenceBase)
XCTAssertEqual(sent.payload, .text("echo cockpit\n"))
```

- [ ] **Step 2: Run the exact terminal-client test RED**

```bash
swift test --disable-automatic-resolution --skip-update \
  --filter TerminalAttachmentControllerTests/testPayloadSendUsesActiveLeaseAndSequence
```

Expected: compile failure for the absent overload.

- [ ] **Step 3: Implement the payload overload and run the terminal-client suite GREEN**

Validate context/client identity, acquire the existing `inputGate`, require active attachment and lease, construct the real `TerminalInput` with the active session/lease/next sequence, send, verify acknowledgement, and increment sequence. Make the existing full-frame `send` delegate to the same private primitive so behavior does not diverge.

- [ ] **Step 4: Write failing AppKit responder tests**

In `GhosttyTerminalViewTests`, test observable payloads from real view methods:

- `acceptsFirstResponder == true`, mouse down makes the view first responder.
- `insertText("你好")` emits exactly `.text("你好")`.
- marked text is not emitted; committing it emits once.
- Command-V with a literal pasteboard string emits `.paste` once; empty pasteboard emits nothing.
- Return/Tab/Escape/Backspace/Delete/arrows/Home/End/PageUp/PageDown/F1 map to literal USB HID usages and modifier bits.
- Control-C emits `.key`; Command-C without a selection emits nothing.

The production mutation these tests catch is removing `interpretKeyEvents`/`NSTextInputClient` and leaving the renderer-only view.

- [ ] **Step 5: Run `GhosttyTerminalViewTests` and verify RED**

Use the App test command from Task 1 with only `GhosttyTerminalViewTests`. Expected failures: the view rejects first responder and no payloads are recorded.

- [ ] **Step 6: Implement AppKit text input normalization**

Make `GhosttyTerminalView` conform to `NSTextInputClient`, maintain only marked-text state, route committed strings to `.text`, route paste to `.paste`, and route special keys through a literal macOS key-code -> USB HID usage table. Call `interpretKeyEvents([event])` for text/IME and use `doCommand(by:)` for editing commands. Use AppKit modifier flags to produce the existing 10-bit terminal modifier mask. Do not encode escape sequences in the App; Keeper Ghostty VT remains the encoder.

- [ ] **Step 7: Write a failing serialization/input-error test for the tab controller**

Use an attachment test double whose first payload blocks. Enqueue text, paste, and resize; release it; assert send order is exactly text -> paste -> resize. Then make one send fail and assert the inline status label is visible once while a later successful send clears it.

- [ ] **Step 8: Implement the serial UI queue and request-context injection**

Set `terminalView.inputHandler` and `gridHandler` in `TerminalTabViewController`. Chain each send behind the prior task on `@MainActor`, call the payload overload with a fresh `RequestID`, and retain no unordered fire-and-forget sends. AppDelegate supplies a closure that creates `RequestContext(validating: .current, clientInstanceID:windowID:workspaceContextID:environmentID:activeContextGeneration:requestID:)`. Cancel and clear the chain on detach/session replacement.

- [ ] **Step 9: Run terminal-client and App focused tests GREEN and commit**

```bash
git add Sources/CockpitTerminalClient/TerminalAttachmentController.swift \
  Tests/CockpitTerminalClientTests/TerminalAttachmentControllerTests.swift \
  Applications/CockpitApp/Terminal/GhosttyTerminalView.swift \
  Applications/CockpitApp/Terminal/TerminalTabViewController.swift \
  Applications/CockpitApp/AppDelegate.swift \
  Tests/CockpitAppTests/GhosttyTerminalViewTests.swift
git commit -m "feat: enable interactive terminal input"
```

---

### Task 3: Keep terminal glyphs at fixed 13pt and resize the PTY grid

**Files:**
- Modify: `Native/CockpitGhosttyBridge/include/cockpit_ghostty.h`
- Modify: `Patches/ghostty/0001-cockpit-external-vt-renderer.patch`
- Modify: `Applications/CockpitApp/Terminal/GhosttyTerminalView.swift`
- Modify: `Applications/CockpitApp/Terminal/TerminalTabViewController.swift`
- Test: `Tests/CockpitAppTests/GhosttyTerminalViewTests.swift`
- Modify/Test: `Tests/ToolingTests/ghostty-bridge.zsh`

**Interfaces:**
- Produces C struct `cockpit_ghostty_grid_t { columns, rows, cell_width, cell_height }`.
- Changes C resize to `cockpit_ghostty_renderer_resize(renderer,pixels_w,pixels_h,scale,font_points,&grid)`.
- Produces Swift `GhosttyRendererLayout` and `GhosttyRendererDriving.resize(...) -> GhosttyRendererLayout?`.

- [ ] **Step 1: Extend the tooling harness first and verify RED**

Compile a literal C/Objective-C harness against the public header. Resize one renderer to 800x600 and 1200x900 at 2x with `font_points=13`; assert both layouts report byte-for-byte equal `cell_width/cell_height`, while the larger viewport reports greater columns and rows. Expected RED is a compile failure for the absent grid struct/signature.

- [ ] **Step 2: Add a failing Swift renderer/grid de-duplication test**

The fake renderer returns literal layouts for two view sizes. Assert the view emits `.resize(80x24)`, emits nothing for another layout with the same grid, then emits `.resize(120x40)`. Assert the fake receives `fontPoints == 13` on every call.

- [ ] **Step 3: Implement fixed-cell renderer metrics**

In the Ghostty patch, cache system monospaced 13pt font metrics at the requested backing scale. Compute pixel `cell_width` from the font's `M` advance and `cell_height` from ascender/descender/leading, clamp both to at least one pixel, and compute `columns=floor(width/cell_width)`, `rows=floor(height/cell_height)`. Render every cell at those cached dimensions, clip to the viewport, and leave remainder pixels as padding. Remove the existing three viewport-derived lines:

```objc
cell_width = width / renderer->columns;
cell_height = height / renderer->rows;
font_size = cell_height * 0.72;
```

- [ ] **Step 4: Update Swift bridge and send de-duplicated resize**

Convert C layout to `TerminalResize` only for positive dimensions within `UInt16`. `GhosttyTerminalView` invokes `gridHandler` only when the grid changes. `TerminalTabViewController` resets its last grid on a new session and sends `.resize` through the serial queue.

- [ ] **Step 5: Run focused App and Ghostty tooling tests GREEN**

```bash
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/GhosttyTerminalViewTests test
Tests/ToolingTests/ghostty-bridge.zsh
```

- [ ] **Step 6: Commit**

```bash
git add Native/CockpitGhosttyBridge/include/cockpit_ghostty.h \
  Patches/ghostty/0001-cockpit-external-vt-renderer.patch \
  Applications/CockpitApp/Terminal/GhosttyTerminalView.swift \
  Applications/CockpitApp/Terminal/TerminalTabViewController.swift \
  Tests/CockpitAppTests/GhosttyTerminalViewTests.swift \
  Tests/ToolingTests/ghostty-bridge.zsh
git commit -m "fix: keep terminal cell metrics fixed"
```

---

### Task 4: Build the approved integrated three-column AppKit workbench

**Files:**
- Create: `Applications/CockpitApp/WorkspaceChromeView.swift`
- Modify: `Applications/CockpitApp/WorkspaceSidebarController.swift`
- Modify: `Applications/CockpitApp/TabStripController.swift`
- Modify: `Applications/CockpitApp/FileTreeViewController.swift`
- Modify: `Applications/CockpitApp/WorkspaceSplitViewController.swift`
- Test: `Tests/CockpitAppTests/WorkspaceHierarchyTests.swift`

**Interfaces:**
- Produces: `WorkspaceColumnView(header:content:footer:)` with exact 48/24 heights.
- Produces: `WorkspaceHeaderBackgroundView` that returns `mouseDownCanMoveWindow == true` while controls remain interactive.
- Consumes: existing sidebar/tab/file-tree update methods and content host.

- [ ] **Step 1: Write failing structural hierarchy tests**

Instantiate the real split controller and assert:

- exactly three split items with initial thicknesses 238 / flexible / 236;
- each root owns one independent header of height 48 and footer of height 24;
- the center tab strip's leading/trailing anchors are descendants of the center item only;
- the right `FILES` header is a descendant of the right item;
- all backgrounds use semantic/dynamic AppKit colors and SF Symbol buttons have accessibility labels.

- [ ] **Step 2: Run `WorkspaceHierarchyTests` RED**

Expected: no header/footer identifiers and current split minimum widths 180/220.

- [ ] **Step 3: Implement reusable chrome and wrap each controller**

Create focused AppKit primitives, then change each controller's `loadView` to install its existing content inside its own column view. Left header contains system-button-safe leading space plus current project title; center header owns only tabs/new-tab; right header owns `FILES` and refresh action. Footers show short semantic statuses. Preserve all existing outline/table delegates and command actions.

- [ ] **Step 4: Apply semantic styling without changing behavior**

Use `NSColor.windowBackgroundColor`, `controlBackgroundColor`, `separatorColor`, `secondaryLabelColor`, `NSVisualEffectView` materials, system fonts, and SF Symbols. Add hover/selected tab states using accent color and a 2pt indicator. Do not introduce a shared full-width top view.

- [ ] **Step 5: Run hierarchy and command-controller suites GREEN, then commit**

```bash
git add Applications/CockpitApp/WorkspaceChromeView.swift \
  Applications/CockpitApp/WorkspaceSidebarController.swift \
  Applications/CockpitApp/TabStripController.swift \
  Applications/CockpitApp/FileTreeViewController.swift \
  Applications/CockpitApp/WorkspaceSplitViewController.swift \
  Tests/CockpitAppTests/WorkspaceHierarchyTests.swift
git commit -m "feat: refine native workspace chrome"
```

---

### Task 5: Add Welcome and persistent integrated window geometry

**Files:**
- Create: `Applications/CockpitApp/WelcomeViewController.swift`
- Modify: `Applications/CockpitApp/WorkspaceWindowController.swift`
- Modify: `Applications/CockpitApp/WorkspaceSplitViewController.swift`
- Modify: `Applications/CockpitApp/WorkspaceSidebarController.swift`
- Modify: `Applications/CockpitApp/FileTreeViewController.swift`
- Test: `Tests/CockpitAppTests/WorkspaceHierarchyTests.swift`

**Interfaces:**
- Produces: `WelcomeViewController(openProject: @MainActor @Sendable () async throws -> Void)`.
- Produces internal pure helper `WorkspaceWindowGeometry.defaultFrame(visibleFrame:)` and `isRestorable(_:screens:)`.
- Consumes: `WorkspaceViewModel.projects`, `WorkspaceViewModel.addProject()`, and existing refresh notifications.

- [ ] **Step 1: Write failing Welcome behavior tests**

Load a zero-project view model, refresh the real split controller, and assert center content is `WelcomeViewController`, no picker was called, left conversation actions are disabled/hidden, and right Files shows an empty state. Invoke the Welcome button and assert the injected add-project action runs exactly once. Then inject a project and assert Welcome is replaced by normal content.

- [ ] **Step 2: Write failing window geometry/chrome tests**

Assert style masks include `.fullSizeContentView`, title visibility is hidden, titlebar is transparent, logical title remains `Cockpit`, minimum content size is 960x640, default frame uses 1440x900 clamped to a literal visible frame, and a saved frame intersecting a current screen is not followed by centering. Assert an off-screen saved frame falls back to the current screen default.

- [ ] **Step 3: Run `WorkspaceHierarchyTests` RED**

Expected: absent Welcome type and current window is 1280x820 followed by unconditional `center()`.

- [ ] **Step 4: Implement Welcome state switching**

Create the fixed Welcome stack with app mark, `Welcome to Cockpit`, one description, and `Open Project…`. The button runs the injected async action and presents only non-cancellation failures through the existing presenter. In `WorkspaceSplitViewController.refresh`, switch to Welcome exactly when `viewModel.projects.isEmpty`; never invoke the picker during refresh/startup.

- [ ] **Step 5: Implement validated frame restoration and integrated titlebar**

Add `.fullSizeContentView`, hide title text, make titlebar transparent, keep standard controls, set minimum size, and move the default-frame calculation to the pure helper. Check saved autosave data before first show; restore only when it intersects a current `NSScreen.visibleFrame`; call `center()` only on the no-valid-save path. Keep `setFrameAutosaveName("Cockpit.WorkspaceWindow")` so move/resize/quit persists.

- [ ] **Step 6: Run hierarchy, menu, project-command, and App focused suites GREEN**

Run `WorkspaceHierarchyTests`, `ApplicationMenuTests`, and `ProjectCommandControllerTests`, then the complete 127+ App test target.

- [ ] **Step 7: Commit**

```bash
git add Applications/CockpitApp/WelcomeViewController.swift \
  Applications/CockpitApp/WorkspaceWindowController.swift \
  Applications/CockpitApp/WorkspaceSplitViewController.swift \
  Applications/CockpitApp/WorkspaceSidebarController.swift \
  Applications/CockpitApp/FileTreeViewController.swift \
  Tests/CockpitAppTests/WorkspaceHierarchyTests.swift
git commit -m "feat: add welcome workspace and window restore"
```

---

### Task 6: Verify the real Release app and close Phase 1

**Files:**
- Modify only if a focused RED identifies a defect within the seven approved requirements.
- Update: `Docs/superpowers/specs/2026-08-13-cockpit-phase-1-product-finish-design.md` status to implemented after all evidence is green.

**Interfaces:**
- Consumes: all five prior tasks.
- Produces: installed Release `.app`, fresh unified gate receipt, clean main branch, and pushed origin/main.

- [ ] **Step 1: Run static and focused preflight**

```bash
git diff --check
git status --short
git diff -- Package.swift Package.resolved .gitmodules ThirdParty/ghostty Patches/ghostty/series
zsh -n Tools/verify-phase1.zsh Tests/ProcessIntegrationTests/*.zsh Tests/ToolingTests/*.zsh
```

Verify no unplanned dependency, lockfile, submodule pointer, or script syntax drift.

- [ ] **Step 2: Generate and build Release**

```bash
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Release \
  -derivedDataPath DerivedData-Release SYMROOT="$PWD/build-release" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation build
```

- [ ] **Step 3: Install the exact Release bundle and perform foreground smoke**

Replace only `/Applications/Cockpit.app` with the newly built `build-release/Release/Cockpit.app`, launch it through LaunchServices, and verify from the running bundle path/signature:

1. zero-project launch shows Welcome without automatically opening a panel;
2. Open Project opens a native folder panel and cancellation returns to Welcome;
3. titlebar is visually integrated and center tabs do not span the Files column;
4. resize, quit, and relaunch restore window frame;
5. Shell input accepts text, Return, Control-C, paste, and IME commit;
6. terminal glyph size remains constant while rows/columns change;
7. persisted file tabs and rapid A/B/A switching do not produce Monaco error 3.

Record exact process PID, bundle path, selected project, restored frame, and terminal/session receipts. Do not infer success from build output alone.

- [ ] **Step 4: Run the single authoritative unified gate**

```bash
Tools/verify-phase1.zsh
```

Required: exit 0 and exact final line `Phase 1 unified gate: PASS`. Stop at the first failing node, diagnose that exact failure, add a reproducing test, fix, and restart the full gate only after focused GREEN.

- [ ] **Step 5: Audit cleanup and repository scope**

Confirm no test LaunchAgent labels, Keeper/CLI/App fixture processes, `/private/tmp/cockpit-phase*` roots, cache fixture roots, namespaced Keychain records, or namespaced preferences remain. Confirm `git diff --check` and the dependency/submodule audit remain clean.

- [ ] **Step 6: Mark the design implemented, commit, and push main**

```bash
git add Docs/superpowers/specs/2026-08-13-cockpit-phase-1-product-finish-design.md
git commit -m "docs: complete phase 1 product finish"
git push origin main
```

Report commit SHAs, installed Release bundle path/signature, focused test receipts, full gate final line, and cleanup audit. Do not claim Phase 1 complete without all four categories.
