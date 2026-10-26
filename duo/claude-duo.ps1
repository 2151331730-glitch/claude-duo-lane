# Claude Code · 双模型通道
#   执行层：DeepSeek V4.1 Flash（主会话）
#   判断层：Claude Opus 5.5（只能经 opus-consult.ps1 单次咨询）
#
# 只影响这个入口：不修改 settings.json，也不影响其他快捷方式。
# 模型白名单写在 settings-duo.json（--settings 是叠加，会覆盖同名 env 键），
# 策略文本写在 duo-policy.md（--append-system-prompt-file 注入每次会话）。

$ErrorActionPreference = 'Stop'

# 四个入口的窗口标题分开，任务栏/Alt+Tab 才认得出是哪个通道
try { $Host.UI.RawUI.WindowTitle = 'Claude Code · Flash × Opus 协作' } catch { }

function Test-LocalPort {
    param([int]$Port)
    try {
        $client = New-Object Net.Sockets.TcpClient
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(400, $false)) { $client.Close(); return $false }
        $client.EndConnect($async)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

$settings = Join-Path $env:USERPROFILE '.claude\settings-duo.json'
$policy = Join-Path $env:USERPROFILE '.claude\duo-policy.md'

foreach ($f in @($settings, $policy)) {
    if (-not (Test-Path $f)) {
        Write-Host "缺少文件：$f" -ForegroundColor Red
        Read-Host '按回车关闭'
        return
    }
}

# Opus 顾问走 beeapi.ai，需要本地代理；DeepSeek 主会话沿用同一个出口。
if (-not (Test-LocalPort 7892)) {
    Write-Host '本地代理 127.0.0.1:7892 未运行，正在启动 Pigeon...' -ForegroundColor Yellow
    $pigeon = Join-Path $env:LOCALAPPDATA 'Programs\Pigeon\Pigeon.exe'
    if (Test-Path $pigeon) {
        Start-Process $pigeon
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-LocalPort 7892) { break }
        }
    }
    if (Test-LocalPort 7892) {
        Write-Host '代理已就绪。' -ForegroundColor Green
    } else {
        Write-Host '代理未就绪：主会话能用，但 Opus 顾问会失败。' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '  双模型通道' -ForegroundColor Cyan
Write-Host '  执行 DeepSeek V4.1 Flash　·　判断 Claude Opus 5.5（opus-consult.ps1 单次咨询）' -ForegroundColor DarkGray
Write-Host '  权限 bypass permissions' -ForegroundColor DarkGray
Write-Host ''

Set-Location $env:USERPROFILE

claude --settings $settings --append-system-prompt-file $policy --dangerously-skip-permissions
