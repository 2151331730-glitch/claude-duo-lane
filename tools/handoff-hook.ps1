#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code 交接自动落盘 / 回注。
    由 hooks 调用，不手工运行。

.DESCRIPTION
    PostCompact  -> 把压缩摘要追加到交接文件（原始对话丢了，结论留下）
    SessionStart -> 新会话（startup/resume/clear）时，把最近几段交接注入回上下文

    设计约束：
      - 任何异常都必须静默退出 0。hook 崩了会打断你的会话，这比丢一条摘要严重得多。
      - 输出必须只有一行 JSON，否则 Claude Code 解析不了。

.PARAMETER Mode
    save  = PostCompact 用
    recall = SessionStart 用
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('save', 'recall')]
    [string]$Mode,

    [int]$RecallSections = 2,
    [int]$RecallMaxChars = 4000
)

$ErrorActionPreference = 'Stop'

function Write-HookJson([hashtable]$obj) {
    $obj | ConvertTo-Json -Compress -Depth 10 | Write-Output
}

try {
    # ---------- 读 stdin ----------
    $raw = [Console]::In.ReadToEnd()
    $payload = $null
    if ($raw -and $raw.Trim()) {
        try { $payload = $raw | ConvertFrom-Json } catch { $payload = $null }
    }

    $cwd = if ($payload.cwd) { $payload.cwd } elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }

    # ---------- 交接文件位置：项目内优先，否则落到 ~/.claude/handoff ----------
    $slug = ($cwd -replace '[\\/:*?"<>|]', '-').Trim('-')
    if ($slug.Length -gt 80) { $slug = $slug.Substring($slug.Length - 80) }

    $projectHandoff = Join-Path $cwd 'HANDOFF.md'
    $canWriteProject = $false
    try {
        if (Test-Path $cwd) {
            $probe = Join-Path $cwd '.handoff-write-probe'
            [System.IO.File]::WriteAllText($probe, 'x')
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            $canWriteProject = $true
        }
    } catch { $canWriteProject = $false }

    if ($canWriteProject -and (Test-Path $projectHandoff)) {
        $handoffFile = $projectHandoff
    } else {
        $dir = "$env:USERPROFILE\.claude\handoff"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $handoffFile = Join-Path $dir "$slug.md"
    }

    if ($Mode -eq 'save') {
        $summary = if ($payload.compact_summary) { [string]$payload.compact_summary } else { '' }
        $trigger = if ($payload.trigger) { $payload.trigger } else { 'unknown' }

        if (-not $summary.Trim()) { exit 0 }

        $head = @(
            '',
            "## $(Get-Date -Format 'yyyy-MM-dd HH:mm') · 压缩交接（$trigger）",
            '',
            "> 工作目录：``$cwd``",
            ''
        ) -join "`n"

        Add-Content -Path $handoffFile -Value ($head + $summary + "`n") -Encoding UTF8
        exit 0
    }

    if ($Mode -eq 'recall') {
        $source = if ($payload.source) { [string]$payload.source } else { 'startup' }
        # 压缩后摘要已经在上下文里了，再注入是重复
        if ($source -eq 'compact') { exit 0 }
        if (-not (Test-Path $handoffFile)) { exit 0 }

        $text = Get-Content $handoffFile -Raw -Encoding UTF8
        if (-not $text -or -not $text.Trim()) { exit 0 }

        # 取最近 N 段
        $parts = [regex]::Split($text, '(?m)^## ') | Where-Object { $_.Trim() }
        $recent = $parts | Select-Object -Last $RecallSections
        $body = ($recent | ForEach-Object { '## ' + $_.Trim() }) -join "`n`n"
        if ($body.Length -gt $RecallMaxChars) {
            $body = '…（更早的交接已省略）' + "`n`n" + $body.Substring($body.Length - $RecallMaxChars)
        }

        $note = @"
以下是你在这个项目上之前留下的交接记录（上一次会话被压缩或结束后自动保存的）。
它可能已经过时——如果和当前代码冲突，以代码为准。

$body
"@

        Write-HookJson @{
            hookSpecificOutput = @{
                hookEventName     = 'SessionStart'
                additionalContext = $note
            }
        }
        exit 0
    }
} catch {
    # 任何异常都静默退出，绝不打乱会话
    exit 0
}
