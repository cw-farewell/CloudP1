<#
.SYNOPSIS
    依赖故障演练：停掉 Redis，记录用户影响与告警的完整时间线。

.DESCRIPTION
    按固定节奏探测 API，同时读取 Prometheus 的告警状态，记录这些时刻：

      注入开始      scale redis 到 0
      用户受影响    第一次探测到非 200
      告警 pending  规则进入 pending
      告警 firing   规则进入 firing
      恢复操作      scale redis 回 1
      业务恢复      第一次探测回 200
      告警解除      规则回到 inactive

    输出各项耗时：发现耗时（受影响 → firing）、恢复耗时（恢复操作 → 业务恢复）。

    探测本身会产生真实请求，所以 5xx 类告警有数据可用，不需要另外跑流量发生器。

.EXAMPLE
    .\scripts\drill-redis-down.ps1 -ApiUrl http://localhost:8000 -PrometheusUrl http://localhost:9090
#>

[CmdletBinding()]
param(
    [string]$ApiUrl = 'http://localhost:8000',
    [string]$PrometheusUrl = 'http://localhost:9090',
    [int]$HoldSeconds = 240,
    [int]$ProbeIntervalSeconds = 3,
    [int]$RecoveryTimeoutSeconds = 600,
    [string[]]$AlertNames = @('TodoApiScrapeAvailabilityLow', 'TodoApiHigh5xxRate'),
    [switch]$Record
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$events = @()
function Add-Event {
    param([string]$Name, [string]$Detail = '')
    $now = Get-Date
    $script:events += [pscustomobject]@{ Name = $Name; Time = $now; Detail = $Detail }
    Write-Host ("  [{0}] {1} {2}" -f $now.ToString('HH:mm:ss'), $Name, $Detail)
}

function Get-ApiCode {
    $code = (& curl.exe -s -m 5 -o NUL -w '%{http_code}' "$ApiUrl/todos") 2>$null
    $code = ("$code").Trim()
    if ([string]::IsNullOrWhiteSpace($code)) { return 'ERR' }
    return $code
}

function Get-AlertStates {
    try {
        $rules = (Invoke-RestMethod "$PrometheusUrl/api/v1/rules?type=alert" -TimeoutSec 10).data.groups.rules
    } catch {
        return @{}
    }
    $states = @{}
    foreach ($r in $rules) {
        if ($AlertNames -contains $r.name) { $states[$r.name] = $r.state }
    }
    return $states
}

# ---------- 预检 ----------
Write-Host ''
Write-Host "依赖故障演练（Redis 停止）  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor Cyan

$pre = Get-ApiCode
if ($pre -ne '200') {
    Write-Host "预检失败：$ApiUrl/todos 返回 $pre，演练前服务应正常。" -ForegroundColor Red
    exit 2
}
$preStates = Get-AlertStates
Write-Host "预检通过。告警初始状态：" ($preStates.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -Separator ' '
Write-Host ""

try {
    # ---------- 注入 ----------
    Add-Event '注入开始' 'kubectl scale deployment/redis --replicas=0'
    kubectl scale deployment/redis -n cloudp1 --replicas=0 | Out-Null

    $impactAt = $null
    $pendingAt = $null
    $firingAt = $null
    $deadline = (Get-Date).AddSeconds($HoldSeconds)

    Write-Host '观察中...'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $ProbeIntervalSeconds
        $code = Get-ApiCode
        if ($null -eq $impactAt -and $code -ne '200') {
            Add-Event '用户受影响' "首次探测返回 $code"
            $impactAt = Get-Date
        }
        if ($null -eq $pendingAt -or $null -eq $firingAt) {
            $states = Get-AlertStates
            foreach ($name in $AlertNames) {
                $state = $states[$name]
                if ($null -eq $pendingAt -and $state -eq 'pending') {
                    Add-Event '告警 pending' $name
                    $pendingAt = Get-Date
                }
                if ($null -eq $firingAt -and $state -eq 'firing') {
                    Add-Event '告警 firing' $name
                    $firingAt = Get-Date
                }
            }
        }
        if ($null -ne $firingAt -and (Get-Date) -gt $firingAt.AddSeconds(20)) { break }
    }

    if ($null -eq $firingAt) {
        Add-Event '告警未触发' ("观察 $HoldSeconds 秒仍未 firing：" + (($AlertNames | ForEach-Object { "$_=$((Get-AlertStates)[$_])" }) -join ' '))
    }

    # ---------- 恢复 ----------
    Add-Event '恢复操作' 'kubectl scale deployment/redis --replicas=1'
    kubectl scale deployment/redis -n cloudp1 --replicas=1 | Out-Null
    $recoverAt = Get-Date

    $businessBackAt = $null
    $alertClearAt = $null
    $recoveryDeadline = (Get-Date).AddSeconds($RecoveryTimeoutSeconds)

    Write-Host '等待恢复...'
    while ((Get-Date) -lt $recoveryDeadline) {
        Start-Sleep -Seconds $ProbeIntervalSeconds
        if ($null -eq $businessBackAt) {
            $code = Get-ApiCode
            if ($code -eq '200') {
                Add-Event '业务恢复' '探测返回 200'
                $businessBackAt = Get-Date
            }
        }
        if ($null -eq $alertClearAt) {
            $states = Get-AlertStates
            $allInactive = $true
            foreach ($name in $AlertNames) {
                if ($states[$name] -and $states[$name] -ne 'inactive') { $allInactive = $false }
            }
            if ($allInactive) {
                Add-Event '告警解除' '全部规则回到 inactive'
                $alertClearAt = Get-Date
            }
        }
        if ($null -ne $businessBackAt -and $null -ne $alertClearAt) { break }
    }

    # ---------- 汇总 ----------
    Write-Host ''
    Write-Host '时间线' -ForegroundColor Cyan
    $events | Format-Table -AutoSize | Out-String | Write-Host

    function Format-Duration {
        param($From, $To)
        if ($null -eq $From -or $null -eq $To) { return '未观测到' }
        return "$([math]::Round(($To - $From).TotalSeconds, 1)) 秒"
    }

    $injectAt = $events[0].Time

    Write-Host '关键数字' -ForegroundColor Cyan
    Write-Host "  注入 → 用户受影响   : $(Format-Duration $injectAt $impactAt)"
    Write-Host "  用户受影响 → firing : $(Format-Duration $impactAt $firingAt)   ← 发现耗时 MTTD"
    Write-Host "  恢复操作 → 业务恢复 : $(Format-Duration $recoverAt $businessBackAt)   ← 恢复耗时"
    Write-Host "  恢复操作 → 告警解除 : $(Format-Duration $recoverAt $alertClearAt)"
    Write-Host ""

    if ($Record) {
        $stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
        $dir = "evidence/$stamp-drill-redis-down"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        @(
            "capture_time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
            "context      : $(kubectl config current-context)"
            "scenario     : redis 停止，观察 API 影响与告警"
            "hold_seconds : $HoldSeconds"
            "probe_interval: $ProbeIntervalSeconds"
        ) | Set-Content "$dir/00-capture.txt" -Encoding utf8
        $events | ForEach-Object { "{0}  {1}  {2}" -f $_.Time.ToString('yyyy-MM-dd HH:mm:ss'), $_.Name, $_.Detail } |
            Set-Content "$dir/01-timeline.txt" -Encoding utf8
        Write-Host "证据已写入 $dir" -ForegroundColor Green
    }
    exit 0
}
catch {
    Write-Host ''
    Write-Host "演练中断：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '无论失败原因，先把 Redis 恢复：' -ForegroundColor Yellow
    Write-Host '  kubectl scale deployment/redis -n cloudp1 --replicas=1'
    exit 1
}
