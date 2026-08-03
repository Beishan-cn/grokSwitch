# Plan: ProfileStore state safety

## Goals

修复 GrokSwitch `ProfileStore` 中会**静默丢配置 / 内存与磁盘分叉 / 幽灵用量**的 P0 状态安全问题，使：

1. **损坏或不可读的 `~/.grokswitch/config.json` 永不触发 re-seed 覆盖**；仅「文件不存在」才走首次导入/建默认账号。
2. **所有写路径统一为「先快照 / 草稿，再持久化，失败可回滚或保持单一真相」**，杜绝 `switchTo` / `addProfile` / `renameProfile` / settings 在 `saveConfig` 失败后留下脏内存。
3. **`deleteProfile` 在 `saveConfig` 已成功后不再把内存回滚成「磁盘已删、内存仍在」**；`writeActiveEnv` 失败视为配置后的环境同步错误，可重试。
4. **用量刷新任务代际正确**：取消的旧 task 不得把 `isRefreshingUsage` 置 false、不得向已删除 profile 写回 usage。
5. **`confirmAdd` 不再忽略切换失败**；store 提供可表达「创建 + 激活」成败的接口。
6. **`showEmailInMenuBar` 默认值单一来源**（`.empty` / seed / `decodeIfPresent` 一致）。

验收原则：**config.json 是账号注册表的唯一 durable 真相**；`active.env` 是派生副作用；内存在 durable 写失败时应回到写前，在 durable 写成功后应与磁盘一致。

## Non-goals

- 不做完整 SPM/XCTest 工程化（当前无 package；可手测 + 可选轻量纯函数单测若 build 允许）。
- 不改终端启动、`TerminalLauncher`、账单 API / `UsageFetcher` 协议本身。
- 不自动从 `profiles/*` 目录「全量重建」丢失的 config（可作为后续恢复工具；本 PR 最多 quarantine 坏文件 + 明确错误文案）。
- 不复制 `sessions`、不改 shell hook 标记语法（`ShellHook` 仅在切换/删除时继续 best-effort 安装）。
- 不强制本次修完所有 review 次级项（项目路径校验、shell 转义、ISO8601 分数秒等）——**相关风险可在步骤中顺手加固，但不阻塞主线**。
- 不引入 Core Data / 数据库；仍用 JSON 文件。

## Design decisions (with tradeoffs)

### D1. 损坏配置 vs 缺失配置：三分结果，禁止 empty→seed

**决策**：`loadConfig()` 改为返回显式结果，例如：

```text
enum ConfigLoadResult {
  case missing          // 文件不存在 → 允许 seed
  case loaded(AppConfig)
  case unreadable(Error) // 读/解码失败 → 禁止 seed、禁止 save 覆盖，直到用户处理或成功恢复
}
```

`reload()`：

| 结果 | 行为 |
|------|------|
| `missing` + profiles 空 | 调用 `seedDefaultProfileFromExistingGrokHome()`（现状语义） |
| `loaded` 且 profiles 空 | **不 seed 覆盖**；可尝试「只创建空 default 且文件原本就是空列表」——**推荐**：仅 `missing` 时 seed；loaded 但 empty 视为合法空配置，提示用户添加账号，避免误伤 |
| `unreadable` | 保留启动前内存（首次 init 时仍为 `.empty` 但 **不写盘**）；设 `lastError`；可选把坏文件 rename 为 `config.json.corrupt-ISO8601`；**绝不**调用 seed 的 `saveConfig` |

**Tradeoff**：用户若真的只有损坏文件、磁盘上还有 profiles 目录，本方案不会自动找回账号列表（安全优先）。可在错误文案中提示路径与「从备份恢复」。后续可做「扫描 profiles/ 重建」单独功能。

**顺带**：seed 成功写盘前若发现 `profiles/*` 已存在且 config missing，仍只 seed default（与现行为一致）；不在本计划做 orphan 扫描。

### D2. 统一「草稿提交」模式，而不是每个方法各写一套 rollback

**决策**：引入私有提交原语（命名可调整）：

1. `func commitConfig(_ next: AppConfig) throws`  
   - 仅负责 `encoder.encode` + atomic write `Paths.configFile`。  
   - **不**改 `self.config`；调用方在成功后再赋值。

2. 或 `func applyConfigChange(_ body: (inout AppConfig) throws -> Void) rethrows`：  
   - `var draft = config` → `try body(&draft)` → `try persist(draft)` → `config = draft`。  
   - 失败时 `config` 不变。

对 **需要 env 副作用** 的路径（`switchTo`、`addProfile` 首次激活、`deleteProfile` 删当前）：

```text
顺序（推荐）：
  1. 计算 draft AppConfig（及目标 Profile）
  2. try commitConfig(draft)          // durable 真相
  3. self.config = draft              // 内存对齐磁盘
  4. try writeActiveEnv(...)          // 派生
  5. ShellHook.ensureInstalled()      // best-effort；失败可记 warning 不回滚 config
  6. 刷新 identities / usage 等
```

若步骤 2 失败：内存未改，返回 false / nil。  
若步骤 2 成功、4 失败：**不回滚 config**（与 D3 一致）；设 `lastError = "配置已保存，但 active.env 写入失败…"`；可选暴露 `retryWriteActiveEnv()`。

**Tradeoff**：env 与 config 短暂不一致时，菜单栏显示新账号、shell 仍用旧 `GROK_HOME`。这比「内存回滚但磁盘已是新配置」更可诊断（下次 launch 与 UI 一致），且可用重试修复。

**对比「先写 env 再写 config」**：env 成功 + config 失败 → shell 已切、注册表未切，更危险。故 **config 优先**。

### D3. `deleteProfile`：save 成功后禁止「整配置回滚」

**现状 bug**：`previousConfig` 在 save 成功 + env 失败时恢复内存 → 磁盘无该 profile、内存仍有。

**决策**：

```text
1. 校验 count > 1、找到 index
2. 取消 usageRefreshTask（见 D4）
3. 计算 draft：移除 profile、必要时 activeProfileID = first
4. try commitConfig(draft)
5. config = draft；identities/usages 去掉 id（usages 用 filter 只保留仍存在的 keys）
6. if wasActive: try writeActiveEnv(fallback)  // 失败 → lastError，return true? 见下
7. 再删 home 目录（失败 → 警告，账号已从注册表移除）
```

**返回值语义**（建议）：

- `false`：未改磁盘（校验失败或 `commitConfig` 失败）。
- `true`：磁盘注册表已删除该账号。`lastError` 可非空表示 env/目录部分失败。

UI（`confirmDelete` / Settings）继续「true 则关闭确认框」即可；部分失败靠 `lastError` 展示。

**Tradeoff**：删除「半成功」时用户仍需处理 env；但不会出现「看起来还在、重启后消失」或「看起来还在、磁盘已无」。

### D4. 用量刷新 generation + 写回过滤

**决策**：

- `private var usageRefreshGeneration: UInt64 = 0`
- `refreshUsage`：`usageRefreshTask?.cancel()`；`generation += 1`；捕获 `let gen = generation`；启动 Task。
- `performUsageRefresh` 开始：`isRefreshingUsage = true`。
- `defer` / 结束：`if gen == usageRefreshGeneration { isRefreshingUsage = false }`（或「仅当仍是当前 task」）。
- 写回 `usages[profileID] = usage` 前：`guard config.profiles.contains(where: { $0.id == profileID }) else { continue }`；且 `guard gen == usageRefreshGeneration, !Task.isCancelled`。
- `deleteProfile` 开头：`usageRefreshTask?.cancel()`；`usageRefreshGeneration += 1`；清 usages 后可选不立即开新 refresh，或 `refreshUsage(force: false)` 只刷剩余账号。

**Tradeoff**：generation 比「引用相等 Task」更简单，避免 MainActor 上 identity 比较踩坑。短时间多次 refresh 仍会取消 inflight 网络，可接受。

### D5. 创建 + 切换：store 提供组合 API，UI 不再吞掉失败

**现状**：`MenuBarView.confirmAdd`：`addProfile` 成功后 `_ = store.switchTo(...)`，忽略 false；若 add 时已是唯一/已 active 则 switch 多半成功，但 add 未设 active 时（已有其他 active）依赖 switch——失败时终端仍可能 `openTerminal(for: profile)` 用新 profile 的 home（`openTerminal` 直接传 profile，不依赖 active），**登录目录可能对、菜单 active 不对**。

**决策**（二选一，推荐 A）：

- **A. `addProfile(name:activate: Bool = false)`**  
  - `activate == true`：在同一次 draft 里 `append` + `activeProfileID = new`，一次 `commitConfig` + `writeActiveEnv`，避免「add 成功 switch 失败」中间态。  
  - `confirmAdd` 调用 `addProfile(name:activate: true)`，再 `openTerminal`；不再单独 `switchTo`。

- **B. `addAndActivateProfile(name:) -> Profile?`**  
  - 内部等价 A。

同时：`addProfile` 在创建目录后若 `commitConfig` 失败，**删除刚建的空 home**（若目录非空则保留并报错，避免误删用户数据——新建应为空）。

**id 占用**：生成 slug 时除 `config.profiles` 外，检查 `!fm.fileExists(Paths.profileHome(id:))`，避免 orphan 目录被当成新号导致「继承 auth」（review Issue 10/11，强烈建议与本 P0 同做）。

### D6. `showEmailInMenuBar` 默认统一为 `false`

**产品依据**：seed / `.empty` / README「菜单栏默认图标 + 剩余用量」；Settings 文案「无用量数据时显示账号短名」为可选。

**决策**：

- `AppConfig.empty`：`false`（已是）
- seed 两处：`false`（已是）
- `init(from:)`：`decodeIfPresent ?? **false**`（改掉当前 `?? true`）
- 可选：`static let defaultShowEmailInMenuBar = false` 单点引用，防再漂移

**Tradeoff**：旧版从未写过该 key 的 config，升级后会从「显示短名」变为「不显示」。与 seed 新产品默认一致；若需保留旧用户 true，则 decode 保持 `?? true` 并改 seed 为 true——**与当前产品文案相反，不推荐**。在 README/变更说明写一句即可。

### D7. 设置项与 rename 一并纳入同一提交模式

`setShowEmailInMenuBar` / `setShowUsageInMenuBar` / `setPreferredTerminal` / `setPreferredProjectPath` / `setProjectsScanRoot` / `renameProfile`：全部改为 draft → commit → assign；失败不改内存。工作量小，避免只修三处 mutation 方法后设置项仍分叉。

### D8. （建议同 PR 小改）日期编解码稳定，降低「自写自毁」触发 D1

Foundation `.iso8601` 策略在部分系统上对 fractional seconds 编解码不一致，可导致刚写入的 config 下次启动 unreadable → 若未修 D1 会 wipe。  
**建议**：`createdAt` 用 `TimeInterval`（Double）或统一 `ISO8601DateFormatter`（`.withInternetDateTime` 无分秒）。与 D1 同 PR 可显著降低真实 wipe 概率。

---

## Implementation steps (ordered)

### Step 1 — Config 加载结果与安全 `reload`（P0-1）

**Files**

- `Sources/GrokSwitch/ProfileStore.swift` — `loadConfig` / `reload` / 可选 `configLoadBlocked` 状态
- 可选 `Models.swift` — 若把 `ConfigLoadResult` 放模型层（更宜放 store private）

**Concrete changes**

1. 新增 private enum `ConfigLoadResult`（或等价）。
2. 重写 `loadConfig() -> ConfigLoadResult`：
   - 不存在 → `.missing`
   - `Data(contentsOf:)` / `decode` 失败 → `.unreadable(error)`；**不要** `return .empty` 冒充成功
   - 成功 → 规范化 `homePath` tilde 后 `.loaded(cfg)`
3. `reload()`：
   - `.loaded(cfg)` → `config = cfg`；若 `activeProfileID` 无效则修复为 `profiles.first?.id`（内存 + 若需持久化则 `commitConfig`，失败仅 lastError）
   - `.missing` → 保持/置 empty 后 `seedDefaultProfileFromExistingGrokHome()`
   - `.unreadable` → **不调用 seed**；`lastError = "读取配置失败：… 已保留原文件，未覆盖。"`；若 init 首次，不写盘；可选 `quarantineCorruptConfig()` rename 旁路备份
4. 增加 `private var allowConfigWrite: Bool`（默认 true；unreadable 时 false，直到成功 loaded 或用户显式重建）——防止 UI 上 toggle 把空/旧内存写穿坏文件。**或** unreadable 时所有 mutator 直接失败。更简单：**unreadable 时拒绝 `commitConfig`**。
5. Seed 仅从 `reload` 的 `.missing` 路径进入；seed 内部不要在「profiles.isEmpty」被其它路径误调。

**Acceptance criteria**

- 手工把 `config.json` 改成非法 JSON → 启动后：多账号目录仍在、config 未被换成单 default、UI 有明确错误。
- 删除 `config.json`（真缺失）→ 仍可 seed default。
- 合法多账号 config → 行为与现网一致。

**Effort**: M

---

### Step 2 — `commitConfig` + 设置/rename 草稿提交（P0-2 基础）

**Files**

- `Sources/GrokSwitch/ProfileStore.swift`

**Concrete changes**

1. 实现 `private func commitConfig(_ cfg: AppConfig) throws`：`ensureDirectories` + encode + `write(options: .atomic)`。
2. 实现 `private func updateConfig(_ body: (inout AppConfig) throws -> Void) throws`：draft → commit → `config = draft`。
3. 改造：
   - `renameProfile`：只在 draft 改 name；成功后再发 status
   - `setShowEmailInMenuBar` / `setShowUsageInMenuBar` / `setPreferredTerminal` / `setPreferredProjectPath` / `setProjectsScanRoot`：同样
4. 去掉多余的、仅因嵌套 mutate 而补的 `objectWillChange.send()`（整值替换 `config` 已够）；usage 强制刷新路径可保留。

**Acceptance criteria**

- 模拟 `commitConfig` 抛错（临时改 path 权限或注入）：rename/toggle 后 UI 与重启后一致（仍为旧值）。
- 成功路径行为不变。

**Effort**: S–M

---

### Step 3 — `switchTo` 安全顺序（P0-2）

**Files**

- `Sources/GrokSwitch/ProfileStore.swift` — `switchTo`

**Concrete changes**

```text
guard profile exists
var draft = config
draft.activeProfileID = profile.id
do {
  try commitConfig(draft)
  config = draft
  do {
    try writeActiveEnv(for: profile)
  } catch {
    lastError = "已切换账号配置，但 active.env 写入失败：…"
    // 仍 return true 或 false？建议：return true（注册表已切）或
    // 引入 enum；最小改动：return false 但 config 保持已切 — 易误导 UI
    // 推荐：return true + lastError 非空，与 delete 一致
  }
  _ = ShellHook.ensureInstalled()
  refreshIdentities()
  refreshUsage(force: false)
  statusMessage = …
  if lastError == nil { lastError = nil } // 仅 env 失败时保留 lastError
  return true
} catch {
  // commit 失败：config 未改
  lastError = "切换失败：…"
  return false
}
```

**Acceptance criteria**

- commit 失败：active 不变、磁盘不变。
- commit 成功 env 失败：磁盘 active 为新 id，内存一致，lastError 提示 env；重启后 active 仍为新 id。

**Effort**: S

---

### Step 4 — `addProfile` 草稿 + 目录回滚 + 可选 activate（P0-2 + P0-5）

**Files**

- `Sources/GrokSwitch/ProfileStore.swift` — `addProfile`
- `Sources/GrokSwitch/MenuBarView.swift` — `confirmAdd`

**Concrete changes**

1. 签名建议：`func addProfile(name: String, activate: Bool = false) -> Profile?`
2. 流程：
   - 校验 name / 生成 id（**同时**检查 `config.profiles` 与 `Paths.profileHome(id:)` 不存在）
   - `createDirectory`
   - `var draft = config`；append；若 `activate || draft.activeProfileID == nil` 则 `draft.activeProfileID = id`
   - `try commitConfig(draft)`；失败则 `removeItem` 新建 home（若仍为空/仅我们创建），return nil
   - `config = draft`
   - 若成为 active：`writeActiveEnv`（失败策略同 Step 3）
   - `usages[id] = .notLoggedIn()`；`refreshIdentities()`
3. `confirmAdd`：
   ```text
   if let profile = store.addProfile(name: newProfileName, activate: true) {
     isAdding = false; newProfileName = ""
     store.openTerminal(for: profile)
   }
   // 不再调用 switchTo；失败时保留输入框与 lastError
   ```
4. 其它调用点（若有）保持 `activate: false` 默认即可。

**Acceptance criteria**

- 创建失败不出现幽灵 list 项；失败后无残留空目录（或仅 orphan 有说明）。
- 创建并 activate 后 active 与 env 指向新 profile；`confirmAdd` 不依赖第二次 switch。
- 已有账号时新建并 activate：一次写盘完成切换。

**Effort**: M

---

### Step 5 — `deleteProfile` 修正（P0-3 + 与 D4 衔接）

**Files**

- `Sources/GrokSwitch/ProfileStore.swift` — `deleteProfile`

**Concrete changes**

1. 开头：`usageRefreshTask?.cancel()`；`usageRefreshGeneration += 1`（或调用统一 `cancelUsageRefresh()`）。
2. 去掉「save 失败才有意义」的整包 `previousConfig` 在 env 失败时的滥用：
   - **仅**在 `commitConfig` 之前需要回滚时用 draft，不必 previous 恢复（因未改 `config`）。
   - 若采用「先改内存再 save」旧结构，则：**commit 成功后禁止 `config = previousConfig`**。
3. 推荐实现完全基于 draft（内存在 commit 成功前不变）：
   ```text
   var draft = config
   draft.profiles.remove...
   if wasActive { draft.activeProfileID = draft.profiles.first?.id }
   try commitConfig(draft)
   config = draft
   identities.removeValue / usages = usages.filter { remaining ids }
   if wasActive, let fallback = activeProfile {
     try? or try writeActiveEnv — 失败设 lastError，不回滚 config
   }
   再删 profile.homeURL
   ```
4. 返回 `true` 当且仅当 `commitConfig` 成功。

**Acceptance criteria**

- 模拟 env 写失败：重启后该账号仍不在列表；无「内存回魂」。
- 删当前账号：active 落到 first，env 尽力更新。
- 删除后 usages 无已删 id；若有 inflight refresh，写回被忽略。

**Effort**: M

---

### Step 6 — Usage refresh generation 与 ghost 防护（P0-4）

**Files**

- `Sources/GrokSwitch/ProfileStore.swift` — `refreshUsage` / `performUsageRefresh` / `deleteProfile` / 可选 `deinit`

**Concrete changes**

1. 添加 `usageRefreshGeneration`。
2. `refreshUsage`：cancel + bump generation + 新 Task 捕获 gen。
3. `performUsageRefresh(force:generation:)`：
   - 入口设 `isRefreshingUsage = true`
   - 每个 await 后检查 gen / cancelled
   - 写 usages 前校验 profile 仍在 `config.profiles`
   - 结束时仅 `if generation == usageRefreshGeneration { isRefreshingUsage = false }`
4. `deleteProfile` 使用 cancel+bump（Step 5）。
5. 可选：`switchTo` 不必 cancel 全量 refresh，但写回过滤已足够。

**Acceptance criteria**

- 快速连点「刷新」：按钮不会在第二次仍进行时提前亮起（isRefreshingUsage 不闪 false）。
- 刷新中删除账号：不会出现已删 id 的 usage 条目；菜单无异常。

**Effort**: S–M

---

### Step 7 — `showEmailInMenuBar` 默认对齐（P0-6）

**Files**

- `Sources/GrokSwitch/Models.swift` — `init(from:)` 与可选常量
- 确认 `ProfileStore.seed*` 与 `.empty` 已为 false（只读校验）

**Concrete changes**

1. `showEmailInMenuBar = try c.decodeIfPresent(...) ?? false`
2. 提取 `AppConfig.defaultShowEmailInMenuBar = false`，empty/seed/decode 共用（seed 目前手写 false，改为常量更稳）

**Acceptance criteria**

- 去掉 JSON 中该 key 后加载 → false。
- 新 seed → false。
- 显式 `true` 的旧配置 → 仍为 true。

**Effort**: S

---

### Step 8 — （强烈建议同 PR）日期编码稳定 + commit 门闸文案

**Files**

- `Sources/GrokSwitch/ProfileStore.swift` — encoder/decoder 或 `Profile.createdAt` 类型
- `Sources/GrokSwitch/Models.swift` — 若改 `createdAt` 为 `TimeInterval` 需迁移：decode 兼容 Date 与 Double 较烦；**更轻**：自定义 encode/decode `Date` 用固定 formatter 无分秒

**Concrete changes**

- 使用 `ISO8601DateFormatter` with `.withInternetDateTime` only，encode/decode 同一 formatter。
- 与 Step 1 的 unreadable 门闸一起：即使历史坏文件也不 wipe。

**Acceptance criteria**

- 连续启动 10 次不因自身写入导致 decode 失败。
- 损坏文件仍不 seed。

**Effort**: S

---

### Step 9 — 编译与手测收口

**Files / scripts**

- 按仓库 `Agents.md`：改完后 `./scripts/dev-run.sh`
- 必要时更新 `README.md` 一句：配置损坏时不会自动重置；菜单栏短名默认关闭

**Acceptance criteria**

- `dev-run.sh` 编译通过，菜单栏可用。
- 走完下方 verification matrix 主路径。

**Effort**: S

---

## Test / manual verification matrix

| # | 场景 | 操作 | 期望 |
|---|------|------|------|
| T1 | 合法多账号 | 正常启动 | 列表完整，active 正确，env 匹配 |
| T2 | 缺失 config | 删 `~/.grokswitch/config.json` 保留 profiles/ | seed 或导入 default；**不**静默合并全部 orphan（本版可不扫） |
| T3 | 损坏 config | 写入 `{` 或截断 JSON | lastError；**不**写成单 profile；坏文件仍在或 `.corrupt-*` 备份 |
| T4 | switch 保存失败 | 对 config.json chmod a-w 后切换 | 返回 false；UI active 不变；恢复权限后可切 |
| T5 | switch env 失败 | 对 active.env 目录不可写（或 mock） | config active 已变；lastError 提 env；重启 active 保持 |
| T6 | rename 失败 | chmod 后改名 | UI 名不变 |
| T7 | add + activate | 管理页创建账号 | 成为 active；打开终端；config 含新项 |
| T8 | add 失败回滚 | chmod 后创建 | 无新 list 项；无残留空 home（或可接受 orphan 有错误） |
| T9 | delete 唯一账号 | 删最后一个 | false，「至少保留一个」 |
| T10 | delete 当前 + env 失败 | 删 active 且 env 不可写 | 列表已无该账号；重启仍无；lastError |
| T11 | delete 目录失败 | 锁住 profile home | 账号从列表消失；lastError 提目录；return true |
| T12 | 刷新中删除 | 刷新时立刻删某号 | usages 无 ghost key；isRefreshing 结束正确 |
| T13 | 连点刷新 | 多次点刷新 | 仅最后一轮结束时 isRefreshing=false；无崩溃 |
| T14 | showEmail 默认 | 无 key 的旧 JSON | false；Settings toggle 仍可 true 并持久化 |
| T15 | confirmAdd | 创建流程 | 不依赖二次 switch；失败时不清空输入（若 add 失败） |
| T16 | 自写自读 | 添加账号后强杀再开 | 列表与 active 与退出前一致 |

无自动化测试框架时，以上作为 QA checklist；若后续加 test target，优先单测：`ConfigLoadResult` 分支、`slug` 与路径占用、generation 清 flag 逻辑（纯函数可抽离）。

## Risks & rollback

| 风险 | 缓解 |
|------|------|
| unreadable 时拒绝所有写入，用户被锁死 | 错误文案提供：退出 app → 手动移走 corrupt 文件 → 再启动 seed；或后续加「重置配置」按钮（non-goal 可记 follow-up） |
| `addProfile(activate:)` 改签名 | 默认参数 `false` 保持源码兼容；仅 `confirmAdd` 传 true |
| delete 返回 true 但 lastError 非空 | UI 已展示 lastError；确认框仍关闭——需在手测确认不困惑 |
| generation 在 MainActor 上与 Task 交错 | 全部 @MainActor 写回，避免 data race |
| quarantine rename 后用户找不到文件 | rename 到同目录 `config.json.corrupt-<ts>`，lastError 写全路径 |
| 改 Date 编码导致旧 config 失败 | 用兼容 decode：先默认策略，失败再 fallback；或 D1 已防 wipe |

**Rollback**：单 PR 可 git revert；用户侧 config 格式未破（仅 default 语义与安全性）。若做了 corrupt rename，revert app 后用户需手动改回文件名。

## Estimated effort (S/M/L per step)

| Step | 内容 | Effort |
|------|------|--------|
| 1 | load/reload 安全 | **M** |
| 2 | commitConfig + settings/rename | **S–M** |
| 3 | switchTo | **S** |
| 4 | addProfile + confirmAdd | **M** |
| 5 | deleteProfile | **M** |
| 6 | usage generation | **S–M** |
| 7 | showEmail default | **S** |
| 8 | date 稳定（建议） | **S** |
| 9 | dev-run + matrix | **S** |

**合计**：约 **M** 体量（1 个专注 PR，约 0.5–1 人日含手测）。

## Suggested PR split (if this area alone)

**推荐单 PR：`fix: ProfileStore state safety (config/load, commit, usage generation)`**

覆盖 Step 1–7 + 9；Step 8 可同 PR（小）。

若需拆分：

1. **PR-A（紧急）**：Step 1 + 8 — 停止 wipe（最高优先级数据安全）
2. **PR-B**：Step 2–5 + 7 — mutation/commit/delete/add UI
3. **PR-C**：Step 6 — usage generation（可独立测）

依赖：PR-B 依赖 PR-A 的 `commitConfig` 门闸（unreadable 不写）；PR-C 可与 B 并行但 delete 取消 refresh 在 B/C 交界，**更建议 A+B+C 合一** 减少中间态。

---

## Implementation notes (quick reference for implementer)

### 关键函数目标契约

| 函数 | 成功后内存 | 成功后磁盘 config | 失败后内存 | env |
|------|------------|-------------------|------------|-----|
| `switchTo` | active=目标 | 同左 | 不变 | 尽力；失败不回滚 config |
| `addProfile` | 含新 profile；（activate 时 active） | 同左 | 不变；清新建空目录 | 仅 active 需要时 |
| `renameProfile` | 新名 | 同左 | 旧名 | 无 |
| `deleteProfile` | 无该 id | 无该 id | commit 失败则不变 | wasActive 时尽力写 fallback |
| `reload` unreadable | 不 seed、不覆盖 | 不动原文件 | 保持/empty 但不写 | 不写 |

### `confirmAdd` 与 store 接口

- **需要**：`addProfile(name:activate: true)` 或 `addAndActivateProfile(name:)`，一次事务内创建+激活。
- **不要**：`add` 成功 + 忽略 `switchTo` 结果 + 仍 `openTerminal` 假装成功。
- `openTerminal(for:)` 在 activate 成功后调用；若仅 env 失败仍可打开终端（GROK_HOME 可由 launcher 直接注入——与 active.env 无关），但应让用户看见 lastError。

### 不修改的公共行为（回归）

- 至少保留一个 profile。
- atomic write config。
- 用量 10 分钟定时、5 分钟 freshness。
- Shell hook best-effort。
- 删目录失败只警告。

---

## Traceability (issues → steps)

| P0 Issue | Steps |
|----------|--------|
| 1 Corrupt → seed overwrite | 1, 8 |
| 2 Mutate before save no rollback | 2, 3, 4, 7 |
| 3 delete save OK + env fail rollback | 5 |
| 4 usage cancel / ghost | 5, 6 |
| 5 confirmAdd ignores switchTo | 4 |
| 6 showEmail default mismatch | 7 |
