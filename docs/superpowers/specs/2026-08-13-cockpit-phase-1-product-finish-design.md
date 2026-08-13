# Cockpit Phase 1 产品收尾设计

日期：2026-08-13
状态：已批准设计的工程化规格
视觉基线：`.superpowers/brainstorm/91116-1786592814/content/native-workbench-columns-v3.html`

## 1. 目标与固定范围

本次工作只收尾以下七项，不增加 Phase 2 功能：

1. Shell、Codex、Claude 终端接受真实键盘输入、组合文本与粘贴。
2. 主窗口按已确认的 A 方案完成原生 macOS 工作台视觉。
3. 首次默认窗口更大，用户调整后的尺寸与位置在下次启动恢复。
4. 切换已存在的文件页签不再抛出 `Cockpit.MonacoBridgeError error 3`。
5. 没有 Project 时显示 Welcome，并由用户点击 `Open Project…` 打开原生目录选择器。
6. 移除独立横条式标题栏，让系统窗口控制与三栏顶部区域融合。
7. 终端字号固定为 13pt；调整窗口只改变 PTY 行列数，不缩放文字。

明确排除：多 Project、Git/Search/LSP UI、设置界面、通用主题编辑器、终端字体设置 UI、远程工作区和 Phase 2 协议。

## 2. 已选择的界面方案

已选择“三栏顶部边界修正版”，拒绝以下两个方向：

- 保留标准独立标题栏：与用户要求冲突。
- 用一条自定义顶栏横跨三栏：会让中栏 Tab 侵占右栏 Files 区域，与已确认反馈冲突。

主窗口继续使用 AppKit `NSWindow`、`NSSplitViewController` 和现有控制器，不迁移 SwiftUI。窗口保留系统 close/minimize/zoom 控件和逻辑标题，以维持 macOS 窗口管理、辅助功能和菜单行为；视觉上使用 full-size content、隐藏标题文字和透明 titlebar，使内容延伸到系统按钮区域。

三栏固定边界如下：

- 左栏：48pt 顶部区域容纳系统窗口按钮和当前 Project；中部显示 Workspace/Conversation 导航；底部为 24pt 状态区。
- 中栏：48pt 顶部区域只显示该栏的页签与新建操作；中部显示 Welcome、Monaco 或 Terminal；底部为 24pt 编辑状态区。
- 右栏：48pt 独立 `FILES` 标题与操作区；中部为文件树；底部为 24pt 状态区。

视觉只使用 AppKit 语义色、系统材质、SF Symbols、系统字体和系统 accent color。浅色与深色外观均由动态系统颜色驱动，不引入自绘 SVG、第三方 UI 依赖或硬编码整套主题。

## 3. Welcome 与启动流程

`WorkspaceWindowController.start()` 先加载 workspace，再选择内容状态：

- workspace 没有 Project：显示三栏工作台和中栏 Welcome；不自动弹出 `NSOpenPanel`。
- 用户点击 `Open Project…` 或菜单 `File > Open Project…`：复用 `ProjectCommandController.appKitDirectoryPicker()`。
- Project 创建成功：选择 Project Context，刷新三栏并用 Project 工作区替换 Welcome。
- workspace 已有 Project：直接恢复上次持久化 Context、页签与窗口，不显示 Welcome。

Welcome 中心内容固定为应用标识、`Welcome to Cockpit`、一句产品说明和主按钮 `Open Project…`。左栏在零 Project 状态只显示 Workspace 概览，不显示不可执行的 Conversation 操作；右栏显示空 Files 状态。

## 4. 窗口尺寸与融合标题栏

默认内容尺寸改为 1440×900，并按当前显示器 `visibleFrame` 收敛，确保在小屏和外接显示器上完整可见。窗口最小尺寸为 960×640。

窗口恢复使用唯一 autosave key `Cockpit.WorkspaceWindow`：

- 有合法保存 frame 时直接恢复，禁止随后调用 `center()` 覆盖恢复值。
- 没有保存 frame 时按可见屏幕居中显示默认尺寸。
- move、resize 和退出时由 AppKit autosave 持久化；恢复值必须与任一当前屏幕的可见区域相交，否则回退默认 frame。

窗口 style 保留 `.titled/.closable/.miniaturizable/.resizable`，增加 `.fullSizeContentView`；设置 `titleVisibility = .hidden`、`titlebarAppearsTransparent = true`。逻辑标题仍为 `Cockpit`。左、中、右顶部背景均可拖动窗口，但按钮、页签和文件操作控件继续接收自己的鼠标事件。

## 5. 终端输入与固定字号

### 5.1 输入数据流

`GhosttyTerminalView` 成为可聚焦的 AppKit 文本输入视图，使用窄接口把用户操作交给 `TerminalTabViewController`：

```text
NSEvent / NSTextInputClient
  -> TerminalInput.Payload (.text / .key / .paste / .resize)
  -> TerminalTabViewController 串行输入队列
  -> TerminalAttachmentController.send
  -> KeeperTerminalDataTransport
  -> PTYKeeper GhosttyVTAdapter
  -> PTY
```

行为固定为：

- 单击终端取得 first responder。
- 普通字符与输入法提交文本发送 `.text`。
- Return、Tab、Escape、Backspace、Delete、方向键、Home/End、Page Up/Down 和功能键发送 `.key`。
- Command-V 读取字符串 pasteboard 并发送 `.paste`；空字符串不发送。
- Command-C 在没有终端选区能力时不发送控制字符；Control-C 发送真实 key event。
- 输入按 UI 接收顺序串行发送，禁止多个无序 `Task` 改变 input sequence。
- 未 attached、只读或 lease 丢失时不吞掉错误；终端内容区显示一次非阻塞错误状态，并允许后续重新 attach 后继续输入。

### 5.2 固定字体与 PTY resize

终端字体固定为系统等宽 13pt。Ghostty renderer 持有由该字体计算出的 cell width/height，并通过 C bridge 返回当前像素区域可容纳的 columns/rows。Swift 端只在计算结果变化时发送 `.resize(TerminalResize)`。

renderer 使用固定 cell metrics 绘制，剩余不足一个 cell 的像素留作边缘 padding；禁止使用 `viewport width / columns` 或 `viewport height / rows` 推导字号。Retina scale 只影响像素密度，不改变 point size。窗口变化的结果是行列数变化，字符尺寸保持不变。

## 6. Monaco 页签恢复与竞态

本机验证 `Cockpit.MonacoBridgeError error 3` 对应 `MonacoBridgeError.unknownDocument`。现有持久化页签只保存 `DocumentID`，新 App 进程重建 `WorkspaceViewModel` 后没有为该引用重建 `DocumentClientController`/Monaco resolver session；选择该页签会在 `selectionReservation` 找不到引用时抛出 `.unknownDocument`。

修复在数据源处完成，不屏蔽错误弹窗：

- `TabCommandController` 增加按 `DocumentID + ActiveContext + TabID` 恢复文件引用的操作。
- 恢复通过现有 `DocumentDataTransport.snapshot(documentID:)`、viewer retain 和 edit lease 重建 `DocumentClientController`，核对 snapshot 的 EnvironmentID、DocumentID 与 Context。
- `WorkspaceViewModel.selectContext` 在选择持久化文件页签前先恢复该引用；`selectTab` 在实际 Monaco selection 前也执行同一幂等保证。
- 同一引用的并发恢复与选择沿用文件 lifecycle gate 串行化；较旧的快速点击请求以 `CancellationError` 结束，不显示模态错误。
- Host 明确返回文档不存在时，将该持久化页签识别为 stale，移除该 TabRecord 并展示可读的 file-missing 状态；不得把真实数据损坏改写成成功。

## 7. 控制器边界

现有控制器保持各自职责，只新增以下窄边界：

- `WorkspaceWindowController`：窗口 chrome、默认 frame、frame 恢复。
- `WorkspaceSplitViewController`：三栏结构与 Welcome/Workspace 状态切换。
- `WorkspaceSidebarController`、`TabStripController`、`FileTreeViewController`：各自 48pt 顶部和 24pt 底部区域，不跨栏绘制。
- `WelcomeViewController`：零 Project 内容和 Open Project action。
- `GhosttyTerminalView`：AppKit responder、IME/paste/key 归一化和 renderer grid 查询。
- `TerminalTabViewController`：输入串行化、attach 生命周期和 resize 去重。
- `TabCommandController`：持久化文件引用恢复。

不得增加新的 Host wire 字段、XPC 方法或数据库 migration；现有 `TerminalInput`、document snapshot 和 client workspace state 已覆盖全部数据需求。

## 8. 错误处理

- Welcome 选择器取消：保持 Welcome，不显示错误。
- Project 打开失败：保持 Welcome，由现有 App error presenter 显示具体错误。
- Monaco stale click：取消旧请求，不显示错误。
- Monaco 真实 file missing：移除无效页签并显示明确状态，不显示枚举数字。
- Terminal input/resize 失败：终端内状态提示；同一连续错误不重复弹窗。
- Window frame 无效或离开所有屏幕：忽略保存值并回退到当前主屏默认 frame。

## 9. 验证与完成标准

每项先写失败测试，再实现：

1. `GhosttyTerminalViewTests` 覆盖 first responder、文本、IME commit、paste、特殊键、串行发送和固定 cell metrics。
2. `WorkspaceHierarchyTests` 覆盖三栏顶部互不跨栏、Welcome 零 Project/Open Project、融合 titlebar、默认 frame 与 autosave 恢复。
3. `TabCommandControllerTests` 与 `WorkspaceViewModelTests` 覆盖 persisted file tab 恢复、快速 A/B/A 页签选择、缺失文档清理。
4. Ghostty tooling tests 覆盖两个不同窗口尺寸下 font point size/cell size不变、grid rows/columns变化。
5. App focused tests全通过后，运行真实 `.app` 前台 smoke，验证拖动、resize/relaunch、Welcome、终端输入和页签切换。
6. 最后运行且只以以下命令 exit 0 和末行 `Phase 1 unified gate: PASS` 作为 Phase 1 收尾证据：

```bash
Tools/verify-phase1.zsh
```

门禁前后必须确认工作区 diff clean、依赖锁/Ghostty submodule未漂移，且没有测试 LaunchAgent、Keeper、临时 root、Keychain 或 preferences 残留。
