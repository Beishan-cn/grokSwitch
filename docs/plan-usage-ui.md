# Plan: Usage accuracy & UI polish

## Goals / Non-goals

### Goals
1. **用量查询正确性**：截断/不完整 gRPC-web 响应时不再丢弃已完整的 data frame；凭证选择在过期 OIDC 与有效 legacy 并存时选可用 token；`auth.json` 解析失败不再伪装成「未登录」。
2. **解析启发式可维护**：percent / reset 提取路径与回退规则写清楚、小幅收紧；不为假想 proto 做大重构。
3. **菜单栏 / 设置 UI 可扫描、状态一致**：长列表可滚动；Settings 重命名草稿与菜单栏重命名同步；状态/错误消息由 store 统一管理；图标尺寸与缓存安全。
4. **FolderPicker 与 MenuBarExtra 共存**：从菜单选目录后，pending 选择不因面板抢焦点而丢失。
5. **`showEmailInMenuBar` 语义对齐**：命名/默认值/文案与 store 侧计划一致，不在本 PR 做无关配置迁移大手术。

### Non-goals
- 不实现 token refresh / OAuth 完整生命周期。
- 不逆向完整 `GetGrokCreditsConfig` protobuf schema 或生成正式 `.proto` 代码。
- 不重做 MenuBarExtra 架构（仍用 `.window` + 内联 expander，不用 sheet）。
- 不处理 store 计划中的 config 损坏 re-seed、switch/add 回滚等（见 store plan；本计划仅协调 `showEmailInMenuBar` 默认值）。
- 不扩大团队账号用量支持面（仍可标 `teamUnsupported`）。
- 不引入新的 UI 框架或第三方依赖。

---

## Implementation steps (usage first, then UI)

### Phase A — Usage / Auth accuracy

#### A1. `grpcWebDataFrames`：截断时保留已解析 data frames
**File:** `Sources/GrokSwitch/UsageFetcher.swift` (`grpcWebDataFrames`)

**现状：** 帧头不足 5 字节，或 `length` 使 `end > bytes.count` 时 **`return []`**，丢掉循环中已收集的 data frames。trailer 解析路径用 `break` 保留部分结果，行为不一致。`parseGRPCWebResponse` 在 payloads 为空时再试 `looksLikeProtobufPayload`；带 `0x00` 帧标志的 framed body 不是裸 protobuf，最终 `emptyResponse`。

**改动：**
1. 帧头不足 / body 不完整时改为 **`break`**，返回已收集的 `frames`。
2. 可选：跳过 **zero-length** data frame（flags=0, length=0），避免 payloads 非空却扫不到字段 → 误报 `parseFailed`。
3. `parseGRPCWebResponse` 错误细分（小改即可）：
   - body 为空 → `emptyResponse`
   - 有字节但无完整 data frame → `invalidResponse` 或 `parseFailed`（文案区分「响应截断」与「无法解析」），**不要**一律 `emptyResponse`
4. 顺带：length 用 `UInt32` 拼装；去掉无意义的 `length >= 0`；可选上限（如 4 MiB）防异常声明长度。

**验证点：** 构造「完整 data frame + 截断 trailer」合成字节，断言 percent 仍可解析。

---

#### A2. `selectPreferredEntry`：非过期优先，再 OIDC > legacy
**File:** `Sources/GrokSwitch/AuthReader.swift`

**现状：** 遍历覆盖 `oidcCandidate`，返回 `oidcCandidate ?? legacyCandidate ?? otherCandidate`，**不看 `expires_at`**。过期 SuperGrok OIDC 压过仍有效的 `https://accounts.x.ai/sign-in` legacy。

**改动：**
1. 收集所有带非空 `key` 的候选，分类：OIDC（`oidcScopePrefix`）、legacy（精确 `legacySessionScope`，可保留有限的 `/sign-in` 兼容）、other。
2. 排序/选择规则（建议）：
   - **第一键：未过期优先**（`expires_at` 解析后 `Date() < expiresAt - 30s` 视为可用；**无 `expires_at` 视为「未知，不当作已过期」**，与 `GrokCredentials.isExpired` 一致）。
   - **第二键：OIDC > legacy > other**。
   - **第三键：** 同类多条时取 `expires_at` 最晚者（或最后出现且未过期）。
3. 实现保持小：可写成「从 prefer 列表里 `first(where: isUsable)`，再 fallback 到 prefer 列表第一条」，避免过度抽象。

**不在此步：** 自动 refresh token、改写 `auth.json`。

---

#### A3. `decodeFailed` 不再映射为 `missingCredentials`
**Files:** `UsageFetcher.swift`（`fetch(authURL:)`）、`UsageModels.swift`（`fromFetchError` 如需）

**现状：**
```swift
} catch AuthReader.Error.notFound {
    return .failure(.missingCredentials)
} catch AuthReader.Error.missingTokens {
    return .failure(.missingCredentials)
} catch {
    return .failure(.missingCredentials)  // 吞掉 decodeFailed
}
```
损坏 JSON → UI「未登录：请运行 grok login」+ `.notLoggedIn()`。

**改动：**
1. 显式 `catch AuthReader.Error.decodeFailed(let message)` → 专用错误。优先：
   - 新增 `FetchError.authParseFailed(String)`（推荐，语义清晰），或
   - 复用 `parseFailed` / 带固定前缀的 `network`（不推荐混淆网络）。
2. `notFound` / `missingTokens` 仍 → `missingCredentials`。
3. 其它 IO（读文件失败）→ `network` 或 `authParseFailed`，**不要**当未登录。
4. `ProfileUsage.fromFetchError`：`authParseFailed` → `.failed("auth.json 无法解析…")`，**不是** `.notLoggedIn()`。

**API：** 见下方「API surface changes」。

---

#### A4. Percent / reset 启发式：文档化 + 小幅收紧（不重做）
**File:** `UsageFetcher.swift` (`parseGRPCWebResponse` + `scanProtobuf`)

**原则：** 保持 heuristic，不生成 proto 代码；只做低风险收紧 + 注释。

**Percent：**
1. 在 `parseGRPCWebResponse` 上方用注释固定当前约定：
   - 优先 path 以 field `1` 结尾、值 ∈ [0, 100]、finite 的 fixed32 float；
   - 浅路径优先，同深度取 scan order 更早。
2. **可选小改：** 要求 path 以 `[1, …]` 开头（顶层 message field 1），减少无关嵌套 float。
3. **可选：** wire type 1（fixed64）若 bitPattern 转 Double 后在 [0, 100]，作为次级候选；若实现成本高可只记 TODO。
4. **`noUsageYet`：** 条件从「`fixed32Fields.isEmpty`」改为「**无 percent 候选**」+ 现有 reset / usage-period 信号；避免无关 float 挡住 0% 回退。

**Reset：**
1. 注释说明：优先 path `[1, 5, 1]`，否则 future-ish varint 的最小时间戳；epoch 窗口约 `[1.7e9, 2.1e9]`。
2. **小改：** future 过滤放宽 grace（如 `date > now - 120s`），使刚过期的 reset 能显示「已重置」而非静默 `nil`（与 `UsageModels.resetShortLabel` 对齐）。
3. 不引入复杂路径白名单表。

**Out of scope for this phase：** URLSession ephemeral、retry URLError 保留、team message 软匹配——可单列 follow-up，不阻塞本 PR。

---

### Phase B — UI polish

#### B1. 长列表 `ScrollView` + maxHeight
**File:** `MenuBarView.swift`

**现状：** `projectPickerInline` 注释写「可滚动感」，实为裸 `ForEach`；`profileList` 同样无上限。项目多时 MenuBarExtra 窗口无限增高。

**改动：**
1. 项目行：`ScrollView { LazyVStack / VStack { ForEach } }.frame(maxHeight: 240)`（约 220–280，与菜单宽度协调）。
2. 账号列表（switch + manage）：同样 `ScrollView` + maxHeight（账号通常更少，可略小如 200，或共用常量）。
3. 终端列表若 `TerminalApp` 变长也可同样处理；当前枚举短，可选。
4. 保证滚动区域内按钮仍可点、底部「完成/取消」**固定在 ScrollView 外**。

---

#### B2. Settings rename draft 与菜单重命名同步
**File:** `GrokSwitchApp.swift`（`SettingsView.syncRenameDrafts`）

**现状：** `syncRenameDrafts` 只在 `drafts[id] == nil` 时填充；菜单 `renameProfile` 成功后 Settings 仍显示旧 draft，`canCommitRename` 为 true，点「保存名称」会写回旧名。

**改动（选一，推荐 1）：**
1. **脏标记：** `renameDrafts` 旁维护 `dirtyRenameIDs: Set<String>`；用户编辑 TextField 时标记 dirty；`onChange(profiles)` 时对 **非 dirty** 的 id 用 `profile.name` 覆盖 draft；dirty 的保留本地编辑。提交成功 / 删除 id 时清 dirty。
2. **简化方案：** 若 draft == 该 profile 的「上次已知名」（需缓存 `lastSyncedNames`），则接受外部更新。比 dirty 稍脆，但实现短。

避免：每次 profiles 变化无条件覆盖（会丢掉用户正在编辑的半成品）。

---

#### B3. `statusMessage` / `lastError` 归属 store
**Files:** `ProfileStore.swift`, `MenuBarView.swift`

**现状：** 菜单「刷新」直接 `store.statusMessage = "已刷新…"`，且 **不** `lastError = nil` → 成功状态与旧错误并排显示。其它路径（switch/add/rename）会成对清理。

**改动：**
1. `@Published private(set) var statusMessage`（与 `lastError` 对称；`lastError` 可仍由 store 写，对外 `private(set)` 更佳）。
2. 新增例如：
   - `func noteStatus(_ message: String?, clearError: Bool = true)`
   - 或 `func markRefreshed()` 在 `reload` + 触发 refresh 后设文案。
3. `MenuBarView` 刷新按钮改为 `store.reload(); store.refreshUsage(force: true); store.noteStatus("已刷新账号与用量")`。
4. 约定：设置成功类 status 时默认清 `lastError`；失败只设 `lastError`，可选清 status（与现有 switch 路径一致）。

---

#### B4. MenuBarIcon：固定画布 + 不缓存共享模板引用
**File:** `MenuBarIcon.swift`（及 `GrokSwitchApp` label frame 若需统一）

**现状：**
- Brand 16pt vs loading 18pt → 菜单 `.frame(16)` 缩放跳动。
- 非 loading 路径把 **`baseTemplate` 同一 NSImage 实例** 放进 `renderedCache` 并直接返回；外部若改 `size`/`isTemplate` 会污染全局。

**改动：**
1. **统一 canvas：** 始终渲染到同一 point size（推荐 **16×16**，loading 弧 inset 画在内侧；或始终 18 且 label frame 改 18——二选一，与 CodexBar 对齐则 16）。
2. Brand 路径：`copy()` 或每次烘焙为独立 bitmap 再缓存；**禁止** `renderedCache[key] = baseTemplate` 共享引用。
3. 简化 `CacheKey` 为 enum `{ brand, loading }`（去掉未使用的 bucket/severity 文档噪音）。
4. `GrokSwitchApp` label 的 `.frame` 与 canvas 一致。

---

#### B5. FolderPicker 从菜单调用不丢 pending
**Files:** `MenuBarView.swift`（`browseAnyProject` / `changeScanRoot`）、必要时 `Paths.swift` / `ProfileStore`

**现状：** `NSOpenPanel.runModal()` 激活应用并抢焦点 → MenuBarExtra `.window` 常被关掉 → `@State`（`pendingProjectPath`、`isChoosingProject`、`scannedProjects`）销毁；用户选完目录后菜单状态没了。Settings 有真实窗口，无此问题。

**改动（推荐组合）：**
1. **扫描目录：** 从菜单「扫描目录…」成功后 **立刻** `store.setProjectsScanRoot`（已是），并在重新打开菜单时靠 store 即可；可选 `noteStatus`。
2. **浏览项目：** 成功选路径后 **立刻** `store.setPreferredProjectPath(url.path)`（提交，而非只写 pending），并 `noteStatus`；若希望仍走「完成」确认，则：
   - 把 pending 项目路径放到 **ProfileStore 临时字段**（`@Published var menuPendingProjectPath`），不依赖 MenuBarView `@State` 存活；或
   - 去掉菜单内 FolderPicker，文案引导「在设置中浏览…」（体验较差，备选）。
3. **推荐默认：** browse → **立即 commit 到 store**（与「点选列表 + 完成」不同：面板本身是明确确认）；`isChoosingProject` 若窗口已死则无所谓，用户再开菜单会看到 store 中的默认项目。
4. 文档注释：`FolderPicker` 说明菜单调用方应 commit 到 store，勿只依赖 view 本地 state。

---

#### B6. `showEmailInMenuBar` 命名 / 默认值（与 store plan 协调）
**Files:** `Models.swift`, `ProfileStore.swift`（seed/empty）, `GrokSwitchApp.swift` Settings 文案, `menuBarTitle`

**现状：**
| 位置 | 值 |
|------|-----|
| `AppConfig.empty` / seed | `false` |
| `init(from:)` 缺 key | `?? true` |
| 属性名 | `showEmailInMenuBar` |
| Settings 文案 | 「无用量数据时显示账号短名」 |
| 实际 title | `shortLabel` 或 `profile.name` |

**改动（与 store plan 同一决策，避免两 PR 打架）：**
1. **产品默认统一为 `false`**（紧凑菜单栏 = 仅图标 + 用量%）：`.empty`、seed、`decodeIfPresent ?? false` 一致。若刻意让旧配置缺 key 显示短名，则用显式 migration 注释说明，**不要** silent `true` 与 empty 分叉。
2. 命名：
   - **最小改动：** 保留 Codable key `showEmailInMenuBar`，Swift 属性可 rename 为 `showAccountShortNameInMenuBar` + `CodingKeys` 别名；或
   - 仅改 Settings/README 文案与注释，属性名暂留（本 PR 可接受）。
3. Settings help 补一句：无 ready/loading/expired 用量时（含 failed/team/未登录）回退短名；`showUsageInMenuBar` 关闭时同理。
4. 可选：`menuBarTitle` 在 usage 为 failed/team 时是否显示 `—`/`团队`——与 UI review 一致，本 PR 可只文档化现状，不强制改 title 分支。

**协调：** store plan Issue 8 同一字段；本 plan 落地默认值与文案，store plan 勿再改回 `?? true`。

---

### Phase C — 小收尾（可并入 Phase B PR）

1. `GrokSwitchApp` 菜单 label：`menuBarTitle` 为空时 **省略** `Text`，避免空 Text 占位。
2. 刷新时若仅 `noteStatus`，确认 `isRefreshingUsage` 与 ProgressView 行为不变。
3. DEBUG：`MenuBarIcon.resetCacheForTesting` 保留。

---

## API surface changes if any

| 符号 | 变更 |
|------|------|
| `UsageFetcher.FetchError` | **新增** `authParseFailed(String)`（或等价）；`errorDescription` 中文提示解析 auth.json 失败 |
| `UsageFetcher.fetch(authURL:)` | catch 分支区分 `decodeFailed` vs missing |
| `ProfileUsage.fromFetchError` | 映射新错误 → `.failed(...)` |
| `AuthReader.selectPreferredEntry` | 行为变更（无公开签名变化；`parse` 结果可能换 scope/token） |
| `UsageFetcher.grpcWebDataFrames` | 内部行为；若测试需要可保持 `private` 或 `#if DEBUG` 可见 |
| `ProfileStore.statusMessage` | → `private(set)` |
| `ProfileStore.lastError` | 建议 → `private(set)` |
| `ProfileStore.noteStatus(_:clearError:)` | **新增** |
| `AppConfig.showEmailInMenuBar` | 默认值统一；可选 rename + CodingKey 兼容 |
| `MenuBarIcon` | 无公开 API 破坏；渲染尺寸语义固定 |

无网络协议 / 配置文件 version bump 要求（除非 rename key 并双写，不推荐本 PR 升 `version`）。

---

## Verification

### 手动
1. **截断帧（开发构造 / 代理）：** 若有单元测试更佳；否则临时 fixture Data：valid data frame + 残缺 trailer → 仍显示剩余 %。
2. **双 token auth.json：** OIDC 已过期 + legacy 有效 → 用量 ready；仅 OIDC 过期 → expired；仅损坏 JSON → 「解析失败」类文案，非「未登录」。
3. **无用量 0% 账号：** 有 reset/period、无 percent field → 显示约 100% remaining，非「—」。
4. **长项目列表：** 展开默认项目，>15 项可滚动，完成/取消仍可见。
5. **重命名同步：** 菜单改名 → 打开设置 → 草稿为新名；设置内半编辑未保存 → 不被菜单改名覆盖（若实现 dirty）。
6. **刷新：** 先制造 lastError（如故意失败路径），再点刷新 → 仅成功 status，无红字残留。
7. **图标：** 刷新用量时菜单栏图标无 16/18 跳动。
8. **FolderPicker：** 菜单「浏览…」选目录后关闭菜单再打开 → 默认项目已是所选路径。
9. **短名开关：** 新用户 / 缺 key 旧配置行为符合统一默认；开关文案与 title 一致。

### 自动化（建议最小集，可无 XCTest 目标或脚本）
- `grpcWebDataFrames` / `parseGRPCWebResponse`：完整帧、截断 trailer、空 body、零长 data frame。
- `AuthReader.parse`：过期 OIDC + 有效 legacy；仅 legacy；decode 坏 JSON。
- `syncRenameDrafts` 逻辑若抽成纯函数可测。

### 回归
- `./scripts/dev-run.sh` 编译启动（Agents.md 要求）。
- 正常已登录账号用量与重置文案仍合理。

---

## Effort + PR split

| PR | 范围 | 估时 | 依赖 |
|----|------|------|------|
| **PR1 — Usage/Auth accuracy** | A1–A4（frames、token 选择、decodeFailed、heuristic 注释/小收紧） | S–M（0.5–1.5d） | 无 |
| **PR2 — UI polish** | B1–B5 + Phase C | S–M（0.5–1d） | 无（可与 PR1 并行） |
| **PR3 — Menu bar naming defaults** | B6（`showEmailInMenuBar` 默认值 + 文案/可选 rename） | XS（~2h） | 与 **store plan** 同一 merge 窗口；或并入 store PR |

**推荐落地顺序：** PR1 → PR2 → PR3（或 PR3 并入 store 默认值 PR）。  
**风险：** PR1 改变 token 选择可能让「以前误用过期 OIDC」的用户突然用量正常——属修复。Heuristic 收紧 path 前缀时，用真实响应抓包对照一次再合入。

**总 effort：** 约 **1.5–3 人日**（含手动验证，无完整测试目标时偏短；加 fixture 测试 +0.5d）。

---

## Source mapping (issue → step)

| # | Issue | Step |
|---|--------|------|
| 1 | incomplete trailing frame drops data frames | A1 |
| 2 | expired OIDC over valid legacy | A2 |
| 3 | decodeFailed → missingCredentials | A3 |
| 4 | heuristic percent/reset | A4 |
| 5 | no ScrollView for long lists | B1 |
| 6 | Settings rename draft desync | B2 |
| 7 | statusMessage public; lastError not cleared | B3 |
| 8 | MenuBarIcon 16 vs 18; shared NSImage | B4 |
| 9 | FolderPicker dismisses MenuBarExtra | B5 |
| 10 | showEmailInMenuBar naming/defaults | B6 |

---

## Critical files

- `Sources/GrokSwitch/UsageFetcher.swift` — frames、parse、auth error mapping
- `Sources/GrokSwitch/AuthReader.swift` — entry preference、expiry
- `Sources/GrokSwitch/UsageModels.swift` — fromFetchError / 展示文案
- `Sources/GrokSwitch/MenuBarView.swift` — ScrollView、refresh status、FolderPicker commit
- `Sources/GrokSwitch/MenuBarIcon.swift` — 固定尺寸与缓存安全
- `Sources/GrokSwitch/GrokSwitchApp.swift` — Settings rename drafts、菜单栏开关文案
- `Sources/GrokSwitch/Models.swift` / `ProfileStore.swift` — showEmail 默认值与 noteStatus
