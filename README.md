# claude-duo-lane · 把 Claude Code 拆成「执行层 + 判断层」

一套 Windows 上的 Claude Code 成本控制方案：便宜的模型干活，贵的模型只在需要判断时按次出场，账本自己算钱。

面向的是这类使用方式：**日常大量读写文件、跑命令、改代码，但真正需要"想"的时刻其实很少。**

---

## 问题

把 Opus 当主会话用，贵的不是回答，是三样东西叠加：

| 成本乘数 | 说明 |
|---|---|
| 上下文长度 × 轮数 | 最大头，和模型无关。一个 40 万 token 的会话，每问一句都要重新读一遍 |
| 模型单价 | Opus 输出 $20/M，Flash 输出 $0.60/M，33 倍 |
| 每次调用的固定开销 | 系统提示 + 技能清单 + MCP 工具定义，实测 63,549 token / 次 |

实测改造前：每天的开销记为 **1.00**（本文下面所有钱都用这个单位，不写绝对金额），每次调用固定开销 63.5k token，Opus 会话中位上下文 44.5 万 token。

## 解决思路

```text
┌─────────────────────────────────────────────────┐
│  执行层（主会话）  DeepSeek V4.1 Flash            │  默认，你就在这
│  ├─ 读文件、改代码、跑命令、写文档                 │
│  ├─ 苦力子代理 scout（haiku 级）                  │  搜代码、批量机械活
│  └─ 卡住了 ──────────────┐                       │
└──────────────────────────┼───────────────────────┘
                           │ 独立进程，一次一个问题，硬预算
┌──────────────────────────▼───────────────────────┐
│  判断层（顾问）  Claude Opus 5.5                  │  2–5 美分/次
│  --bare：不带插件、CLAUDE.md、hooks → 固定开销 1.9k│
│  --max-budget-usd：唯一能真正封顶单次花费的机制    │
└──────────────────────────────────────────────────┘
```

关键点：**一个 Claude Code 进程只能有一个 `ANTHROPIC_BASE_URL`**，所以模型不能在同一会话里跨端点切换。Opus 必须以独立短进程出现——这既是限制，也正好是省钱的地方：顾问拿到的只有你显式指定的问题和文件，没有 40 万历史包袱。

## 效果（实测）

| 项目 | 改造前 | 改造后 |
|---|---|---|
| 主会话固定开销 | 63,549 token | 33,763 token |
| 顾问固定开销 | — | 1,907 token |
| 单次顾问成本 | — | 0.003 – 0.01（单位同上） |
| 压缩触发点 | 98.7 万 token（1M 窗口下等于从不触发） | 14.7 万 |
| 七天总花费（同一使用强度） | — | **0.50**，其中 Opus 占 91%、Flash 占 6%。七天里有一天是改造当天（还带着改造前的旧会话）；改造完成后稳定下来的六天合计 0.06 |

七天 6,800 次调用里 Opus 只有 917 次（主要是改造当天那半天）。**花费结构从「Opus 长会话」变成「Flash 长会话 + 少量 Opus 单次」**——这就是全部收益来源。

## 两条通道

### 1. 默认通道：全自动路由

主会话是 Flash。遇到需要判断的事（根因诊断、架构取舍、判断"这到底是不是缺陷"），它自己调 `opus-consult.ps1`。规则写在 `docs/MODEL_ROUTING.md`，被 `CLAUDE.md` 引入。

### 2. 白名单通道（`duo/`）：只允许两个模型

桌面上另有一个快捷方式，点开就是「只用 Flash + Opus 5.5」的会话，带 `--dangerously-skip-permissions`，且**不影响其他入口**。

做法上的三个实现细节，都是实测确认过的：

- `--settings` 是**叠加**不是替换：base `settings.json` 的 hooks 照常触发，同名 env 键被覆盖。所以 `settings-duo.json` 里不需要复制 token、不需要复制 hooks——换 token 只改一处。
- 把 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` 四个别名全指向 Flash，于是 `/model opus`、`chief` 子代理（`model: opus`）、`scout`（`model: haiku`）在这条通道里**全部悄悄变成 Flash**。这既是白名单的实现方式，也是它最大的陷阱——所以策略文本明确禁止用 `chief` 做判断，判断一律走 `opus-consult.ps1`。
- `--append-system-prompt-file` 是隐藏参数（`claude --help` 只在 `--append-system-prompt[-file]` 的描述里提一句），但可用，用来注入每通道策略而不污染共享的 `CLAUDE.md`。

## 文件

```text
duo/
  claude-duo.ps1        启动器：查代理端口 → 必要时拉起代理 → 起 claude
  settings-duo.json     白名单：四个别名 + ANTHROPIC_MODEL 全部 = Flash
  duo-policy.md         注入每次会话的策略（只有两个模型，判断走顾问）

tools/
  opus-consult.ps1      顾问调用器：--bare + 硬预算 + 自动记账 + 可降级
  handoff-hook.ps1      压缩前落盘摘要 / 新会话回注（hooks 用）
  claude-usage.ps1      花费账本：自带价表、去重、按真 timestamp 分天、白名单检查

agents/
  scout.md              model: haiku，执行层子代理
  chief.md              model: opus，判断层子代理

docs/
  MODEL_ROUTING.md      什么时候该叫顾问、什么时候该派 scout
  COST_CONTROL.md       完整落地记录，含全部踩坑
```

## 安装

```powershell
# 先确保 ~/.claude/settings.json 里已经配好主会话的模型端点（本方案不改它）
.\install.ps1 -Shortcut
```

`install.ps1` 只做三件事：把文件拷到 `~\.claude\` 对应位置、把两个 hook 合并进 `settings.json`（已存在同名 hook 则跳过）、可选建桌面快捷方式。**不会碰 settings.json 里已有的模型和 token。**

手动装的话，`hooks.example.json` 是 hook 的样子，把路径换成你的即可。

## 已验证的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `/model opus` 还是 Flash | 四个别名都被改写 | 这是设计；判断走 `opus-consult.ps1` |
| 顾问脚本报 `Invalid JSON provided to --settings` | Windows 下把 JSON 字符串直接当参数会被引号转义搞坏 | 必须落成文件再传 |
| 顾问脚本被 stderr 警告打断 | `$ErrorActionPreference='Stop'` 会把原生程序的 stderr 变成 `NativeCommandError` | 调用处临时改成 `Continue` |
| `autoCompactWindow` 不认 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | 模型名以 `claude-` 开头时后者被忽略 | 用 `autoCompactWindow` |
| 压缩点比预期晚得多 | 触发点是「窗口 − 13000」，不是 80% | 直接设小 `autoCompactWindow` |
| hook 一挂会话就断 | hook 抛异常 | 任何异常都要静默 `exit 0`，输出只能一行 JSON |
| 账本金额虚高 4 倍 | 客户端对不认识的中转模型按 $5/$25 兜底估算 | 自带价表自己算 |
| 账本金额翻倍 | resume / sidechain / 压缩会让同一行 usage 重复 | 按 `message.id`+`requestId`+token 三元组去重 |
| `.ps1` 带中文就报 `MissingEndCurlyBrace` | PowerShell 5.1 按 GBK 读无 BOM 的 UTF-8 | 存成 **UTF-8 with BOM** |

## 注意

- 这是给**自己的机器**写的脚本，路径默认 `$env:USERPROFILE\.claude`，模型 id 用的是 DeepSeek 中转的命名（`deepseek-v4-flash[1M]`）。换供应商时改 `duo/settings-duo.json` 和 `tools/claude-usage.ps1` 的价表。
- `claude-usage.ps1` 从 `~/.claude/projects/**/*.jsonl` 读 transcript，价表里没有的模型按 0 计（但仍会标出越界）。
- `duo-policy.md` 里写的是中文，改语言不影响机制。
- 所有数字来自一个真实账号七天的流量，不是估算。

## License

MIT
