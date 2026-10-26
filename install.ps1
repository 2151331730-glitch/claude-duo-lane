#Requires -Version 5.1
<#
.SYNOPSIS
    把 claude-duo-lane 装进 ~\.claude。

.DESCRIPTION
    做三件事，其余不动：
      1. 复制 duo / tools / agents / icons 到 ~\.claude（已存在则跳过，-Force 覆盖）
      2. 把 handoff 的两个 hook 合并进 settings.json（已有的跳过，改前自动备份）
      3. -Shortcut 时在桌面建快捷方式

    不碰 settings.json 里已有的模型、token 和其他 hook。
    前提：settings.json 里主会话已经配好能用（本脚本不管 API 端点）。

.PARAMETER Shortcut
    顺便创建桌面快捷方式「Claude Code（Flash × Opus 协作）」。

.PARAMETER Force
    覆盖 ~\.claude 里已存在的同名文件。
#>
param(
    [switch]$Shortcut,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dst = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst | Out-Null }

function Copy-Lane([string]$From, [string]$To) {
    if (-not (Test-Path $To)) { New-Item -ItemType Directory -Path $To -Force | Out-Null }
    Get-ChildItem $From -File | ForEach-Object {
        $target = Join-Path $To $_.Name
        if ((Test-Path $target) -and -not $Force) {
            Write-Host "  跳过（已存在）  $($_.Name)" -ForegroundColor DarkGray
        } else {
            Copy-Item $_.FullName $target -Force
            Write-Host "  已装  $($_.Name)" -ForegroundColor Green
        }
    }
}

Write-Host '== 复制文件 ==' -ForegroundColor Cyan
Copy-Lane (Join-Path $src 'duo') $dst
Copy-Lane (Join-Path $src 'tools') (Join-Path $dst 'tools')
Copy-Lane (Join-Path $src 'agents') (Join-Path $dst 'agents')
Get-ChildItem (Join-Path $src 'icons') -File | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $dst $_.Name) -Force
    Write-Host "  已装  $($_.Name)" -ForegroundColor Green
}

# ---------- hooks ----------
Write-Host '== 合并 hooks ==' -ForegroundColor Cyan
$settingsPath = Join-Path $dst 'settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Host '  没有 settings.json，跳过。先跑一次 claude 让它生成，再把 hooks.example.json 的 hooks 段并进去。' -ForegroundColor Yellow
} else {
    # 注意：settings.json 里有 token，本脚本只改 hooks 字段，不读不打印其他内容
    $cfg = (Get-Content $settingsPath -Raw -Encoding UTF8) | ConvertFrom-Json
    $hookPs1 = Join-Path $dst 'tools\handoff-hook.ps1'

    $plan = [ordered]@{
        SessionStart = @{ Matcher = 'startup|resume|clear'; Mode = 'recall' }
        PostCompact  = @{ Matcher = 'auto|manual'; Mode = 'save' }
    }

    $changed = $false
    if (-not $cfg.PSObject.Properties['hooks'] -or -not $cfg.hooks) {
        $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    foreach ($evt in $plan.Keys) {
        $has = $false
        if ($cfg.hooks.PSObject.Properties[$evt]) {
            if (($cfg.hooks.$evt | ConvertTo-Json -Depth 12) -match 'handoff-hook') { $has = $true }
        }
        if ($has) {
            Write-Host "  已有 $evt 的 handoff hook，跳过" -ForegroundColor DarkGray
            continue
        }

        $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $hookPs1 + '" -Mode ' + $plan[$evt].Mode
        $entry = [pscustomobject]@{
            matcher = $plan[$evt].Matcher
            hooks   = @([pscustomobject]@{ command = $cmd; type = 'command'; timeout = 10 })
        }
        $cfg.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue @($entry) -Force
        $changed = $true
        Write-Host "  已加 $evt" -ForegroundColor Green
    }

    if ($changed) {
        $bak = Join-Path $dst ('settings.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Copy-Item $settingsPath $bak -Force
        # 必须无 BOM，Node 读 JSON 遇到 BOM 会解析失败
        [System.IO.File]::WriteAllText($settingsPath, ($cfg | ConvertTo-Json -Depth 20),
            [System.Text.UTF8Encoding]::new($false))
        Write-Host "  已写入（备份：$bak）" -ForegroundColor Green
    } else {
        Write-Host '  无需改动' -ForegroundColor DarkGray
    }
}

# ---------- 快捷方式 ----------
if ($Shortcut) {
    Write-Host '== 桌面快捷方式 ==' -ForegroundColor Cyan
    $wt = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (-not (Test-Path $wt)) {
        Write-Host '  没有 Windows Terminal（wt.exe），快捷方式跳过：可用 cmd 手工起 powershell -File ' -ForegroundColor Yellow
        Write-Host "  $dst\claude-duo.ps1" -ForegroundColor Yellow
    } else {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Code（Flash × Opus 协作）.lnk'
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = $wt
        $s.Arguments = '-d "' + $env:USERPROFILE + '" cmd /k powershell -NoProfile -ExecutionPolicy Bypass -File "' +
            (Join-Path $dst 'claude-duo.ps1') + '"'
        $s.WorkingDirectory = $env:USERPROFILE
        $ico = Join-Path $dst 'duo-icon.ico'
        if (Test-Path $ico) { $s.IconLocation = $ico + ',0' }
        $s.Save()
        Write-Host "  已创建：$lnk" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '装完了。下一步：' -ForegroundColor Cyan
Write-Host '  1. 编辑 ~\.claude\settings-duo.json 里的模型 id，换成你自己中转商的名字'
Write-Host '  2. 双击桌面快捷方式，或直接跑 ~\.claude\claude-duo.ps1'
Write-Host '  3. 顾问调用自检：powershell -File ~\.claude\tools\opus-consult.ps1 "1+1 等于几，只回答数字" -Budget 0.05'
Write-Host '  4. 看花费：powershell -File ~\.claude\tools\claude-usage.ps1 -Days 7'
