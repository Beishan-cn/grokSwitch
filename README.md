# GrokSwitch

macOS 菜单栏工具：用官方 `GROK_HOME` 隔离多 Grok 账号，一键切换。

## 功能（MVP）

- 菜单栏显示当前账号短名（如 `G·antony.beishan`）
- 点击切换账号（更新 active `GROK_HOME`）
- 新开终端自动生效（写入 `~/.zshrc` hook + `~/.grokswitch/active.env`）
- 用当前账号打开 Terminal 并启动 `grok`
- 添加新账号 profile（打开终端后 `grok login`）
- 首次启动从现有 `~/.grok` 导入默认账号

## 原理

```bash
# 每个账号独立 home
GROK_HOME=~/.grokswitch/profiles/personal grok
GROK_HOME=~/.grokswitch/profiles/work     grok
```

Grok 官方支持 `GROK_HOME` 覆盖配置目录；各 home 内 `auth.json` / `config.toml` / `sessions` 互不干扰。

二进制仍使用官方安装路径 `~/.grok/bin/grok`（不随 profile 切换）。

## 要求

- macOS 14+
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
  config.json       # profile 列表与当前激活 id
  active.env        # export GROK_HOME=...
  profiles/
    default/        # 导入的默认账号
    work/           # 你添加的其它账号
```

`~/.zshrc` 中会自动加入：

```bash
# >>> grokswitch >>>
if [ -f "$HOME/.grokswitch/active.env" ]; then
  . "$HOME/.grokswitch/active.env"
fi
# <<< grokswitch <<<
```

## 使用流程

1. 启动 GrokSwitch（菜单栏出现 `G·…`）
2. 首次运行会导入当前 `~/.grok` 登录态为「默认」
3. **添加账号** → 输入名称 → 自动打开终端 → 运行 `grok login`
4. 之后在菜单里点选即可切换
5. **新开终端** 后 `echo $GROK_HOME` 应指向当前 profile

已打开的终端不会自动变账号，请重开或：

```bash
source ~/.grokswitch/active.env
```

## 注意

- **不要**把 `~/.grok` 做成指向 profile 的软链接：Grok sandbox 会拒绝 symlink 形式的 `$GROK_HOME`。
- 首次用 Terminal 打开 Grok 时，macOS 可能询问「自动化 / 控制 Terminal」权限，请允许。
- 本工具只读 `auth.json` 中的 email / 名字等展示字段，不会上传任何凭证。

## 许可

MIT
