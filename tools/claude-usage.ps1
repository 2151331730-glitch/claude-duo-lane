#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code 花费账本（自带价表，自己算钱）。

.DESCRIPTION
    和直接用 transcript 里的 cost-state 不同，本脚本按模型单价自己算：
      - 客户端不认识的中转模型会被它按 $5/$25 兜底估算，虚高 30 倍以上；
      - transcript 里同一行 usage 会因 resume / sidechain / 压缩重复出现，需要按
        message.id + requestId + token 三元组去重，否则总量翻倍。

    价表单位：美元 / 1M token。DeepSeek 记的是闲时价，峰时（工作日 9-12、14-18）×2。

.EXAMPLE
    .\claude-usage.ps1
    .\claude-usage.ps1 -Days 7 -Detail
#>
param(
    [int]$Days = 1,
    [switch]$Detail,
    # 只允许这两个模型（双模型通道的白名单）
    [string[]]$Allowed = @('deepseek-v4-flash', 'claude-opus-5-5')
)

$ErrorActionPreference = 'Stop'
$since = (Get-Date).Date.AddDays(-($Days - 1))

# ---------- 价表 ----------
$PRICES = [ordered]@{
    'claude-opus-5-5'   = @{ In = 4.0;  Out = 20.0; Read = 0.20;  Write = 5.0;   Peak = $false }
    'claude-fable-5-1'  = @{ In = 10.0; Out = 50.0; Read = 1.00;  Write = 12.5;  Peak = $false }
    'claude-sonnet-5-5' = @{ In = 2.0;  Out = 10.0; Read = 0.20;  Write = 2.5;   Peak = $false }
    'claude-haiku-5-5'  = @{ In = 0.10; Out = 0.50; Read = 0.01;  Write = 0.125; Peak = $false }
    'deepseek-v4-flash' = @{ In = 0.15; Out = 0.60; Read = 0.003; Write = 0.0;   Peak = $true  }
    'deepseek-v4-pro'   = @{ In = 0.66; Out = 1.98; Read = 0.022; Write = 0.0;   Peak = $true  }
}

function Get-Price([string]$model) {
    if (-not $model) { return $null }
    $m = ($model -replace '\[[^\]]*\]', '').Trim().ToLowerInvariant()
    foreach ($k in $PRICES.Keys) {
        if ($m -eq $k -or $m.StartsWith($k)) { return $PRICES[$k] }
    }
    return $null
}

function Test-Peak([datetime]$t) {
    $l = $t.ToLocalTime()
    if ($l.DayOfWeek -eq [DayOfWeek]::Saturday -or $l.DayOfWeek -eq [DayOfWeek]::Sunday) { return $false }
    $h = $l.Hour
    return (($h -ge 9 -and $h -lt 12) -or ($h -ge 14 -and $h -lt 18))
}

# ---------- 扫描 ----------
$files = Get-ChildItem "$env:USERPROFILE\.claude\projects" -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $since }

$byDay = @{}
$byModel = @{}
$unknown = @{}
$sessions = @()
$seen = @{}

foreach ($f in $files) {
    $sCost = 0.0; $sCalls = 0
    foreach ($line in (Get-Content $f.FullName -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '"usage"') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $u = $o.message.usage
        if (-not $u) { continue }

        $model = [string]$o.message.model
        if (-not $model -or $model -eq '<synthetic>') { continue }

        $in = [int]$u.input_tokens
        $out = [int]$u.output_tokens
        $cr = [int]$u.cache_read_input_tokens
        $cw = [int]$u.cache_creation_input_tokens
        if (($in + $out + $cr + $cw) -eq 0) { continue }

        # 去重：resume / sidechain / 压缩会让同一行重复出现
        $id = [string]$o.message.id
        $rid = [string]$o.requestId
        if ($id -or $rid) {
            $key = "$id|$rid|$in|$out|$cr|$cw"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 1
        }

        $ts = $null
        if ($o.timestamp) {
            try { $ts = [datetime]::Parse([string]$o.timestamp).ToLocalTime() } catch { $ts = $null }
        }
        if (-not $ts) { $ts = $f.LastWriteTime }
        if ($ts -lt $since) { continue }

        $short = ($model -replace '\[[^\]]*\]', '')
        $p = Get-Price $model
        if ($p) {
            $mult = 1.0
            if ($p.Peak -and (Test-Peak $ts)) { $mult = 2.0 }
            $cost = (($in * $p.In) + ($out * $p.Out) + ($cr * $p.Read) + ($cw * $p.Write)) / 1e6 * $mult
        } else {
            $cost = 0.0
            if (-not $unknown.ContainsKey($short)) { $unknown[$short] = 0 }
            $unknown[$short]++
        }

        $day = $ts.ToString('yyyy-MM-dd')
        if (-not $byDay.ContainsKey($day)) { $byDay[$day] = @{ Calls = 0; Cost = 0.0; CR = 0; Out = 0 } }
        $byDay[$day].Calls++
        $byDay[$day].Cost += $cost
        $byDay[$day].CR += $cr
        $byDay[$day].Out += $out

        if (-not $byModel.ContainsKey($short)) { $byModel[$short] = @{ Calls = 0; Cost = 0.0; CR = 0 } }
        $byModel[$short].Calls++
        $byModel[$short].Cost += $cost
        $byModel[$short].CR += $cr

        $sCost += $cost
        $sCalls++
    }
    if ($sCalls -gt 0) {
        $sessions += [pscustomobject]@{
            Date    = $f.LastWriteTime.ToString('MM-dd HH:mm')
            Session = $f.BaseName.Substring(0, 8)
            Calls   = $sCalls
            Cost    = [math]::Round($sCost, 3)
        }
    }
}

if (-not $byDay.Count) { "最近 $Days 天没有记录。"; exit 0 }

$total = ([double](($byDay.Values | ForEach-Object { $_.Cost } | Measure-Object -Sum).Sum))

"═══ 按天汇总（最近 $Days 天，价表自算）═══"
$byDay.Keys | Sort-Object | ForEach-Object {
    $d = $byDay[$_]
    [pscustomobject]@{
        日期    = $_.Substring(5)
        调用    = $d.Calls
        缓存读M = [math]::Round($d.CR / 1e6, 1)
        输出K   = [math]::Round($d.Out / 1000)
        花费USD = [math]::Round($d.Cost, 2)
    }
} | Format-Table -AutoSize

"═══ 按模型汇总 ═══"
$byModel.Keys | Sort-Object { $byModel[$_].Cost } -Descending | ForEach-Object {
    $m = $byModel[$_]
    $ok = $false
    foreach ($a in $Allowed) { if ($_ -eq $a -or $_.StartsWith($a)) { $ok = $true; break } }
    [pscustomobject]@{
        模型    = $_
        调用    = $m.Calls
        缓存读M = [math]::Round($m.CR / 1e6, 1)
        花费USD = [math]::Round($m.Cost, 2)
        占比    = if ($total -gt 0) { '{0:P0}' -f ($m.Cost / $total) } else { '-' }
        白名单  = if ($ok) { 'OK' } else { '越界' }
    }
} | Format-Table -AutoSize

if ($unknown.Count) {
    "`n⚠ 价表里没有这些模型，花费按 0 计（token 仍已统计）：" + (($unknown.Keys | Sort-Object) -join ', ')
}

$bad = @($byModel.Keys | Where-Object {
        $name = $_
        -not ($Allowed | Where-Object { $name -eq $_ -or $name.StartsWith($_) })
    })
if ($bad.Count) {
    "✗ 白名单外：$($bad -join ', ')"
} else {
    "✓ 全部落在白名单内：$($Allowed -join ' / ')"
}

if ($Detail) {
    "`n═══ 花费最高的 20 个会话 ═══"
    $sessions | Sort-Object Cost -Descending | Select-Object -First 20 | Format-Table -AutoSize
}

"`n总计: `$$([math]::Round($total, 2))"

$ledger = "$env:USERPROFILE\.claude\ledger\consult.jsonl"
if (Test-Path $ledger) {
    $recs = Get-Content $ledger -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
        Where-Object { $_.ts -and [datetime]$_.ts -ge $since }
    if ($recs) {
        $cs = [math]::Round((($recs | Measure-Object costUSD -Sum).Sum), 2)
        "`n═══ Opus 顾问调用 ═══"
        "次数: $($recs.Count)   总花费: `$$cs   平均: `$$([math]::Round((($recs | Measure-Object costUSD -Average).Average),4))"
        $recs | Sort-Object ts -Descending | Select-Object -First 10 `
            @{n = '时间'; e = { ([datetime]$_.ts).ToString('MM-dd HH:mm') } },
            @{n = '花费'; e = { $_.costUSD } },
            @{n = '秒'; e = { $_.secs } },
            @{n = '问题'; e = { if ($_.question.Length -gt 46) { $_.question.Substring(0, 46) + '…' } else { $_.question } } } |
            Format-Table -AutoSize
    }
}
