# GrokSwitch

macOS 菜单栏工具：用官方 `GROK_HOME` 隔离多 Grok 账号，一键切换。

## 功能（MVP）

- 菜单栏显示 **Grok 图标 + 剩余用量**（如 `99%`）；可选在无用量时显示账号短名
- 账号列表旁显示各 profile 的剩余额度与重置时间
- 点击切换账号（更新 active `GROK_HOME`）
- 新开 **zsh** 终端自动生效（写入 `~/.zshrc` hook + `~/.grokswitch/active.env`）
- 用当前账号打开终端并启动 `grok`（可选择 Terminal / iTerm2 / Ghostty / Otty / Warp 等）
- 添加新账号 profile（打开终端后 `grok login`）
- 首次启动从现有 `~/.grok` 导入默认账号
- 用量：用各账号 `auth.json` 的 Bearer 调用 grok.com 账单接口（与 CodexBar 同源），约每 10 分钟自动刷新

## 原理

```bash
# 每个账号独立 home
GROK_HOME=~/.grokswitch/profiles/personal grok
GROK_HOME=~/.grokswitch/profiles/work     grok
```

Grok 官方支持 `GROK_HOME` 覆盖配置目录；各 home 内 `auth.json` / `config.toml` / `sessions` 互不干扰。

二进制解析顺序（与 auto_update 装进 `$GROK_HOME/bin` 对齐）：

1. **当前 profile 的** `$GROK_HOME/bin/grok`（内部 installer 更新目标）
2. 共享的 `~/.grok/bin/grok` 与常见固定路径
3. login shell 的 `command -v grok`

`active.env` 会同时 `export GROK_HOME` 并把 `$GROK_HOME/bin` 前置到 `PATH`，避免「更新装进了 profile，日常启动仍走 `~/.grok/bin` 旧版」。

## 要求

- macOS 14+ **Apple Silicon (arm64)**
- 已安装 [Grok Build CLI](https://x.ai/cli)
- Xcode Command Line Tools / Swift 5.9+

## 构建与运行

```bash
./scripts/dev-run.sh   # 开发：编译并重启
# 或
./scripts/run.sh       # 同上
./scripts/build.sh
open .build/GrokSwitch.app
```

安装到应用程序：

```bash
./scripts/build.sh
cp -R .build/GrokSwitch.app /Applications/
```

## 目录布局

```
~/.grokswitch/
  config.json       # profile 列表与当前激活 id（权限 0600）
  active.env        # export GROK_HOME + PATH 前置 $GROK_HOME/bin（shell 安全转义）
  profiles/
    default/        # 导入的默认账号
    work/           # 你添加的其它账号
```

`~/.zshrc` 中会自动加入（应在官方 `>>> grok installer >>>` 块**之后**，以便覆盖其 PATH）：

```bash
# >>> grokswitch >>>
# GrokSwitch: apply active GROK_HOME + profile bin PATH for new shells (zsh only)
if [ -f "$HOME/.grokswitch/active.env" ]; then
  . "$HOME/.grokswitch/active.env"
fi
# <<< grokswitch <<<
```

`active.env` 示例：

```bash
export GROK_HOME='/Users/you/.grokswitch/profiles/default'
export PATH='/Users/you/.grokswitch/profiles/default/bin':"$PATH"
```

### bash / fish

自动 hook **仅支持 zsh**。其它 shell 请在配置中手工：

```bash
# bash: ~/.bash_profile 或 ~/.bashrc
[ -f "$HOME/.grokswitch/active.env" ] && . "$HOME/.grokswitch/active.env"
```

```fish
# fish: ~/.config/fish/conf.d/grokswitch.fish
if test -f $HOME/.grokswitch/active.env
  source $HOME/.grokswitch/active.env
end
```

## 使用流程

1. 启动 GrokSwitch（菜单栏出现 Grok 图标）
2. 首次运行会导入当前 `~/.grok` 登录态为「默认」
3. **添加账号** → 输入名称 → 自动打开终端 → 运行 `grok login`
4. 之后在菜单里点选即可切换
5. **新开 zsh 终端** 后 `echo $GROK_HOME` 应指向当前 profile；`which grok` 应优先解析到 `$GROK_HOME/bin/grok`（若该 profile 已有 bin）

已打开的终端不会自动变账号，请重开或：

```bash
source ~/.grokswitch/active.env
```

### 版本「更新了但还是旧版」

`installer = "internal"` 时，自动更新装进**当前** `$GROK_HOME/bin`，不会改写 `~/.grok/bin`。若 shell 仍优先 `~/.grok/bin`，会看起来像没更新。GrokSwitch 通过 `active.env` 前置 profile `bin` 修复这一点。可自检：

```bash
which -a grok
echo "GROK_HOME=$GROK_HOME"
grok --version
"$GROK_HOME/bin/grok" --version   # 若该 profile 有 bin
```

### 设置入口

菜单栏图标 → **设置…**（本应用为菜单栏 agent，不一定出现在「系统设置」列表中）。

### 终端支持

| 终端 | 启动 grok 命令 |
|------|----------------|
| Terminal / iTerm2 | 可靠（AppleScript） |
| Ghostty / Otty / Alacritty / Kitty / WezTerm | 可靠（直接启动二进制） |
| Warp / Hyper / Tabby | 尽力而为：仅打开应用；依赖 shell hook 的 `GROK_HOME` + profile `bin` PATH，需手动 `grok` |

## 配置损坏恢复

若 `~/.grokswitch/config.json` 损坏，应用**不会**用空配置覆盖它，并会显示错误。

1. 查看 / 备份：`~/.grokswitch/config.json`
2. 修复 JSON，或删除该文件后重启以重新 seed（账号目录 `profiles/*` 可能仍在，需手动对照恢复列表）
3. 菜单中点「刷新账号与用量」

## 注意

- **不要**把 `~/.grok` 做成指向 profile 的软链接：Grok sandbox 会拒绝 symlink 形式的 `$GROK_HOME`。
- profile 的 `homePath` 必须位于 `~/.grokswitch/profiles/<id>`；手改 config 指向其它路径会被拒绝。
- 首次用 Terminal / iTerm2 打开 Grok 时，macOS 可能询问「自动化 / 控制该终端」权限，请允许。
- 本工具读取 `auth.json` 中的 email / 名字用于展示，并用其中的 access token 向 grok.com 查询用量；凭证不会上传到第三方。
- 查询用量前，若 access token 即将过期/已过期且存在 `refresh_token`，会向官方 OIDC 端点 `https://auth.x.ai/oauth2/token` 做**标准 refresh**（与 Grok CLI 同类），并写回该 profile 的 `auth.json`。不会调用其它非公开接口，也不会启动 `grok` 进程代为续期。
- 团队账号可能无法查询个人用量（接口限制）；若 refresh 失败（例如 `invalid_grant`）或没有 refresh_token，需在对应 profile 下重新 `grok login`。

## 许可

MIT
