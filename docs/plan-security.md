# Plan: Security & shell integration

## Goals / Non-goals

### Goals

1. **P0 — `writeActiveEnv` shell injection**：`active.env` 中 `GROK_HOME` 值经 shell 转义后再写入，路径中的 `"`、`$`、`` ` ``、换行等无法打断 `export` 语句。
2. **P0 — profile `homePath` 约束**：`loadConfig` / `deleteProfile` / `writeActiveEnv` / 打开终端前，校验 `homePath` 规范化后严格位于 `Paths.profilesRoot` 之下，拒绝路径穿越与任意目录删除/读取。
3. **P0 — `ShellHook.replaceBlock` 安全**：要求 `beginMarker` 位置 **严格早于** `endMarker`；非法块不改写 `~/.zshrc`；安装失败可观测（不再静默忽略）。
4. **P1 — 敏感目录/文件权限**：`~/.grokswitch` 树与 `auth.json` / `config.json` / `active.env` 强制合理权限（目录 `0700`，敏感文件 `0600`）。
5. **P1 — AppleScript 转义**：`escapeForAppleScript` 处理换行与其它会破坏字符串字面量的控制字符。
6. **P1 — 多 shell 文档/策略**：明确当前只装 zsh；文档说明 bash/fish 手工方案；代码注释与 UI 文案对齐，不为本 PR 强行实现多 shell。

### Non-goals

- 不实现 bash/fish/nu 的自动 hook 安装（可后续 PR）。
- 不改 macOS Keychain / 加密 `auth.json`（范围过大）。
- 不引入完整 sandbox 或代码签名 hardening 变更。
- 不重写 `TerminalLauncher` 启动策略（仅共享 escape 与 path 校验）。
- 不引入新的第三方依赖或测试框架（无现成 unit test target 时以手工/脚本验证为主；若后续加 SPM test target 再补单测）。

---

## Design decisions

### D1. 统一 `shellEscape` 位置

| 选项 | 说明 |
|------|------|
| A. 留在 `TerminalLauncher` private | 现状；`ProfileStore` 无法复用 |
| **B. 抽到共享 helper（推荐）** | 新建 `ShellEscape.swift` 或放在 `Paths.swift` 旁的 `ShellQuoting.swift`，供 `writeActiveEnv` 与 `TerminalLauncher` 共用 |
| C. 扩展 `Paths` | 职责混淆，路径与 quoting 无关 |

**决定：B** — 单一实现，避免 `active.env` 用双引号半转义、启动命令用单引号两套逻辑漂移。

**转义语义（与现有 `TerminalLauncher.shellEscape` 一致）**：POSIX 单引号形式  
`'` + `value.replacingOccurrences(of: "'", with: "'\\''")` + `'`  
写入 `active.env` 时使用：

```text
export GROK_HOME='…escaped…'
```

而不是当前的双引号插值（`export GROK_HOME="\(homePath)"`）。

### D2. `homePath` 校验策略

- **规范化**：`expandingTildeInPath` → `URL(fileURLWithPath:).standardizedFileURL`（解析 `.` / `..`，不跟随 symlink 到 profiles 外也可接受；若需更严可用 `resolvingSymlinksInPath`，但要注意用户把 profile 目录本身 symlink 出去的边界——**推荐：先 `standardizedFileURL`，再要求 path 以 `profilesRoot.standardizedFileURL.path + "/"` 为前缀，且不等于 root 本身**）。
- **合法源**：仅 `Paths.profileHome(id:)` 生成的路径；`id` 已由 `slugify` 限制为 alphanumerics/`-`/`_`，降低 `../` 注入 id 的风险，但仍要在 load 时防御手改 `config.json`。
- **非法时行为**：
  - `loadConfig`：丢弃该 profile 或整配置回退 `.empty` + `lastError`（**推荐：过滤非法 profile 并设 `lastError` 提示「配置中存在非法 homePath，已忽略」**；若 active 被滤掉则选第一个合法 profile 并重写 env）。
  - `deleteProfile`：若 `homePath` 非法，**只从 config 移除条目，绝不 `removeItem`**；`lastError`/`statusMessage` 说明未删磁盘。
  - `writeActiveEnv` / `openTerminal`：校验失败则 throw / 设 error，不写 env、不启动。
- **不迁移**：不自动把越界 path「纠正」到 `profilesRoot`（避免误伤）；用户需删坏配置或重建 profile。

### D3. `replaceBlock` 与 hook 安装返回值

- 增加 `startRange.lowerBound < endRange.lowerBound`（或 `upperBound` 在 begin 之后）检查；失败返回 `nil`。
- 可选加强：若 begin 出现多次或 end 在 begin 前，视为损坏块，**不追加第二份 hook**（避免双 hook）；可返回明确错误 enum。
- `ensureInstalled` 今日多处 `try?` / 忽略 `Bool`。**最小改动**：
  - `replaceBlock` 失败且 markers 存在但顺序错乱时：返回 `false`，并让 `ProfileStore` 在 switch/reload 时把失败写到 `lastError`（需 `ensureInstalled` 改为返回 `Result` 或 `(Bool, Error?)`）。
  - **推荐 API**：`enum InstallResult { case alreadyUpToDate, modified, failed(String) }`，`ProfileStore` 在 `switchTo` / `reload` 中非 `alreadyUpToDate`/`modified` 时设置 `lastError`（reload 可用 status，避免弹过多）。

### D4. 文件权限

| 路径 | 权限 |
|------|------|
| `~/.grokswitch`、`profiles/`、各 `profileHome` | `0700` |
| `config.json`、`active.env` | `0600` |
| 各 profile 下 `auth.json`（创建/复制/检测到时） | `0600` |

实现：`Paths` 或 `ProfileStore` 内 `func ensureSecurePermissions()`：

1. `createDirectory` 后 `setAttributes([.posixPermissions: 0o700], …)`。
2. 每次 `saveConfig` / `writeActiveEnv` 写完后设 `0600`。
3. `seedDefaultProfileFromExistingGrokHome` 复制 `auth.json` 后设 `0600`。
4. `reload`/`bootstrap` 时对已存在树做一次 best-effort chmod（不递归扫 sessions 全树也可；至少 root + config + active.env + 各 profile 的 `auth.json`）。

注意：`Data.write(options: .atomic)` / `String.write(atomically:)` 可能产生默认 umask 权限，**必须在 write 之后**再 `setAttributes`。

### D5. AppleScript 转义

在现有 `\` 与 `"` 替换之外，处理：

- `\n` → `\n`（字面反斜杠-n，或拒绝含换行的 command）
- `\r` 同理
- 可选：其它控制字符直接 reject

**推荐**：换行/回车转义为 AppleScript 可接受的形式，使 `do script "…"` / `write text "…"` 不会因嵌入换行而闭合字符串并注入后续语句。  
`command` 本身由内部 `shellEscape` 拼出，正常路径无换行；防御的是 profile path / binary path 被篡改后的二次注入。

与 shell escape 一起可放在 `ShellQuoting.swift`：`shellSingleQuoted` + `appleScriptStringLiteral`。

### D6. 仅 zsh — 文档 vs 多 shell

- **代码**：`ShellHook` 顶部注释写明「MVP: zsh only (`~/.zshrc`)」。
- **README + Settings 文案**（`GrokSwitchApp.swift` 已有 zsh 说明）：增加「bash/fish 用户需手工 source `~/.grokswitch/active.env`」示例。
- **不**在本 PR 写 `~/.bashrc` / `config.fish`，避免半吊子多文件损坏风险。

---

## Implementation steps (ordered, files, acceptance criteria)

### Step 1 — 共享 quoting helper

**Files**

- 新建 `Sources/GrokSwitch/ShellQuoting.swift`（名称可微调）
- 改 `Sources/GrokSwitch/TerminalLauncher.swift`：删除 private `shellEscape` / `escapeForAppleScript`，改为调用共享 API

**Work**

1. `ShellQuoting.shellSingleQuoted(_ value: String) -> String`（现有单引号算法）。
2. `ShellQuoting.appleScriptEscaped(_ value: String) -> String`：`\`、`"`、换行、回车。
3. `TerminalLauncher` 全部替换调用点。

**Acceptance**

- 路径含 `'`、`"`、空格时，打开终端命令仍正确。
- 含换行的字符串经 AppleScript escape 后不会在源码中产生未转义换行。

---

### Step 2 — `writeActiveEnv` 使用 shell 单引号

**Files**

- `Sources/GrokSwitch/ProfileStore.swift`（`writeActiveEnv`）

**Work**

1. 将  
   `export GROK_HOME="\(homePath)"`  
   改为  
   `export GROK_HOME=\(ShellQuoting.shellSingleQuoted(homePath))`  
   （或先校验 path 再 escape）。
2. 写文件后设 `0600`（可与 Step 4 合并）。

**Acceptance**

- 手工把 profile home 改成含 `"; malicious; "` 的路径时，若仍通过校验（见 Step 3 应拦截），`active.env` 中值为完整单引号字面量，`zsh -c 'source active.env'` 不会执行额外命令。
- 正常 path（无特殊字符）行为与现网一致：`echo $GROK_HOME` 指向 profile。

---

### Step 3 — `homePath` 必须在 `profilesRoot` 下

**Files**

- `Sources/GrokSwitch/Paths.swift` — 增加校验 API
- `Sources/GrokSwitch/ProfileStore.swift` — `loadConfig`、`deleteProfile`、`writeActiveEnv`、必要时 `openTerminal` 入口
- 可选：`TerminalLauncher.open` 入口再 assert 一次 defense-in-depth

**Work**

1. 在 `Paths` 增加例如：

   - `static func isPathInsideProfilesRoot(_ path: String) -> Bool`
   - `static func validatedProfileHome(path: String) throws -> URL`  
     规范化后：存在或不存在均可（delete 前可能已不存在），但 path 字符串必须在 root 下；拒绝 `profilesRoot` 自身、拒绝 `../`、拒绝前缀假匹配（用 `"/"` 边界，不要用裸 `hasPrefix(root)` 导致 `/profiles` vs `/profiles-evil`）。

2. `loadConfig`：expand tilde 后 filter；记录 ignored 数量；修正 `activeProfileID`。

3. `deleteProfile`：仅当 `isPathInsideProfilesRoot` 为真且 path 非 root 时才 `removeItem`。

4. `writeActiveEnv`：非法则 `throw`。

5. `addProfile` / seed：继续只用 `Paths.profileHome(id:)`，保证写入 config 的 path 合法。

**Acceptance**

- `config.json` 中 `homePath: "/tmp/evil"` 或 `~/.grokswitch/profiles/foo/../../.ssh`：load 后该 profile 不可用或被丢弃；不会删 `~/.ssh`；不会把 `GROK_HOME` 指到外部。
- 正常 `~/.grokswitch/profiles/default` 行为不变。
- 删除合法 profile 仍删除对应目录。

---

### Step 4 — 权限 0700 / 0600

**Files**

- `Sources/GrokSwitch/Paths.swift` 或 `ProfileStore.swift`（`ensureDirectories` 扩展）
- `ProfileStore.saveConfig`、`writeActiveEnv`、`seedDefault…`、`addProfile` 创建目录处

**Work**

1. `ensureDirectories`：创建 + chmod root / profilesRoot。
2. 写 config / active.env 后 chmod `0600`。
3. 新建 profile 目录 `0700`；复制/存在 `auth.json` 时 `0600`。
4. `reload` 时 best-effort 加固已有文件。

**Acceptance**

- 新装后：`stat -f '%Lp' ~/.grokswitch` → `700`；`config.json` / `active.env` → `600`。
- 新建账号后对应 profile 目录 `700`，login 后若 app 再次 touch 权限，`auth.json` 为 `600`（若 grok CLI 自己写宽权限，app 下次 reload 应收紧——best-effort）。

---

### Step 5 — `ShellHook.replaceBlock` + 安装结果可观测

**Files**

- `Sources/GrokSwitch/ShellHook.swift`
- `Sources/GrokSwitch/ProfileStore.swift`（调用方处理失败）

**Work**

1. `replaceBlock`：  
   - 找不到 marker → `nil`  
   - `start >= end`（begin 不在 end 之前）→ `nil`  
   - 可选：end 必须在 begin 同一逻辑块内（当前按 first match 即可）
2. 当 text 同时含 begin/end 但 `replaceBlock` 返回 `nil`：`ensureInstalled` **不要**再 append 新块；返回 failure。
3. 写 `~/.zshrc` 失败：返回 failure，不再仅 `try?` 吞掉（至少 failure 路径有字符串）。
4. `ProfileStore.switchTo` / `addProfile` / delete 激活切换：若 hook 失败，在成功写 config/env 后设置 `lastError` 或合并 warning（「账号已切换，但未能更新 ~/.zshrc」）。

**Acceptance**

- 构造 `~/.zshrc` 内容为 `endMarker` 在前、`beginMarker` 在后：再次 `ensureInstalled` **不截断/不损坏**文件，不插入第二份完整 hook（或明确失败且文件字节不变）。
- 正常已安装 hook：refresh 后块内容等于当前 `hookBlock`，文件其余部分不变。
- 无 hook 的 zshrc：末尾追加一块且仅一块。

---

### Step 6 — AppleScript 换行（与 Step 1 同一 helper）

**Files**

- `ShellQuoting.swift` + `TerminalLauncher` 调用点（已在 Step 1）

**Acceptance**

- 单元级：输入 `foo\nbar` 与 `say "hi"`，输出中无裸换行，`"` 与 `\` 已转义。
- 回归：Terminal.app / iTerm2 打开当前 profile 仍能启动 grok。

---

### Step 7 — 文档与 UI：仅 zsh

**Files**

- `README.md`（shell 集成章节）
- `Sources/GrokSwitch/GrokSwitchApp.swift`（Settings 说明段落）
- `ShellHook.swift` 文件头注释

**Work**

1. 明确「自动安装仅限 zsh（`~/.zshrc`）」。
2. bash 示例：`echo 'source ~/.grokswitch/active.env' >> ~/.bashrc`（或 login 场景 `.bash_profile`）。
3. fish 示例：`source ~/.grokswitch/active.env` 在 conf.d 中需注意 POSIX `export` 与 fish `set -x` 不兼容——**文档应写**：`active.env` 为 POSIX sh；fish 用户可 `bass` 或手工 `set -x GROK_HOME ~/.grokswitch/profiles/...`。避免承诺 fish 兼容 `active.env`。

**Acceptance**

- README 读者能判断「我用 fish 时 app 不会改我的 config」以及如何手动生效。
- Settings 文案与 README 一致。

---

### Step 8 — 验证脚本 / 手工清单

**Files**

- 可选：`scripts/security-smoke.sh`（只读检查 + 临时目录模拟，不强制）
- 必做：改完后按 `Agents.md` 跑 `./scripts/dev-run.sh`

**Acceptance** 见下一节。

---

## Shared helpers (e.g. shellEscape location)

| Helper | Location | Consumers |
|--------|----------|-----------|
| `shellSingleQuoted(_:)` | `Sources/GrokSwitch/ShellQuoting.swift` | `ProfileStore.writeActiveEnv`、`TerminalLauncher`（GROK_HOME、binary、cwd） |
| `appleScriptEscaped(_:)` | 同上 | `TerminalLauncher.openInTerminalApp` / `openInITerm` |
| `isPathInsideProfilesRoot` / `validatedProfileHome` | `Paths.swift` | `ProfileStore` load/delete/writeEnv；可选 `TerminalLauncher` |
| `chmod` wrappers（`secureDir` / `secureFile`） | `Paths.swift` 或 `ProfileStore` private | ensureDirectories、saveConfig、writeActiveEnv、seed、addProfile |
| `ShellHook.InstallResult` | `ShellHook.swift` | `ProfileStore` 所有 `ensureInstalled` 调用点 |

保持 helper **无 UI、无 AppKit**（`ShellQuoting` / path 校验纯 Foundation），便于日后抽测。

---

## Test / verification

### 自动化（若无 test target，用 zsh 一次性脚本在临时目录）

1. **shellEscape 等价表**（Swift 打印或脚本对照）：

   | input | expected idea |
   |-------|----------------|
   | `/safe/path` | `'/safe/path'` |
   | `a'b` | `'a'\''b'` |
   | `"; rm -rf /; "` | 整段单引号包住，无未闭合引号 |

2. **active.env 注入**：临时写 env 后 `zsh -c 'source …; echo OK'`，确认无副作用命令执行（可用 path 含 `$(touch /tmp/pwned)` 的字符串；source 后 `/tmp/pwned` 不存在）。

3. **path 边界**：

   - `profilesRoot/foo` → ok  
   - `profilesRoot/../config.json` → reject  
   - `/tmp/x` → reject  
   - `profilesRoot` 自身 → reject  

4. **replaceBlock**：begin/end 颠倒、缺失 end、正常 refresh。

### 手工（`./scripts/dev-run.sh` 后）

1. 切换账号 → `cat ~/.grokswitch/active.env` 为单引号形式 → 新开终端 `echo $GROK_HOME` 正确。
2. 打开 Terminal / iTerm2 启动 grok 仍可用。
3. `ls -ld ~/.grokswitch`、`ls -l ~/.grokswitch/config.json ~/.grokswitch/active.env` 权限正确。
4. 添加 / 删除账号不误删 profiles 外路径。
5. Settings/README 文案检查。

### 回归注意

- `seedDefaultProfileFromExistingGrokHome` 仍从 `~/.grok` **读** auth（路径固定，不在 profilesRoot 校验范围内）；写入 dest 必须在 profiles 下。
- `preferredProjectPath` 仍可在 home 外（项目目录），**不要**误用 profilesRoot 校验到 project path。

---

## Risks

| Risk | Mitigation |
|------|------------|
| 过严 path 校验误伤已有手改 `homePath` 的用户 | load 时 filter + 明确 `lastError`；README 说明 profile home 必须在 `~/.grokswitch/profiles/` |
| chmod 与 atomic write 竞态 / 其它进程改权限 | write 后 chmod；reload 时 best-effort；不保证对抗恶意并发 |
| `replaceBlock` 更严后部分「半损坏」zshrc 不再自动修复 | 失败可见；用户可手动删 marker 后让 app 重装 |
| 单引号 `active.env` 与旧双引号并存 | 每次 switch/reload 重写 active.env，自然收敛 |
| fish 用户误 source POSIX `export` 文件 | 文档明确 fish 不兼容；不自动改 fish 配置 |
| AppleScript 过度转义导致命令变字面量错误 | 仅转义 `\ " \n \r`；用真实 Terminal 点一次回归 |
| `standardizedFileURL` 与 symlink 边界 | 文档：profile 目录勿 symlink 到敏感树外；校验用 path 前缀而非实时 ACL |

---

## Effort + PR suggestion

### Effort

| 块 | 估时 |
|----|------|
| ShellQuoting + TerminalLauncher 替换 | 0.5–1h |
| writeActiveEnv + path 校验 + delete/load | 1.5–2h |
| ShellHook replaceBlock + InstallResult 接线 | 1h |
| 权限 ensure | 0.5–1h |
| 文档/UI 文案 | 0.5h |
| 手工验证 + dev-run | 0.5–1h |
| **合计** | **约 0.5–1 人日** |

### PR 建议

- **单一 PR**：`fix: harden shell env, profile paths, and zshrc hook`  
  安全项耦合（escape + path + hook + perms），拆 PR 易出现中间态仍可注入。
- 若需拆分：  
  1) P0 escape + path 校验 + writeActiveEnv  
  2) ShellHook + perms + docs  
  但 (1) 应先合。
- PR 描述勾选：injection / path traversal / zshrc corruption / permissions / docs-only multi-shell。
- 合并前必跑：`./scripts/dev-run.sh`（见 `Agents.md`）。

### 实现顺序（开发者清单）

1. `ShellQuoting.swift` + 改 `TerminalLauncher`  
2. `Paths` 校验 API  
3. `ProfileStore.writeActiveEnv` + load/delete 校验 + 权限  
4. `ShellHook` 修复 + `ProfileStore` 处理返回值  
5. README + Settings 文案  
6. `./scripts/dev-run.sh` + 手工清单  

---

## Issue → code map (quick reference)

| # | Issue | Primary site today | Fix |
|---|--------|-------------------|-----|
| 1 | Unescaped `GROK_HOME` in double quotes | `ProfileStore.writeActiveEnv` L489–498 | `shellSingleQuoted` |
| 2 | No `homePath` under `profilesRoot` | `loadConfig` L463–481, `deleteProfile` L246–251, `writeActiveEnv` | `Paths.validatedProfileHome` |
| 3 | `replaceBlock` no begin<end; return ignored | `ShellHook.replaceBlock` L61–77; callers `try?` / `_ =` | order check + `InstallResult` |
| 4 | No 0700/0600 | `ensureDirectories` L459–461; saves | post-write chmod |
| 5 | AppleScript missing newlines | `TerminalLauncher.escapeForAppleScript` L344–348 | shared escape |
| 6 | zsh only | `ShellHook` / README | document, no multi-shell install |
