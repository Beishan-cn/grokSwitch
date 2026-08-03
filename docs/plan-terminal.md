# Plan: Terminal launch reliability

## Goals / Non-goals

### Goals

1. **可靠启动**：对支持 CLI 的终端，真正在新窗口/标签里跑  
   `export GROK_HOME=…; exec <grok-binary> [--cwd …]`，而不是“只打开了 app 壳子”。
2. **诚实反馈**：打开失败、静默回退、cwd 被丢弃、仅 best-effort 时，UI **不得**一律显示“已用 X 打开…”。
3. **统一启动管线**：把“解析 app / 解析可执行文件 / 跑 Process / open 回退 / 临时脚本”收成可复用 helper，Otty 的 CLI `Process` 路径作为范本。
4. **修复 PATH 解析**：`resolveGrokBinary()` 不要在 macOS GUI 受限 PATH 下误用 `/usr/bin/env grok`，导致用户装了 grok 仍 `command not found`。
5. **清理临时文件与错误传播**：Hyper/Tabby 的 temp script 路径要可失败、可清理、不偷偷改用 Terminal。

### Non-goals

- 不为每个终端实现完整 TUI 自动化（AppleScript 键入、Accessibility 打字等）。
- 不改 ShellHook 的 GROK_HOME 注入语义（新 shell 仍靠 `~/.zshrc` + `active.env`）。
- 不强制用户安装某一款终端；Terminal.app 仍是默认与最终兜底。
- 不在本 PR 引入 SPM/Xcode project（`build.sh` 改进为可选、低优先级）。
- 不保证 Warp / Hyper / Tabby 与 iTerm 同等可靠——它们标记为 **best-effort**，但 UX 必须说清楚。

---

## Root-cause snapshot（当前代码）

| 问题 | 现状（`TerminalLauncher` / `Paths` / `ProfileStore`） |
|------|--------------------------------------------------------|
| Hyper/Tabby | `openViaTempScript`：`open -na App --args -e /bin/zsh <tmp>`（这两款不认 `-e`）；失败时 `NSWorkspace.open(tmp)` 落到 **Terminal**；**从不 throw**；tmp `.command` **不清理**。 |
| Warp/Kitty/`open --args` | `open -na … --args …` 在已运行实例上常 **吞掉 argv**；`open` 退出码 0 ≠ 命令被执行。 |
| cwd 静默丢弃 | `cwdArgument` 路径无效时返回 `""`；`openTerminal` 仍用 `preferredProjectPath` 拼成功文案。 |
| grok 二进制 | 候选失败 → `/usr/bin/env` + 命令里 `exec grok`；`zsh -lc` **非交互 login**，通常 **不读 `.zshrc`**，GUI 进程 PATH 又极短。 |
| Ghostty/WezTerm | 走 `openWithOpenArgs`，未优先 `Contents/MacOS/*` 直接 `Process`（Otty 已证明更稳）。 |
| build.sh | `arm64` only；`SOURCES=(…)` 手写列表易漏文件。 |

---

## Per-terminal strategy matrix

图例：

- **Primary**：首选实现
- **Fallback**：主路径失败时
- **Reliability**：expected / good / best-effort
- **cwd**：是否可靠附带 `--cwd`（经 grok 参数，而非终端自己的 cwd flag）

| Terminal | Primary | Fallback | Reliability | Notes / argv shape |
|----------|---------|----------|-------------|--------------------|
| **Terminal** | AppleScript `do script` | throw | expected | 保持现状；需 Automation 权限。 |
| **iTerm2** | AppleScript `create window` + `write text` | throw | expected | 保持现状；需 Automation 权限。 |
| **Ghostty** | Direct `Process` → `App/Contents/MacOS/ghostty`（或 bundle 内可执行名）`["-e", "/bin/zsh", "-lic", command]` | `open -na … --args` 同参；再失败 throw | good | 优先二进制，避免 `open` 吞 args。 |
| **Otty** | 已有：`otty-cli open --command … --quiet` | throw `appNotFound` / `processFailed` | expected | **参考实现**；可抽 `runProcess(executable:args:)`。 |
| **Warp** | Best-effort：`open -na Warp` **不传不可靠的 `--args` 命令**；可选尝试官方/文档化 CLI（若存在 `warp` 且支持 run） | 若必须跑 grok：可选“用 Terminal 执行并提示”，或仅激活 Warp + shell hook | best-effort | 当前 `["--", "/bin/zsh", "-lc", command]` 经 `open` **不可靠**；不要假成功。 |
| **Alacritty** | Direct binary `Contents/MacOS/alacritty` `["-e", "/bin/zsh", "-lic", command]` | `open --args` 同参 | good | `-e` 语义清晰。 |
| **Kitty** | Direct binary `Contents/MacOS/kitty` `["/bin/zsh", "-lic", command]`（或 `["-e", …]` 若版本需要） | `open --args` | good | **禁止依赖** `open --args` 作为主路径。 |
| **WezTerm** | Direct binary：优先 `Contents/MacOS/wezterm`（CLI）`["start", "--", "/bin/zsh", "-lic", command]`；若只有 `wezterm-gui` 再适配 | `open --args` 同参 | good | 与 issue #6 一致：prefer `Process`。 |
| **Hyper** | **不**用假 `-e`；`open -na Hyper`（或 activate）+ **诚实 best-effort 文案**（GROK_HOME 靠 hook，需用户手动 `grok`） | 用户可选：设置里“不支持自动启动时回退 Terminal”（默认 off 或 on 需产品定） | best-effort | 删除/重写 `openViaTempScript` 对该 app 的误用。 |
| **Tabby** | 同 Hyper：activate only + 诚实文案；若发现 `tabby` CLI 可执行且支持 run，再升级为 good | 可选 Terminal 回退（显式） | best-effort | Bundle `org.tabby`；勿 `NSWorkspace.open(.command)` 静默换 Terminal。 |

### Shared command shape

- 始终尽量解析出 **绝对路径** 的 grok 二进制，命令：  
  `export GROK_HOME='…'; exec '/path/to/grok'[ --cwd '…']`
- 仅在绝对路径不可得时，才用 login+interactive shell 做 PATH 查找（见下）。
- Shell 建议：`/bin/zsh -lic`（login **且** interactive），以便读到 `.zprofile` + `.zshrc` 里的 PATH（Homebrew、nvm 等）。比当前 `-lc` 更接近用户日常终端。

### Launch capability tiers（实现用 enum，不必暴露给用户 rawValue）

```text
.scriptedAppleEvent   // Terminal, iTerm2
.directCLI            // Otty, Ghostty, Alacritty, Kitty, WezTerm
.bestEffortOpenOnly   // Hyper, Tabby, (Warp 若无可靠 CLI)
```

`open()` 返回或内部产出 `LaunchResult`（成功级别 + 可选 warning），供 `ProfileStore` 生成文案。

---

## Implementation steps

### Step 1 — 结果模型与错误语义（小、先做）

**文件**：`TerminalLauncher.swift`，必要时 `ProfileStore.swift`

1. 扩展 `LaunchError` 或新增非抛出的结果类型，例如：

   ```text
   enum LaunchOutcome {
     case launched                    // 命令已交给目标终端
     case launchedWithWarning(String) // 打开了终端，但 cwd/自动跑 grok 等有折扣
     case bestEffort(String)          // 仅打开 app / 依赖 hook
   }
   ```

2. `open(…) throws -> LaunchOutcome`（或 `open` 仍 void + 通过 out-param；推荐带返回值）。
3. **禁止**“catch 后 open Terminal 且不 throw/不 warning”。

### Step 2 — 通用 Process / 可执行文件解析

**文件**：`TerminalLauncher.swift`（对齐 Otty）

1. `runProcess(executable: URL, arguments: [String], label: String) throws`  
   - 捕获 stderr、非 0 退出 → `LaunchError.processFailed`  
   - 统一 null stdout 或有限 stderr 缓冲  
2. `resolveAppExecutable(_ app: TerminalApp) -> URL?`  
   - `resolvedAppURL()` + `Contents/MacOS/<候选名>`  
   - 候选表：`ghostty`, `alacritty`, `kitty`, `wezterm`, `wezterm-gui`, app 名等；`isExecutableFile`  
3. `openWithDirectBinary(app:args:) throws`：有 binary 则 `runProcess`；否则再 `openWithOpenArgs`  
4. `openWithOpenArgs`：保留作 fallback；**成功仅表示 open(1) 返回 0**，对 best-effort 终端不要单独当作“已执行 command”。

### Step 3 — 按终端改写 `open(profile:terminal:projectPath:)`

| Case | 改动 |
|------|------|
| terminal / iTerm2 | 不变（可改用 `-lic` 的 command 字符串若需要） |
| ghostty / alacritty / kitty / wezTerm | 改走 `openWithDirectBinary` + 上表 argv |
| otty | 继续 CLI；可迁到 `runProcess` |
| warp | 去掉不可靠 `--args` 主路径；`LaunchOutcome.bestEffort` + 说明 |
| hyper / tabby | 删除有效的假 `-e` 路径；`NSWorkspace.open(appURL)` 或 `open -na` **无 args**；outcome = bestEffort |

### Step 4 — 重写 / 收敛 `openViaTempScript`

**文件**：`TerminalLauncher.swift`

1. 若仍保留 temp script（例如“显式回退到 Terminal 跑 .command”）：  
   - 写 `#!/bin/zsh` + command  
   - `chmod 700`  
   - **仅** `NSWorkspace.open(tmp)` 交给 LaunchServices（`.command` → Terminal）  
   - **defer / 延迟删除**：`DispatchQueue.global().asyncAfter(2–5s)` 删 tmp，或脚本末尾 `rm -- "$0"`  
2. **不要**对 Hyper/Tabby 传 `-e`。  
3. 若调用方要“回退 Terminal”，必须：  
   - 用户设置允许，或  
   - outcome/warning 写明「已用 Terminal 代替 Hyper」  
4. 默认建议：**best-effort 终端不自动换 Terminal**，避免“设置里选了 Hyper 却弹出 Terminal”的困惑。

### Step 5 — `cwdArgument` 与 UI 对齐

**文件**：`TerminalLauncher.swift`, `ProfileStore.swift`（可选 `MenuBarView` 副标题）

1. 将 `cwdArgument` 改为显式结果，例如：

   ```text
   enum CwdResolution {
     case none
     case applied(flag: String)      // " --cwd '…'"
     case invalid(path: String)      // 配置了但目录不存在/非目录
   }
   ```

2. `open` 在 `invalid` 时：仍可启动 grok（无 `--cwd`），但 `LaunchOutcome.launchedWithWarning("项目路径无效，已忽略：…")`。  
3. `ProfileStore.openTerminal`：  
   - 成功文案仅在 `applied` 或用户未设置项目时带项目名  
   - `invalid` / `bestEffort` 写入 `statusMessage` 或 `lastError`（warning 用 status、失败用 lastError；或统一 status 橙色——保持现有双通道即可）  
4. 可选：设置页 / 菜单在路径失效时显示“路径不可用”（`FileManager` 检查），与扫描列表刷新一致。

### Step 6 — `resolveGrokBinary` 加固

**文件**：`Paths.swift`（解析逻辑可留在 Paths；launch 侧决定 `-lic`）

1. **扩大候选**（仍只接受 `isExecutableFile`）：  
   - `~/.grok/bin/grok`（已有）  
   - `/usr/local/bin/grok`, `/opt/homebrew/bin/grok`（已有）  
   - `~/.local/bin/grok`  
   - 可选：`/opt/homebrew/opt/...` 不必过度  
2. **禁止**把 `/usr/bin/env` 当作“已解析二进制”静默 `exec grok`。改为：  
   - **A（推荐）**：用一次探测进程解析绝对路径：

     ```text
     /bin/zsh -lic 'command -v grok'
     ```

     读 stdout，校验可执行后缓存（进程内静态缓存即可）。  
   - **B**：若探测失败，launch 命令用  
     `export GROK_HOME=…; command -v grok >/dev/null && exec grok …`  
     或在 TerminalLauncher 层 throw：`找不到 grok，请安装 Grok CLI 或检查 PATH`。  
3. GUI app 的 `Process` 环境可设置：

   ```text
   PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:…
   ```

   作为探测时的 **最小补强**（不能替代用户自定义 PATH，故仍要 `-lic`）。  
4. 命令拼装：`binary.lastPathComponent == "env"` 分支删除或收窄为“仅探测失败时的显式错误”。

### Step 7 — UX 文案（与 Step 1/5 一起落地）

见下一节「UX messaging」。涉及：

- `ProfileStore.openTerminal`  
- 设置 footer（`GrokSwitchApp` 终端 Section）  
- 菜单终端选择旁：best-effort 标注（可选）

### Step 8 — `build.sh`（可选、低优先级，可拆 PR）

**文件**：`scripts/build.sh`

1. 架构：`ARCH=$(uname -m)` → `arm64-apple-macos14.0` / `x86_64-apple-macos14.0`；或 `lipo` 双架构（成本更高，MVP 用 host arch 即可）。  
2. 源列表：`SOURCES=("$ROOT"/Sources/GrokSwitch/*.swift)` 或 `find` 排序，避免漏文件。  
3. 不改变 `dev-run.sh` 入口语义。

### Step 9 — 验证与文档

1. 按下方 Verification matrix 手工过一遍（至少 Terminal + 一种 directCLI + 一种 best-effort）。  
2. README「注意」补一句：Warp/Hyper/Tabby 为尽力支持；Ghostty/Kitty/WezTerm/Alacritty/Otty 走 CLI。  
3. 按 `Agents.md`：改完后 `./scripts/dev-run.sh` 编译重启。

### Suggested code structure (no patch, target shape)

```text
TerminalLauncher.open
  ├─ resolve command (Paths.resolveGrokBinary + CwdResolution)
  ├─ switch terminal
  │    ├─ AppleScript paths
  │    ├─ Otty CLI
  │    ├─ openWithDirectBinary (ghostty/alacritty/kitty/wezterm)
  │    └─ openBestEffortApp (warp/hyper/tabby)
  └─ return LaunchOutcome

Paths.resolveGrokBinary
  ├─ fixed candidates
  └─ zsh -lic 'command -v grok' (+ short PATH seed)
```

---

## UX messaging for best-effort terminals

### 原则

1. **Process/open 抛错** → `lastError = "打开终端失败：…"`（保持）。  
2. **App 打开了但未保证执行 grok** → **不要**用与 iTerm 相同的“已用 X 打开：账号 · 项目”。  
3. **cwd 无效** → 警告，不假装已带项目。  
4. **静默换 Terminal** → 禁止；若产品要回退，必须写明。

### 推荐文案（简体中文）

| 场景 | 建议 `statusMessage` / `lastError` |
|------|-------------------------------------|
| 可靠启动 + 有效项目 | `已用 iTerm2 打开：工作 · my-repo`（现有） |
| 可靠启动 + 无项目 | `已用 Ghostty 打开：工作`（现有） |
| 可靠启动 + 配置了项目但路径无效 | `已用 Ghostty 打开：工作（项目路径无效，已忽略）` |
| Warp/Hyper/Tabby best-effort | `已打开 Warp。该终端无法可靠自动启动 grok，请在窗口内运行 grok（GROK_HOME 已由 shell hook 提供）。` |
| 找不到 grok 二进制 | `lastError`：`找不到 grok 可执行文件。请安装 Grok CLI，或确认 ~/.grok/bin/grok 与 PATH。` |
| app 未安装 | 现有：`找不到终端应用「…」，请在设置中更换` |
| 用户显式允许回退 Terminal（若实现） | `「Hyper」无法自动启动命令，已改用 Terminal 打开 Grok。` |

### 设置 / 菜单提示

- 终端 Section footer 补充：  
  **「Terminal、iTerm2、Otty、Ghostty、Alacritty、Kitty、WezTerm 支持一键启动 grok；Warp / Hyper / Tabby 为尽力支持（打开应用，需手动运行 grok）。」**
- 终端 picker 行（可选）：best-effort 显示为 `Warp（尽力）`。  
- 默认项目路径失效时，副标题或 caption：`路径不存在`（避免 openGrokSubtitle 仍显示文件夹名造成误解）。

### `openTerminal` 伪逻辑

```text
outcome = try TerminalLauncher.open(...)
switch outcome {
case .launched:
  status = 标准成功文案（仅当 cwd applied 才带项目名）
case .launchedWithWarning(let w):
  status = 标准成功 + "（\(w)）"
case .bestEffort(let detail):
  status = detail   // 不用“已用 X 打开：账号 · 项目”模板
}
```

---

## Verification matrix (manual)

环境：已安装 grok；至少一个 profile 已 login；Automation 权限按需点允许。

| # | 终端 | 前置 | 操作 | 期望 |
|---|------|------|------|------|
| 1 | Terminal | 默认 | 打开 Grok，无项目 | 新窗口执行 grok；`GROK_HOME` 为当前 profile；status 成功 |
| 2 | Terminal | 有效默认项目 | 打开 Grok | grok 带 `--cwd`；status 含项目名 |
| 3 | Terminal | 默认项目改为已删路径 | 打开 Grok | 仍启动 grok；**无** `--cwd`；status **警告**路径无效 |
| 4 | iTerm2 | 已装 | 同上 1–2 | 新窗口 + 命令；非 Terminal 窗口 |
| 5 | Otty | 已装 | 打开 Grok | `otty-cli` 成功；失败时 lastError 含 stderr |
| 6 | Ghostty | 已装 | 打开 Grok | **不依赖**已运行实例吞 args；新窗跑 grok |
| 7 | Alacritty | 已装 | 打开 Grok | 同 direct binary |
| 8 | Kitty | 已装；Kitty 已在跑 | 打开 Grok | 仍新开并执行（验证不再只靠 `open --args`） |
| 9 | WezTerm | 已装 | 打开 Grok | `wezterm start -- …` 类行为；grok 起来 |
| 10 | Warp | 已装 | 打开 Grok | App 前台；**status 为 best-effort 文案**；不假称已 exec grok；不弹错 Terminal |
| 11 | Hyper | 已装 | 打开 Grok | 同 10；**无**残留 `grokswitch-*.command` 或短时清理 |
| 12 | Tabby | 已装 | 打开 Grok | 同 10–11 |
| 13 | 任意 | 临时移走所有 grok 候选 | 打开 Grok | **失败** lastError 找得到 grok；不是空窗 `command not found` 装成功 |
| 14 | 任意 | grok 仅在 `.zshrc` PATH（不在固定候选） | 打开 Grok | 探测或 `-lic` 能解析并启动 |
| 15 | 设置 | 选未安装终端 | 打开 | `appNotFound` 文案 |
| 16 | build（可选） | Intel 或 `uname -m` | `./scripts/build.sh` | 产物 arch 匹配 host；新增 swift 文件无需手改列表 |

回归：账号切换、ShellHook、`dev-run.sh` 编译启动不受影响。

---

## Effort + PR split

| PR | 范围 | 预估 | 风险 |
|----|------|------|------|
| **PR1 — Core reliability** | Step 1–4：`LaunchOutcome`、direct binary、Otty 式 `runProcess`、重写 Hyper/Tabby/Warp、temp script 清理与错误传播 | **M**（0.5–1 天） | 中：各终端 argv 需真机点验 |
| **PR2 — cwd + binary PATH** | Step 5–6：`CwdResolution`、UI 文案、`resolveGrokBinary` 探测与去掉假 env | **S–M**（数小时） | 低–中：zsh 探测在沙箱/权限下的边界 |
| **PR3 — UX copy + settings** | Step 7：footer、picker「尽力」、README | **S** | 低；可与 PR1 合并 |
| **PR4 — build.sh**（可选） | Step 8：host arch + glob sources | **XS** | 低 |

### 推荐落地顺序

1. **PR1+PR2 合并为一个 “terminal launch reliability” PR**（用户痛点都在启动链）若希望单次验收。  
2. 若要减小 diff：先 PR1（不再假成功 / 不再错落到 Terminal），再 PR2（cwd 与 grok 路径）。  
3. PR4 独立，避免与启动逻辑耦合。

### 实现时注意

- 全程 **简体中文** 用户可见字符串（与仓库一致）。  
- 每改完跑 **`./scripts/dev-run.sh`**（`Agents.md`）。  
- 不在 `openWithOpenArgs` 把 stderr 丢弃后仍当成功——至少对 direct `Process` 保留 stderr。  
- WezTerm 可执行名可能是 `wezterm` 或 `wezterm-gui`：解析时按候选列表探测。  
- Ghostty 参数以已安装版本为准；若 `-e` 无效，查 `ghostty +show-config` / 帮助后微调，但结构保持 “direct binary first”。

---

## Critical files for implementation

- `Sources/GrokSwitch/TerminalLauncher.swift` — 主改动：策略矩阵、Process、temp script、cwd 结果  
- `Sources/GrokSwitch/Paths.swift` — `resolveGrokBinary` 候选与 zsh 探测  
- `Sources/GrokSwitch/ProfileStore.swift` — `openTerminal` 按 `LaunchOutcome` / cwd 生成 status  
- `Sources/GrokSwitch/GrokSwitchApp.swift` / `MenuBarView.swift` — 设置 footer、副标题、best-effort 标注  
- `scripts/build.sh` — 可选：arch + 源文件列表  

---

## Summary

当前启动链的核心矛盾是：**把 `open(1)` 退出码和“配置了项目”当成业务成功**，同时对 Hyper/Tabby 使用错误的 `-e` 并静默回退 Terminal，对 Warp/Kitty 等依赖不可靠的 `--args`，以及对 grok 使用不读 `.zshrc` 的 `env` 回退。修复方向是：**CLI 型终端直连 bundle 可执行文件（Otty 模式）**、**best-effort 终端诚实打开 + 明确文案**、**cwd/二进制解析失败可观测**、临时脚本可清理且不偷偷换应用。
