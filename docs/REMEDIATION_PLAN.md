# Master Fix Plan: GrokSwitch

> 范围：基于已知 review 的 P0 / P1 / P2 交叉交付序列。  
> 约束：改码后跑 `./scripts/dev-run.sh` 编译并重启验证。  
> 原则：安全优先、小 PR、不制造行为惊喜。无实现代码，仅排序与边界。

---

## Principles (safety first, small PRs, no behavior surprise)

1. **数据完整性 > 功能完整 > 体验抛光**  
   任何可能 wipe config、腐蚀 `~/.zshrc`、或留下「内存与磁盘不一致」的改动，必须先于终端/UI 美化。

2. **小 PR、单主题**  
   每个 PR 一个可独立 review 的安全/正确性主题；避免「顺手改 UI + 改存储」混装。ProfileStore 热点文件用**串行**，其它文件尽量并行。

3. **先不破坏，再变好**  
   - 损坏配置：只读保护 / 备份 / 报错，**禁止**落到 empty 后再 seed 写盘。  
   - Shell hook：marker 异常时 **no-op + 报错**，不半截替换。  
   - 终端启动：打不开就明确失败，禁止「app 已打开 = 成功」。

4. **无行为惊喜**  
   - 默认值统一（如 `showEmailInMenuBar`）时，在 PR 说明里写清「老用户 decode 默认 vs 新建默认」的迁移选择。  
   - 产品行为变更（创建后是否自动 switch / open terminal）保持现状意图，只修 bug（忽略失败返回值等），不借修 bug 改产品语义。

5. **验证纪律**  
   每个 PR 落地后：`./scripts/dev-run.sh` + 本 PR 专属回归条目；整条系列结束再跑全量 checklist。

6. **热点文件所有权**  
   - `ProfileStore.swift`：PR-1 → PR-2 → PR-3 → PR-5 串行（可同一 agent 连续做）。  
   - `ShellHook.swift`、`TerminalLauncher.swift`、`AuthReader.swift` / `UsageFetcher.swift`、UI 文件：与存储串行线可并行，但合并前做一次冲突检查。

---

## PR DAG (ordered list PR-1…PR-N with dependencies, files, what lands)

```
PR-1 (config load safety)
  └─► PR-2 (atomic mutate / rollback / delete+env consistency)
        └─► PR-3 (active.env escape + homePath constrain)
              └─► PR-5 (usage cancel / ghost usage)   [也可紧接 PR-2，若与 PR-3 无文件冲突可并行]

PR-4 (ShellHook replaceBlock)     ── 独立，可与 PR-1 后任意时刻并行

PR-6 (Auth + gRPC correctness)    ── 独立，建议与 PR-4/7 并行
PR-7 (Terminal + cwd + PATH)      ── 独立
PR-8 (UI defaults / drafts / ScrollView / confirmAdd)
                                  ── 依赖 PR-2 的 switch/add 语义稳定；可与 PR-6/7 并行

PR-9 (P2 polish batch)            ── 依赖 P0 全部 + 建议 P1 主体已合
PR-10 (docs + release notes)      ── 最后；依赖 PR-9 或与 PR-9 尾部合并
```

### PR-1 — Config 损坏不 wipe（P0）
| 项 | 内容 |
|----|------|
| **Deps** | 无（系列地基） |
| **Files** | `Sources/GrokSwitch/ProfileStore.swift`（`loadConfig` / `reload` / `seedDefaultProfileFromExistingGrokHome`）；必要时 `Paths.swift`（quarantine 路径） |
| **Lands** | decode/读盘失败时：**不**返回可被 seed 写盘的 empty；保留/备份损坏文件；`lastError` 明确；仅当**确认无配置文件**时才 first-run seed。禁止 `reload` 在「corrupt → empty → profiles.isEmpty → seed → save」路径上覆盖用户数据。 |
| **DoD** | 手工：把 `config.json` 写成非法 JSON / 半截 JSON → 启动后原文件仍在（或旁路 `.corrupt` 备份），profiles 不被 default 覆盖；合法 empty/first-run 仍可 seed。 |
| **Risk** | 过高保护导致「真·空配置」无法初始化——用「文件不存在」vs「文件存在但坏」分支区分。 |

### PR-2 — 内存提交顺序 + 删除/写 env 一致性（P0）
| 项 | 内容 |
|----|------|
| **Deps** | PR-1 |
| **Files** | `ProfileStore.swift`（`switchTo` / `addProfile` / `renameProfile` / `deleteProfile` / setters / `saveConfig` / `writeActiveEnv`） |
| **Lands** | **copy-mutate-save-commit**：先在副本上改，save 成功再赋给 `@Published config`；save 失败不改 UI 状态。`deleteProfile`：磁盘 config 与 `active.env` / active 切换同事务语义——`saveConfig` 成功后 `writeActiveEnv` 失败时不得「内存回滚但盘上已删」；应重试写 env、或保持已提交状态并 `lastError` 要求用户手动 reload/switch，且**不**假装删除失败。env 失败与目录删除失败的用户文案分开。 |
| **DoD** | 模拟 save 失败（权限）→ UI 与磁盘一致；删除后打断 env 写 → 无「列表已删但 active.env 仍指旧 home」的静默态，或有明确错误+可恢复路径。 |
| **Risk** | 与 PR-1 同文件；必须在 PR-1 合并后 rebase。 |

### PR-3 — `active.env` 转义 + `homePath` 约束（P0）
| 项 | 内容 |
|----|------|
| **Deps** | PR-2（写 env / 路径规范化已稳定） |
| **Files** | `ProfileStore.swift`（`writeActiveEnv`）；`Models.swift` / `Paths.swift`（校验辅助）；可选加载时 normalize |
| **Lands** | `GROK_HOME` 值 shell 安全转义（与 `TerminalLauncher.shellEscape` 同策略，可抽共享 helper）。`homePath` 限制在应用管理的 profiles 根下（或显式允许的安全前缀），拒绝 `..`、意外绝对路径逃逸；加载时发现非法路径 → 标记错误，不写危险 `active.env`。 |
| **DoD** | 路径含空格/引号/`$` 时 `source active.env` 仍正确；构造越界 homePath 时拒绝切换/写入。 |
| **Risk** | 过度约束可能伤到「用户手改 homePath」的高级用法——默认只允许 `Paths.profilesRoot` 下；若需例外单独 flag，本系列不做。 |

### PR-4 — ShellHook `replaceBlock` 陷阱（P0）
| 项 | 内容 |
|----|------|
| **Deps** | 无（可与 PR-1 后并行） |
| **Files** | `ShellHook.swift`；错误上浮时 `ProfileStore` 仅透传 status（尽量少碰） |
| **Lands** | marker 缺失/乱序/嵌套/多段时安全行为：不替换或只替换**唯一**合法 pair；写盘前校验结果仍含完整 begin/end；失败返回 false 且可观测（不要静默腐蚀 `~/.zshrc`）。已安装且内容不变 → 仍 false/no-op。 |
| **DoD** | 手工构造缺 end marker / 双 begin 的 `.zshrc` 片段 → 文件内容不变；正常安装与刷新仍工作。 |
| **Risk** | 用户手改 hook 块——以 marker 为唯一权威，文档在 PR-10 说明。 |

### PR-5 — Usage 刷新 cancel / `isRefreshing` 竞态 + 删除后幽灵用量（P0）
| 项 | 内容 |
|----|------|
| **Deps** | PR-2（删除与 map 生命周期清晰）；与 PR-3 无硬依赖，但建议 PR-3 后合以减少 ProfileStore 冲突 |
| **Files** | `ProfileStore.swift`（`refreshUsage` / `performUsageRefresh` / `deleteProfile`）；可能 `UsageModels.swift` |
| **Lands** | 刷新 generation / task id：cancel 后旧 task 不得写 `usages`、不得把 `isRefreshingUsage` 误清/误留。`defer { isRefreshing = false }` 仅由**当前** generation 执行。删除 profile 后立即 drop 该 id 的 usage/identity；进行中的 fetch 结果若 id 已不在 `config.profiles` 则丢弃。 |
| **DoD** | 连点刷新 + 删除账号：无幽灵 %、无卡死「刷新中…」、无已删 id 的 usage 回流。 |
| **Risk** | TaskGroup 取消语义；保持 MainActor 一致性。 |

### PR-6 — Auth 语义 + gRPC 帧（P1）
| 项 | 内容 |
|----|------|
| **Deps** | 无；与 PR-4/5/7 可并行 |
| **Files** | `AuthReader.swift`；`UsageFetcher.swift`；轻微 `UsageModels.swift` / identity 展示 |
| **Lands** | **gRPC-web**：不完整 frame / 截断 payload 明确失败，不半解析。**OIDC/过期**：`isExpired` 优先于「当作已登录去打 usage」；过期展示 expired，不误走 ready。**decode 失败**：有 `auth.json` 但 decode 失败 ≠「未登录」文案；区分 notFound / decodeFailed / missingTokens / expired。 |
| **DoD** | 坏 auth、过期 token、截断响应：UI 文案可区分；合法 token 用量仍成功。 |
| **Risk** | 文案变化用户可见——保持中文一致风格，不改菜单结构。 |

### PR-7 — 终端启动可靠 + `--cwd` + PATH / zsh -lc（P1）
| 项 | 内容 |
|----|------|
| **Deps** | 无；与 PR-6/8 可并行 |
| **Files** | `TerminalLauncher.swift`；`ProfileStore.openTerminal` 错误透传；`scripts/build.sh` 仅当本 PR 需触及 arm64 说明时（否则留给 PR-9） |
| **Lands** | **Hyper / Tabby / Warp / Kitty**：真实检测启动失败；禁止「open 了 app 但未注入 GROK_HOME/command」却 status 成功。无法可靠 exec 的终端：明确降级文案（依赖 shell hook）或禁用为 preferred 并提示。**`--cwd`**：非法/不存在路径不静默吞掉——校验后省略并 warning，或失败。**PATH / `zsh -lc`**：login shell 与 PATH 中 `grok` 解析策略与 `Paths.resolveGrokBinary` 对齐，避免「菜单成功、壳里 command not found」。 |
| **DoD** | 各 TerminalApp：已装/未装矩阵；无效 project path 有可见反馈；Kitty/Warp 至少不再假成功。 |
| **Risk** | 各终端 CLI 差异大——优先正确失败，不追求 100% 注入。 |

### PR-8 — UI / 默认值 / 草稿一致性（P1）
| 项 | 内容 |
|----|------|
| **Deps** | PR-2（`switchTo`/`addProfile` 返回值可信）；`showEmail` 默认与 Models 一并定案 |
| **Files** | `MenuBarView.swift`（`confirmAdd`）；`GrokSwitchApp.swift`（rename drafts、ScrollView、设置）；`Models.swift`（`showEmailInMenuBar` empty vs decode 默认统一） |
| **Lands** | **confirmAdd**：`switchTo` 失败则不假装成功、不盲目 `openTerminal`（或仅 open 且错误可见）。**Settings rename draft**：外部 rename/delete/reload 后 draft map 与列表同步，无脏草稿。**showEmailInMenuBar**：`AppConfig.empty` / seed / `decodeIfPresent` 默认统一（建议统一为产品意图：菜单栏默认紧凑 → `false`，与 empty/seed 一致；改 decode 默认时写清「缺字段老配置」行为）。**ScrollView**：账号/设置过长可滚动，不裁切。 |
| **DoD** | 创建失败/switch 失败路径；重命名中删除该账号；缺字段 config 解码默认与 UI Toggle 一致；多账号列表可滚。 |

### PR-9 — P2 抛光批（可再拆 2 个小 PR 若并行人力足够）
| 项 | 内容 |
|----|------|
| **Deps** | PR-1…PR-5 必须；PR-6…PR-8 强烈建议已合 |
| **Files** | `ProfileStore`/`Paths`（file perms 0600/0644 策略）；`ShellHook`（multi-shell 若做 bash 仅 opt-in）；`TerminalLauncher`（AppleScript 换行转义）；`UsageFetcher`（URLSession ephemeral）；`MenuBarIcon.swift`（宽度跳动）；`GrokSwitchApp`/`MenuBarView`（panel focus）；`Models` ProjectScanner（limits）；`scripts/build.sh`（arm64 说明/文档化，非盲目 universal） |
| **Lands** | 配置与 `active.env` 权限收紧；会话 ephemeral 减少磁盘 cookie 痕迹；图标/焦点/扫描上限防卡顿；AppleScript 多行 command 安全；扫描深度/数量上限；构建目标文档化（当前 `arm64-apple-macos14.0`——不在本系列强行加 x86_64，除非明确需求）。 |
| **DoD** | 无 P0 回归；P2 项可逐条勾选，允许「文档化 wontfix」但需在 PR-10 记录。 |

### PR-10 — 文档与系列收口
| 项 | 内容 |
|----|------|
| **Deps** | PR-9 或与 PR-9 同 PR 尾部 |
| **Files** | `README.md`；必要时 `Agents.md` 无冲突补充 |
| **Lands** | active.env / zshrc marker / 损坏配置恢复步骤；终端支持矩阵与降级说明；默认值变更说明；验证命令 `./scripts/dev-run.sh`。 |
| **DoD** | README 与真实行为一致。 |

---

## What can parallelize

| 并行组 | PR | 说明 |
|--------|----|------|
| **A 存储串行线** | PR-1 → PR-2 → PR-3 → PR-5 | 同一 `ProfileStore.swift`，单 agent 连续最稳 |
| **B Hook** | PR-4 | 与 A 在 PR-1 合并后全程并行 |
| **C Auth/Usage 协议** | PR-6 | 与 A/B/D 并行；避免同时大改 ProfileStore usage 编排时与 PR-5 撞车——若一人做，PR-5 先于 PR-6 合并 usage 相关 |
| **D 终端** | PR-7 | 与 B/C/E 并行 |
| **E UI** | PR-8 | PR-2 合并后启动；与 C/D 并行 |
| **F 抛光** | PR-9 可拆：perms+session / UI chrome / scanner+docs | 仅 P0/P1 主干合并后 |

**多人建议最大并行度：**  
- 人 1：A 线（PR-1…3…5）  
- 人 2：PR-4 + PR-7  
- 人 3：PR-6 + PR-8（PR-2 后开 PR-8）  
- 收口：任一人 PR-9 + PR-10  

**单人建议：** 严格按 PR-1…PR-10 顺序，PR-4 可在 PR-2 等待编译时插入。

---

## What must not ship without the other

| 捆绑 | 原因 |
|------|------|
| **PR-1 不得单独「只报错仍 seed」半吊子** | 半修复仍可能 wipe；要么完整保护，要么不发布该路径。 |
| **PR-2 的 delete 回滚 与 writeActiveEnv 失败处理** | 只修 memory-before-save 不修 env 序，删除路径仍 desync。 |
| **PR-3 转义 与 homePath 约束** | 只转义不约束，仍可能指向危险路径；只约束不转义，合法路径仍可破 shell。 |
| **PR-5 cancel 与 ghost-after-delete** | 同属 usage map 生命周期；拆开会再引入竞态。 |
| **PR-6 过期判断 与 usage 跳过过期** | Auth 标 expired 但 fetcher 仍打 RPC → 噪音/错误状态。 |
| **PR-7 假成功修复 与 statusMessage 文案** | UI 仍显示「已打开」会抵消 launcher 修正。 |
| **PR-8 `showEmailInMenuBar` Models 默认 与 Settings Toggle 初始** | 只改一侧会「设置项与菜单栏表现反相」。 |
| **PR-4 与任何「确保 hook 已安装」的静默假设** | PR-4 失败变多后，调用方应容忍 false，不在本系列改成强制崩溃。 |
| **不要先发 PR-9 perms 收紧再发 PR-1** | 权限变更可能掩盖/干扰损坏配置恢复测试。 |

**可独立热修上线（若生产已在丢数据）：** 仅 PR-1，其后 48h 内必须跟 PR-2。

---

## Suggested subagent assignment per PR (implementer scope)

| PR | Subagent 角色 | 范围边界（禁止越界） |
|----|---------------|----------------------|
| **PR-1** | **Storage-Safety Implementer** | 只动 load/reload/seed/quarantine；不改 delete 事务、不改 UI。测：坏 JSON / 无文件 / 好文件。 |
| **PR-2** | **Store-Transaction Implementer** | 统一 save 事务与 delete/env；不改 ShellHook 算法、不改 gRPC。测：权限失败、删除唯一账号拒绝、删除 active。 |
| **PR-3** | **Env-Path Harden Implementer** | `writeActiveEnv` + path validate；可抽 `shellEscape` 到共享处但勿重写 TerminalLauncher 行为。 |
| **PR-4** | **ShellHook Implementer** | 仅 `ShellHook.swift`（+ 必要测试说明）；禁止「顺手」改 zsh 以外 shell（留给 P2）。 |
| **PR-5** | **Usage-Concurrency Implementer** | generation/cancel/ghost；不改 fetch 协议细节（PR-6）。 |
| **PR-6** | **Auth-RPC Implementer** | `AuthReader` + `UsageFetcher` 解析与错误映射；不改 ProfileStore 调度（只消费现有 API）。 |
| **PR-7** | **Terminal-Launcher Implementer** | `TerminalLauncher` + openTerminal 错误串；不改 menu 布局。 |
| **PR-8** | **UI-Consistency Implementer** | MenuBarView / GrokSwitchApp / Models 默认值；不改存储事务。 |
| **PR-9** | **Polish Implementer**（可拆 2 agent） | 按文件切片；每切片独立 `./scripts/dev-run.sh`。 |
| **PR-10** | **Docs Implementer** | 只文档；行为以已合并代码为准。 |
| **每 PR 后** | **Reviewer（Fable 5）** | 对照本 plan DoD +「must not ship without」；拒收跨主题大包。 |

模型约定（项目规则）：实现与 review 均用 **Fable 5**，不为省 token 降级。

---

## Milestone definition of done

### M0 — 止血（PR-1 + PR-2）
- [ ] 损坏 `config.json` 不会被 default seed 覆盖  
- [ ] 任意 profile 写操作：save 失败则 UI 与磁盘一致  
- [ ] 删除账号：无「盘上已删、内存回滚」或「config 已改、active.env 仍指死者」的静默分裂  
- [ ] `./scripts/dev-run.sh` 通过  

### M1 — 环境面 P0 闭合（PR-3 + PR-4 + PR-5）
- [ ] `active.env` 对特殊字符安全；非法 homePath 不落盘  
- [ ] 畸形 zshrc marker 不被 replaceBlock 破坏  
- [ ] 刷新取消/删除后无幽灵 usage、无卡住 isRefreshing  
- [ ] M0 回归仍绿  

### M2 — 正确性 P1（PR-6 + PR-7 + PR-8）
- [ ] Auth/过期/decode/gRPC 截断语义正确  
- [ ] 终端矩阵无假成功；坏 cwd 可感知  
- [ ] confirmAdd / rename draft / showEmail 默认 / ScrollView 达标  
- [ ] M0+M1 回归仍绿  

### M3 — 抛光与发布（PR-9 + PR-10）
- [ ] P2 清单关闭或文档化 wontfix  
- [ ] README 与行为一致  
- [ ] 全量 Regression checklist 通过  
- [ ] 系列可打 tag / 发布说明（若项目需要）  

---

## Regression checklist for whole series

### 配置与档案
- [ ] 首次启动（无 config）→ 创建 default / 从 `~/.grok` 导入  
- [ ] 合法多账号：切换 / 重命名 / 创建 / 删除（非最后一个）  
- [ ] 拒绝删除最后一个账号  
- [ ] 损坏 config → 不 wipe；修复/恢复后可再用  
- [ ] save 失败（只读目录模拟）→ 无脏 UI  

### 环境与 Shell
- [ ] 切换后 `~/.grokswitch/active.env` 指向正确 GROK_HOME  
- [ ] `source active.env` 在路径含空格时可用  
- [ ] `~/.zshrc` hook 安装一次、升级块不重复追加  
- [ ] 损坏 marker 的 zshrc 不被写坏  
- [ ] 新开 zsh 看到预期 `GROK_HOME`  

### 用量与登录态
- [ ] 已登录：用量显示 / 手动刷新 / 定时刷新  
- [ ] 刷新中再次刷新：最终状态一致，无死「刷新中」  
- [ ] 刷新中删除该账号：无幽灵用量  
- [ ] 未登录 / 过期 / 坏 auth.json：文案区分正确  
- [ ] 网络/截断 gRPC：错误态，不崩溃  

### 终端与项目
- [ ] Terminal / iTerm2 / 其它已装终端：打开带正确 GROK_HOME  
- [ ] 未装终端：明确错误  
- [ ] Hyper/Tabby/Warp/Kitty：无假成功  
- [ ] 有效 `--cwd` / 无效路径反馈  
- [ ] `grok` 不在非 login PATH 时仍有合理行为或明确错误  

### UI / 设置
- [ ] 创建账号：switch 失败时不误导  
- [ ] 设置中重命名 draft 与列表同步；删除编辑中账号无残 draft  
- [ ] `showEmailInMenuBar` / `showUsageInMenuBar` 与菜单栏标题一致（含缺字段旧配置）  
- [ ] 多账号时列表可滚动  
- [ ] 菜单栏图标/标题无严重跳动（P2）  

### 构建
- [ ] `./scripts/dev-run.sh` 每次改码后成功  
- [ ] `scripts/build.sh` 在目标架构（arm64）产出可开 app  

### 回归禁区（全程不得引入）
- [ ] 不写 exploit / 不弱化权限到「世界可写 config」  
- [ ] 不默认改用户产品工作流（如取消创建后打开终端——除非修的是错误处理）  
- [ ] 不在未备份情况下重写整个 `~/.zshrc`  

---

## 执行节奏建议（solo）

| Day | 产出 |
|-----|------|
| 1 | PR-1 + PR-2（M0） |
| 2 | PR-3 + PR-4 + PR-5（M1） |
| 3 | PR-6 + PR-7（M2 半） |
| 4 | PR-8 + 全量 P0/P1 回归 |
| 5 | PR-9 + PR-10（M3）+ 系列 checklist |

每 PR：`实现 → ./scripts/dev-run.sh → 专属 DoD → review → merge → rebase 下一条`。

---

## PR 一览（one-liners）

1. **PR-1** — 损坏 config 只读保护，禁止 empty-seed 写盘 wipe  
2. **PR-2** — Profile 变更 copy-mutate-save；删除与 active.env 同事务语义  
3. **PR-3** — active.env shell 转义 + homePath 限制在 profiles 根  
4. **PR-4** — ShellHook replaceBlock 畸形 marker 安全 no-op  
5. **PR-5** — Usage 刷新 generation/cancel；删除后无幽灵 usage  
6. **PR-6** — Auth 过期/decode 语义 + gRPC 不完整帧失败  
7. **PR-7** — 终端真失败/真成功；cwd 校验；PATH/zsh -lc 对齐  
8. **PR-8** — confirmAdd/switchTo、rename draft、showEmail 默认、ScrollView  
9. **PR-9** — P2：perms、session、图标焦点、扫描上限、AppleScript、构建说明  
10. **PR-10** — README/恢复与终端矩阵文档收口  

---

*本文件为 master sequencing plan；实现阶段按 PR 切片开 PR，勿一次混交 M0–M3。*
