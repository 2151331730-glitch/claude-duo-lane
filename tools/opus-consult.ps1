#Requires -Version 5.1
<#
.SYNOPSIS
    Opus 顾问调用器 —— 把 Opus 变成按次计费的「顾问」，只在干净上下文里做判断。

.DESCRIPTION
    主会话（Flash）负责执行；遇到需要判断的事，调用本脚本。
    Opus 拿到的只有：你的问题 + 你显式指定的文件，没有 40 万历史包袱。

    为什么用 --bare：
      - 跳过插件技能清单、CLAUDE.md 自动发现、hooks、MCP 同步
      - 实测固定开销从 63k token 降到约 2k
    为什么用 -p + --max-budget-usd：
      - 交互模式没有预算硬闸；只有无头模式有，且这是唯一能封顶 Opus 花费的方式。

.PARAMETER Question
    要问的问题。尽量具体：给出症状 + 你已经试过什么。

.PARAMETER Files
    要一起送过去的文件（相对或绝对路径）。只送真正相关的，送得越多越贵。

.PARAMETER Budget
    单次花费上限（美元），默认 0.50。超了会被 API 侧掐断。

.PARAMETER MaxChars
    文件内容总字符上限，默认 80000（约 20k token）。超了会截断并警告。

.PARAMETER Effort
    low / medium / high / xhigh / max。思考 token 是 Opus 的主要成本来源，复杂诊断用 high，平时 medium。

.PARAMETER FallbackFlash
    代理不通 / Opus 调用失败时，改用 DeepSeek Flash 兜底重试一次，不让任务卡死。
    结论质量低于 Opus（ledger 记 degraded=true，输出头会标「Flash 兜底顾问」）。
    注意：端点可达但 bee 报错时，CLI 自己会重试约 3 分钟才失败，兜底也随之延后；
    代理根本没开的情况走端口检查，会立刻降级。

.EXAMPLE
    .\opus-consult.ps1 "壁纸设好后几秒被换回去，最可能的根因是什么" -Files src\apply.py,src\watch.py -FallbackFlash

.EXAMPLE
    .\opus-consult.ps1 "壁纸设好后几秒被换回去，最可能的根因是什么" -Files src\apply.py,src\watch.py

.EXAMPLE
    .\opus-consult.ps1 "这段评分逻辑为什么会导致个性化失效" -Files src\score.py -Effort high
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Question,

    [string[]]$Files,

    [double]$Budget = 0.50,

    [int]$MaxChars = 80000,

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort = 'medium',

    [string]$Model = 'claude-opus-5-5',

    [string]$SettingsPath = "$env:USERPROFILE\.claude\settings-bee.json",

    [switch]$NoLedger,

    # Pigeon 没开 / bee 连不上时，改用 DeepSeek Flash 兜底重试，不让任务卡死。
    # 判断质量低于 Opus，ledger 里会记 degraded=true。
    [switch]$FallbackFlash
)

$ErrorActionPreference = 'Stop'

# ---------- 定位 claude.exe ----------
$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) {
    $cand = "$env:APPDATA\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
    if (Test-Path $cand) { $claude = $cand } else { throw "找不到 claude.exe" }
}

# ---------- 确保代理可用（beeapi.ai 国内直连不通）----------
function Test-Port([int]$Port) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $a = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne(400, $false)) { $c.Close(); return $false }
        $c.EndConnect($a); $c.Close(); return $true
    } catch { return $false }
}

if (-not (Test-Port 7892)) {
    $pigeon = Join-Path $env:LOCALAPPDATA 'Programs\Pigeon\Pigeon.exe'
    if (Test-Path $pigeon) {
        Start-Process $pigeon
        for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Test-Port 7892) { break } }
    }
}

$degraded = $false
if (-not (Test-Port 7892)) {
    if (-not $FallbackFlash) {
        throw "本地代理 127.0.0.1:7892 不可用，beeapi.ai 连不上。请先开 Pigeon，或加 -FallbackFlash 用 DeepSeek 兜底。"
    }
    Write-Warning '本地代理不可用：本次降级到 DeepSeek Flash 回答，判断质量低于 Opus（ledger 记 degraded=true）。'
    $degraded = $true
}

if (-not $degraded) {
    $env:HTTPS_PROXY = 'http://127.0.0.1:7892'
    $env:HTTP_PROXY = 'http://127.0.0.1:7892'
    $env:NO_PROXY = 'localhost,127.0.0.1,::1'
}

if (-not (Test-Path $SettingsPath)) { throw "找不到 settings 文件: $SettingsPath" }

# 降级时绕开代理直连 DeepSeek（settings.json 里的 HTTPS_PROXY 可能指向死的那个代理）。
# 必须落成文件：Windows 下把 JSON 字符串直接当命令行参数传会被引号转义搞坏。
$FALLBACK_SETTINGS = Join-Path $env:TEMP 'claude-consult-fallback.json'
function Get-FallbackSettings {
    $json = '{"env":{"NO_PROXY":"localhost,127.0.0.1,::1,api.deepseek.com,.deepseek.com"}}'
    [System.IO.File]::WriteAllText($FALLBACK_SETTINGS, $json, [System.Text.UTF8Encoding]::new($false))
    return $FALLBACK_SETTINGS
}

$effectiveSettings = if ($degraded) { Get-FallbackSettings } else { $SettingsPath }
if ($degraded) {
    $Model = 'deepseek-v4-flash[1M]'
    $env:NO_PROXY = 'localhost,127.0.0.1,::1,api.deepseek.com,.deepseek.com'
    $env:HTTPS_PROXY = ''
    $env:HTTP_PROXY = ''
}

# ---------- 组装上下文 ----------
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('你是一个顾问。调用你的人正在执行任务，卡在需要判断的地方，向你请教。')
[void]$sb.AppendLine('要求：')
[void]$sb.AppendLine('- 直接给结论和理由，不要复述问题，不要客套。')
[void]$sb.AppendLine('- 需要看更多文件才能判断时，明确说「需要看 X」，不要猜。')
[void]$sb.AppendLine('- 控制长度：结论优先，除非我要求，不要写完整代码。')
[void]$sb.AppendLine()
[void]$sb.AppendLine('## 问题')
[void]$sb.AppendLine($Question.Trim())
[void]$sb.AppendLine()

if ($Files) {
    $used = 0
    $included = 0
    [void]$sb.AppendLine('## 相关文件')
    foreach ($f in $Files) {
        if (-not (Test-Path $f)) { Write-Warning "文件不存在，跳过: $f"; continue }
        $item = Get-Item $f
        if ($item.PSIsContainer) { Write-Warning "是目录，跳过: $f"; continue }
        $remaining = $MaxChars - $used
        if ($remaining -le 500) { Write-Warning "字符预算已用尽，跳过: $f"; continue }

        $text = Get-Content $f -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { $text = '' }
        if ($text.Length -gt $remaining) {
            $text = $text.Substring(0, $remaining) + "`n... [已截断，原文件 $($item.Length) 字节]"
            Write-Warning "文件被截断: $f"
        }
        $used += $text.Length
        $included++

        [void]$sb.AppendLine("### $f")
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine($text)
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine()
    }
    Write-Verbose "送入 $included 个文件，共 $used 字符"
}

$prompt = $sb.ToString()

# ---------- 调用 ----------
function Invoke-Consult([string]$M, [string]$S, [switch]$WithEffort) {
    $argv = @('-p', '--bare', '--model', $M, '--settings', $S,
        '--max-budget-usd', $Budget.ToString([Globalization.CultureInfo]::InvariantCulture),
        '--output-format', 'json')
    if ($WithEffort) { $argv += @('--effort', $Effort) }
    $argv += $prompt
    # 脚本级 ErrorActionPreference=Stop 会把原生程序的 stderr 当成终止性错误
    # （PS 5.1 的 NativeCommandError），这里必须临时放开。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $claude @argv 2>&1) } finally { $ErrorActionPreference = $prev }
}

function Get-ResultJson($raw) {
    $line = $raw | Where-Object { $_ -match '^\{"duration_api_ms"|^\{"type":"result"' } | Select-Object -Last 1
    if (-not $line) { return $null }
    try { return ($line | ConvertFrom-Json) } catch { return $null }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$raw = Invoke-Consult -M $Model -S $effectiveSettings -WithEffort:(-not $degraded)
$sw.Stop()
$j = Get-ResultJson $raw

# Opus 调不通（bee 抽风、额度、网络）→ 可选降级重试一次
if ((-not $j -or $j.is_error) -and -not $degraded -and $FallbackFlash) {
    $why = if ($j) { ": $($j.result)" } else { '' }
    Write-Warning "Opus 调用失败$why，降级到 DeepSeek Flash 重试一次。"
    $degraded = $true
    $Model = 'deepseek-v4-flash[1M]'
    $env:NO_PROXY = 'localhost,127.0.0.1,::1,api.deepseek.com,.deepseek.com'
    $env:HTTPS_PROXY = ''
    $env:HTTP_PROXY = ''
    $sw.Restart()
    $raw = Invoke-Consult -M $Model -S (Get-FallbackSettings) -WithEffort:$false
    $sw.Stop()
    $j = Get-ResultJson $raw
}

if (-not $j) {
    throw "顾问调用没有返回结果。原始输出:`n$($raw | Out-String)"
}

if ($j.is_error) {
    throw "顾问调用失败: $($j.result)"
}

# ---------- 记账 ----------
if (-not $NoLedger) {
    $ledgerDir = "$env:USERPROFILE\.claude\ledger"
    if (-not (Test-Path $ledgerDir)) { New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null }
    $rec = [ordered]@{
        ts         = (Get-Date).ToString('o')
        kind       = 'consult'
        model      = $Model
        effort     = $Effort
        cwd        = (Get-Location).Path
        question   = if ($Question.Length -gt 200) { $Question.Substring(0, 200) } else { $Question }
        files      = ($Files -join ';')
        filesChars = $prompt.Length
        inTokens   = $j.usage.input_tokens + $j.usage.cache_creation_input_tokens + $j.usage.cache_read_input_tokens
        outTokens  = $j.usage.output_tokens
        thinkTok   = $j.usage.output_tokens_details.thinking_tokens
        costUSD    = $j.total_cost_usd
        secs       = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        ok         = $true
        degraded   = $degraded
    }
    ($rec | ConvertTo-Json -Compress) | Add-Content "$ledgerDir\consult.jsonl" -Encoding UTF8
}

# ---------- 输出 ----------
$who = if ($degraded) { 'Flash 兜底顾问（非 Opus，结论仅供参考）' } else { 'Opus 顾问' }
Write-Host "──── $who · `$$([math]::Round($j.total_cost_usd,4)) · $([math]::Round($sw.Elapsed.TotalSeconds,0))s · $($j.usage.output_tokens) 输出 token（含思考 $($j.usage.output_tokens_details.thinking_tokens)）────" -ForegroundColor DarkCyan
$j.result
