# Claude Code 成本控制与模型分工 · 落地记录

**日期**：2026-10-25
**目标**：在**不降低质量**的前提下降低 Claude Code 花费
**结论**：三阶段全部落地并实测通过

---

## 一、改造前的诊断（实测数据）

| 指标 | 改造前 |
|---|---|
| 单日花费（改造当天实测） | **1.00**（本文件的花费基准，含当时正在跑的会话；下文所有钱都以它为 1） |
| 每次调用固定开销 | **63,549 token** |
| 上下文压缩触发点 | 窗口 − 13,000（1M 窗口 = 98.7 万才触发，等于从不触发） |
| Opus 会话中位上下文 | 44.5 万 token，峰值 74.4 万 |
| 默认模型 | 名为 "Flash" 的快捷方式实际跑 v4-**pro** |

三个成本乘数，按贡献排序：
1. **上下文长度 × 轮数**（最大头，与模型无关）
2. **模型单价**（Opus 输出单价高）
3. **固定开销**（每次调用必带的系统提示 + 技能清单）

## 二、改造内容

### 阶段 1 · 止血（配置层）

| 文件 | 改动 |
|---|---|
| `settings.json` | `model`: sonnet → `deepseek-v4-flash[1M]`；子代理改 flash；`autoCompactWindow: 160000`；禁用 hyperframes 插件 |
| `settings-bee.json` | 子代理改 `claude-haiku-5-5`；`autoCompactWindow: 160000` |
| `settings-zhipu.json` | 子代理改 `glm-5.3-flash`；`autoCompactWindow: 160000` |

### 阶段 2 · Opus 转顾问

`~/.claude/tools/opus-consult.ps1` —— 按次调用 Opus，带硬性预算闸。

```powershell
opus-consult.ps1 "问题" -Files 文件1,文件2 -Budget 0.5 -Effort medium
```

关键设计：
- `--bare` 跳过插件、CLAUDE.md 自动发现、hooks → 固定开销 **1907 token**
- `--max-budget-usd` 是唯一能封顶单次花费的机制（仅无头模式有）
- 自动把每次调用记入 `~/.claude/ledger/consult.jsonl`

### 阶段 3 · 全自动交接

`~/.claude/tools/handoff-hook.ps1` + 两个 hook：

| Hook | 时机 | 动作 |
|---|---|---|
| `PostCompact` | 压缩发生时 | 把压缩摘要追加到 `HANDOFF.md`（项目内优先，否则 `~/.claude/handoff/`） |
| `SessionStart` | `startup` / `resume` / `clear` | 把最近 2 段交接注入回上下文 |

不需要手动 `/clear`——压缩自动发生，摘要自动留、自动回。

### 模型路由

| 文件 | 作用 |
|---|---|
| `~/.claude/agents/scout.md` | `model: haiku`，执行层子代理 |
| `~/.claude/agents/chief.md` | `model: opus`，判断层子代理 |
| `~/.claude/MODEL_ROUTING.md` | 路由规则，被 CLAUDE.md 引入 |
| `~/.claude/tools/claude-usage.ps1` | 花费账本 |

## 三、实测验证结果

| 项目 | 改造前 | 改造后 | 变化 |
|---|---|---|---|
| DeepSeek 固定开销 | 63,549 | **33,763** | −47% |
| Opus 顾问固定开销 | 63,549 | **1,907** | −97% |
| 单次顾问成本 | — | **0.003 – 0.01** | 有硬闸 |
| 交接跨会话传递 | 无 | **验证码成功传递** | ✓ |
| 压缩触发点 | 98.7 万 | **14.7 万** | −85% |

## 四、踩过的坑

1. **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` 对 bee 无效**：模型名以 `claude-` 开头时该变量被忽略。必须用 `autoCompactWindow`。
2. **自动压缩不是 80% 触发**：实际是 `窗口 − 13000`。要早压就设小窗口（160000）。
3. **`@` 导入路径相对 CLAUDE.md 所在目录**：`@.claude/MODEL_ROUTING.md` 会解析成 `.claude/.claude/`，应为 `@MODEL_ROUTING.md`。
4. **`.ps1` 带中文必须 UTF-8 with BOM**，否则 PowerShell 5.1 按 GBK 读会报错。
5. **transcript 的逐次 usage 不含 costUSD**：成本只在 `type=cost-state` 汇总行里。
6. **hook 必须只输出一行 JSON**，且任何异常都要静默 exit 0，否则会打断会话。
7. **同一会话内无法跨端点路由**：`model` 只能在当前 `ANTHROPIC_BASE_URL` 内选。跨 Opus/DeepSeek 必须开独立进程。

## 五、回滚方式

备份在 `~/.claude/backup-20261025-202842/`，四个 settings 文件原样可还原。

```powershell
Copy-Item "$env:USERPROFILE\.claude\backup-20261025-202842\*.json" "$env:USERPROFILE\.claude\" -Force
```

## 六、后续要观察的两个数

- **每任务平均花费**：`claude-usage.ps1 -Days 7`
- **Opus 顾问调用次数/天**：同上，看最后一段

七天后对照：如果顾问调用超过 30 次/天，说明阈值设太松，可以收紧 `MODEL_ROUTING.md` 里的「该叫顾问」条件。
如果顾问调用少于 5 次/天但问题变多，说明该放开的没放开。

---

## 七、双模型通道（2026-10-26 新增）

需求：一个只允许 `deepseek-v4-flash[1M]` + `claude-opus-5-5` 两个模型的入口，点开即用，且**不影响其他入口**。

做法是不改 `settings.json`，另开一套：

| 文件 | 作用 |
|---|---|
| `~/.claude/claude-duo.ps1` | 启动器（UTF-8 BOM）：查 7892 端口 → 必要时拉起 Pigeon → 打印通道信息 → 起 claude |
| `~/.claude/settings-duo.json` | 只写 env 覆盖：四个别名 + `ANTHROPIC_MODEL` + `CLAUDE_CODE_SUBAGENT_MODEL` 全部 = `deepseek-v4-flash[1M]` |
| `~/.claude/duo-policy.md` | `--append-system-prompt-file` 注入：本通道只有 Flash，判断必须走 `opus-consult.ps1` |
| `~/.claude/duo-icon.ico` | 蓝鲸 + 橙花左右分屏，16/32/48/64/128/256 六帧 |

桌面快捷方式「Claude Code（Flash × Opus 协作）」→ `wt.exe -d %USERPROFILE% cmd /k powershell -NoProfile -ExecutionPolicy Bypass -File "...claude-duo.ps1"`。

实测结论（都跑过）：

- `--settings` 是**叠加**不是替换：base 的 hooks 照常触发，同名 env 键被覆盖。所以 duo 文件里不需要复制 token、不需要复制 hooks——token 轮换时只改 `settings.json` 一处。
- 四个别名实测全部解析为 `deepseek-v4-flash[1M]`。
- `--append-system-prompt-file` 可用（隐藏语法，`claude --help` 只在描述里提到 `--append-system-prompt[-file]`），比塞 inline 长字符串稳。
- 本通道里 `chief`（model: opus）和 `scout`（model: haiku）都会被别名改写成 Flash —— 所以 `duo-policy.md` 明确禁止用 `chief` 做判断，判断一律走 `opus-consult.ps1`。

代价：这条通道里没有 DeepSeek Pro 这个中间档，判断要么 Flash 要么 Opus 单次，所以策略文本把升级阈值写得更松（返工 > $5 或不可逆操作就上 Opus）。

### 7.1 顾问降级（`-FallbackFlash`）

`opus-consult.ps1` 加 `-FallbackFlash` 后，代理不可用或 Opus 调用失败时自动改用 DeepSeek Flash 重试一次：

- 代理端口没开：端口检查直接判定，**约 10 秒**内降级完成。
- 代理开着但 bee 报错：claude CLI 自己会重试，**约 3 分钟**后才失败，兜底也随之延后。
- 降级时临时生成一个 settings 文件（`%TEMP%\claude-consult-fallback.json`，无 BOM），把 `api.deepseek.com` 写进 `NO_PROXY` 并清空 `HTTPS_PROXY`——因为 base `settings.json` 里硬塞了指向 7892 的代理，代理死了会连 DeepSeek 一起拖死。
- 输出头改成「Flash 兜底顾问（非 Opus，结论仅供参考）」，ledger 记 `degraded=true`。

两个踩坑：`--settings` **不能直接传 JSON 字符串**（命令行引号转义会把它搞成 Invalid JSON），必须落文件；脚本级 `$ErrorActionPreference='Stop'` 会把 claude 的 stderr 警告变成终止性 `NativeCommandError`，调用处必须临时放开。
