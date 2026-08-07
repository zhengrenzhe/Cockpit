### Task 5: 实现 ActiveContext generation 与 Context 布局恢复

**Depends on:** Task 4。

**Files:**

- Modify: `Sources/CockpitTypes/WorkspaceModels.swift`
- Create: `Sources/CockpitClientCore/ActiveContextController.swift`
- Create: `Sources/CockpitClientCore/WorkspaceClientState.swift`
- Create: `Sources/CockpitLocalTransport/ClientIdentityStore.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Modify: `Sources/CockpitPersistence/WorkspaceMigrations.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Create: `Tests/CockpitClientCoreTests/ActiveContextControllerTests.swift`
- Create: `Tests/CockpitClientCoreTests/WorkspaceClientStateTests.swift`
- Create: `Tests/CockpitLocalTransportTests/ClientIdentityStoreTests.swift`
- Modify: `Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift`
- Modify: `Tests/CockpitPersistenceTests/WorkspaceMigrationTests.swift`
- Modify: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`

**Contract:**

```swift
public actor ActiveContextController {
    public func select(_ context: ResolvedWorkspaceContext) -> ActiveContext
    public func accepts(generation: UInt64) -> Bool
    public func current() -> ActiveContext?
}

public struct ClientWorkspaceStateKey: Hashable, Codable, Sendable {
    public let deviceID: DeviceID
    public let windowID: WindowID
    public let workspaceContextID: WorkspaceContextID

    public init(deviceID: DeviceID,
                windowID: WindowID,
                workspaceContextID: WorkspaceContextID)
}

public struct SidebarState: Hashable, Codable, Sendable {
    public var isCollapsed: Bool
    public init(isCollapsed: Bool)
}

public struct SplitViewState: Hashable, Codable, Sendable {
    public var leadingPaneWidth: Double
    public var trailingPaneWidth: Double

    public init(validatingLeadingPaneWidth leadingPaneWidth: Double,
                trailingPaneWidth: Double) throws
    public func validated() throws -> Self
}

public struct ClientWorkspaceState: Hashable, Codable, Sendable {
    public let key: ClientWorkspaceStateKey
    public var tabs: [TabRecord]
    public var selectedTabID: TabID?
    public var sidebar: SidebarState
    public var splitView: SplitViewState

    public init(validatingKey key: ClientWorkspaceStateKey,
                tabs: [TabRecord],
                selectedTabID: TabID?,
                sidebar: SidebarState,
                splitView: SplitViewState) throws
    public func validated() throws -> Self
}
```

`ClientWorkspaceStateKey`、`ClientWorkspaceState`、`SidebarState` 与 `SplitViewState` 在本任务加入 `CockpitTypes/WorkspaceModels.swift`，供 HostCore 与 ClientCore 共同依赖；HostCore 永远不依赖 ClientCore。`SplitViewState` 的宽度必须有限且不小于 0；state 拒绝重复 TabID，非空 selectedTabID 必须引用 tabs。`WorkspaceClientState.swift` 只实现 ClientCore 的状态协调逻辑，不拥有这些共享类型。`TabRecord`、`TextPosition`、`TextRange` 与 `DocumentViewState` 直接使用 Task 2 已批准并实现的 CockpitTypes 领域值，不在本任务重复定义。Generation 从进程内 1 单调递增，不写数据库。每个异步 UI response/event 必须先通过 `accepts(generation:)`，相同 Context 的旧 generation 也被拒绝。file `TabRecord` 按 WorkspaceContext 保存 `DocumentViewState`；文本仍由 Environment 级 DocumentID 共享。

Task 5 在 `WorkspaceMigrations` 新增 migration v2，且只创建 `client_workspace_states(device_id, window_id, context_kind, context_id, state_json)`；复合主键固定为 `(device_id, window_id, context_kind, context_id)`。`state_json` 是 `ClientWorkspaceState` 的 UTF-8 Codable JSON，写入前和读取后都执行批准设计中的 validation path。`WorkspaceRepository` 从本任务起增加：

```swift
func loadClientState(_ key: ClientWorkspaceStateKey) async throws -> ClientWorkspaceState?
func saveClientState(_ state: ClientWorkspaceState) async throws
```

`ClientIdentityStore` 使用可注入的 Keychain/Preferences ports：DeviceID 以 service `dev.cockpit.client-identity`、account `device-id-v1` 持久化；Phase 1 主窗口的 WindowID 以 preferences key `main-window-id-v1` 持久化；ClientInstanceID 每次 App 启动重新生成。生产实现只在 App composition root 使用，测试使用 UUID 隔离的 service 与独立 `UserDefaults` suite。

- [ ] **Step 1: 写失败测试**

使用固定序列 `A(17) -> B(18) -> A(19)` 断言 17 的文件树、Document 与布局结果均不被应用；断言 migration v1 数据库升级到 v2 后才出现 `client_workspace_states`，v2 事务回滚不留下表或版本记录；断言 Project Context 和两个 Conversation 各自恢复不同 tabs/selectedTab/sidebar/splitView/cursor/selection/scroll，同时引用同一个 DocumentID；覆盖非法 split width、重复 TabID、selectedTabID 不存在及非法 Codable JSON 拒绝；重建 store 后 DeviceID 和主 WindowID 不变，ClientInstanceID 改变。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'activeContextGenerationRejectsEveryStaleResultKindAcrossRepeatedContextSelection|workspaceClientStateCoordinatesValidatedValuesByExactContextKey|splitViewRejectsNonfiniteAndNegativeWidthsThroughEveryValidationPath|clientWorkspaceState(RecursivelyRejectsInvalidTabsAndSelection|CodableRejectsMutatedInvalidDomainValues)|clientIdentityPersistsDeviceAndMainWindowAcrossStoresButNotClientInstance|invalidPersisted(DeviceIDFailsClosedWithoutOverwritingKeychain|MainWindowIDFailsClosedWithoutOverwritingPreferences)|createsProjectAndDirectEnvironmentAtomically|failedEnvironmentInsertRollsBackProjectAndEnvironment|rejectsASecondProjectAtThePhaseOneLimit|conversationsShareTheProjectBaseEnvironment|reopening(PreservesProjectConversationAndEnvironmentResolution|RepositoryEnumeratesAllConversationsFromDatabaseURL)|repositoryTextValuesRoundTripEmbeddedNUL|nonGitProjectRoundTripsWithoutGitCommonDirectory|clientWorkspace(LayoutsRoundTripIndependentlyAcrossProjectAndConversations|State(SaveValidatesAndUpsertsOneExactKey|LoadRejectsSQLJSONKeyMismatchAndMalformedStoredValues))|workspaceMigration(sCreateOnlyTheApprovedTables|UpgradesV1DataToV2AndCreatesExactClientStateSchema)|failedV2MigrationLeavesV1DataWithoutV2TableOrVersion|failedMigrationRollsBackItsSchemaChanges|documentsMigration(UsesEnvironmentLocatorAndApprovedPersistentState|EnforcesLocatorDirtyStateAndNonnegativeVersions)|environmentsMigrationAllowsMissingGitCommonDirectory'
```

Expected: 失败，原因是 ActiveContextController 与布局模型不存在。

- [ ] **Step 3: 实现 actor 与 repository 映射**

在 CockpitTypes 实现共享 client-state 值与显式 Codable validation；ClientCore 只保存稳定 ID 和值类型，不导入 AppKit、XPC 或 SQLite3。WorkspaceMigrations 实现 v2；SQLite repository 实现 load/save，布局保存是 Host 的单条 upsert，Terminal tab 只保存 TerminalSessionID 引用。HostCore 只依赖 CockpitTypes 中的共享值，不导入或依赖 ClientCore。

Task 4 的 `InMemoryWorkspaceRepository` 测试替身同步实现新增的 client-state load/save requirements，并使用内存字典保持真实协议语义；该维护变更只保证现有 HostCore 测试目标继续编译，不增加 Task 5 产品行为。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'activeContextGenerationRejectsEveryStaleResultKindAcrossRepeatedContextSelection|workspaceClientStateCoordinatesValidatedValuesByExactContextKey|splitViewRejectsNonfiniteAndNegativeWidthsThroughEveryValidationPath|clientWorkspaceState(RecursivelyRejectsInvalidTabsAndSelection|CodableRejectsMutatedInvalidDomainValues)|clientIdentityPersistsDeviceAndMainWindowAcrossStoresButNotClientInstance|invalidPersisted(DeviceIDFailsClosedWithoutOverwritingKeychain|MainWindowIDFailsClosedWithoutOverwritingPreferences)|createsProjectAndDirectEnvironmentAtomically|failedEnvironmentInsertRollsBackProjectAndEnvironment|rejectsASecondProjectAtThePhaseOneLimit|conversationsShareTheProjectBaseEnvironment|reopening(PreservesProjectConversationAndEnvironmentResolution|RepositoryEnumeratesAllConversationsFromDatabaseURL)|repositoryTextValuesRoundTripEmbeddedNUL|nonGitProjectRoundTripsWithoutGitCommonDirectory|clientWorkspace(LayoutsRoundTripIndependentlyAcrossProjectAndConversations|State(SaveValidatesAndUpsertsOneExactKey|LoadRejectsSQLJSONKeyMismatchAndMalformedStoredValues))|workspaceMigration(sCreateOnlyTheApprovedTables|UpgradesV1DataToV2AndCreatesExactClientStateSchema)|failedV2MigrationLeavesV1DataWithoutV2TableOrVersion|failedMigrationRollsBackItsSchemaChanges|documentsMigration(UsesEnvironmentLocatorAndApprovedPersistentState|EnforcesLocatorDirtyStateAndNonnegativeVersions)|environmentsMigrationAllowsMissingGitCommonDirectory'
/usr/bin/git diff --check
git add Sources/CockpitTypes/WorkspaceModels.swift Sources/CockpitClientCore Sources/CockpitLocalTransport/ClientIdentityStore.swift Sources/CockpitHostCore/WorkspaceRepository.swift Sources/CockpitPersistence/WorkspaceMigrations.swift Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift Tests/CockpitClientCoreTests Tests/CockpitLocalTransportTests/ClientIdentityStoreTests.swift Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift Tests/CockpitPersistenceTests/WorkspaceMigrationTests.swift Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift
git commit -m "feat: isolate workspace context state"
```

---
