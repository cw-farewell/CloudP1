<#
.SYNOPSIS
    持续、低速率、可重复的流量发生器。

.DESCRIPTION
    按固定速率向 todo-api 发请求，可以指定总时长和失败比例。
    目的是让 status 序列在整个 SLO 窗口里都有样本，避免"计数器出生值吞掉增量"
    和"窗口里没有变化"这两类问题，从而让 SLO 数字可解释、多轮之间可对比。

    成功请求：POST /todos，合法 JSON
    失败请求：由 -FailureKind 决定
        422 —— 发送非法 JSON，应用拒绝解析
        404 —— GET 一个不存在的 todo id，应用返回未找到

    需要 5xx 时不要用这个脚本伪造，应该真的把依赖弄坏（比如删掉 redis Pod），
    那样响应码来自真实故障，演练结论才有意义。

.EXAMPLE
    # 每秒 1 次，连续 20 分钟，全部成功
    .\scripts\load-generator.ps1 -Rate 1 -DurationMinutes 20

.EXAMPLE
    # 每秒 2 次，10 分钟，其中 10% 是 422
    .\scripts\load-generator.ps1 -Rate 2 -DurationMinutes 10 -FailurePercent 10

.EXAMPLE
    # 一边跑一边存证据
    .\scripts\load-generator.ps1 -Rate 1 -DurationMinutes 20 -Record
#>

[CmdletBinding()]
param(
    [string]$ApiUrl = 'http://localhost:8000',
    [double]$Rate = 1,
    [double]$DurationMinutes = 20,
    [ValidateRange(0, 100)][int]$FailurePercent = 0,
    [ValidateSet('422', '404')][string]$FailureKind = '422',
    [switch]$Record,
    [string]$EvidenceRoot = 'evidence'
)

$ErrorActionPreference = 'Stop'

if ($Rate -le 0) { throw 'Rate 必须大于 0。' }
if ($DurationMinutes -le 0) { throw 'DurationMinutes 必须大于 0。' }

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$interval = 1.0 / $Rate
$totalPlanned = [int][math]::Round($Rate * $DurationMinutes * 60)
if ($totalPlanned -lt 1) { $totalPlanned = 1 }

# ---------- 预检 ----------
$health = ''
try {
    $health = (& curl.exe -s -m 5 -o NUL -w '%{http_code}' "$ApiUrl/healthz") 2>$null
} catch {
    $health = ''
}
if ($health -ne '200') {
    Write-Host "预检失败：$ApiUrl/healthz 返回 [$health]，不是 200。" -ForegroundColor Red
    Write-Host '先确认服务可达：'
    Write-Host '  kubectl port-forward service/todo-api 8000:8000 -n cloudp1'
    exit 2
}

# 成功请求体写成文件，绕开 PowerShell 给外部程序传参时吃引号的问题。
$bodyFile = Join-Path $env:TEMP 'load-body.json'
'{"title":"load test"}' | Set-Content $bodyFile -Encoding ascii

Write-Host ''
Write-Host "流量发生器  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor Cyan
Write-Host "目标：$ApiUrl"
Write-Host "速率：$Rate 次/秒    时长：$DurationMinutes 分钟    计划请求数：$totalPlanned"
Write-Host "失败比例：$FailurePercent%（类型 $FailureKind）"
Write-Host ''

$codes = @{}
$started = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastReport = 0
$failCount = 0

for ($i = 0; $i -lt $totalPlanned; $i++) {
    # 按绝对时间排程，避免请求耗时累积成漂移。
    $target = $i * $interval
    $wait = $target - $sw.Elapsed.TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }

    $isFailure = $false
    if ($FailurePercent -gt 0) {
        $isFailure = ((Get-Random -Minimum 1 -Maximum 101) -le $FailurePercent)
    }

    if ($isFailure) {
        $failCount++
        if ($FailureKind -eq '422') {
            $code = (& curl.exe -s -m 5 -o NUL -w '%{http_code}' -X POST "$ApiUrl/todos" `
                    -H 'Content-Type: application/json' --data-binary '{not valid json')
        }
        else {
            $randomId = [guid]::NewGuid().ToString()
            $code = (& curl.exe -s -m 5 -o NUL -w '%{http_code}' "$ApiUrl/todos/$randomId")
        }
    }
    else {
        $code = (& curl.exe -s -m 5 -o NUL -w '%{http_code}' -X POST "$ApiUrl/todos" `
                -H 'Content-Type: application/json' --data-binary ('@' + $bodyFile))
    }

    $code = ("$code").Trim()
    if ([string]::IsNullOrWhiteSpace($code)) { $code = 'ERR' }
    if ($codes.ContainsKey($code)) { $codes[$code]++ } else { $codes[$code] = 1 }

    $elapsed = $sw.Elapsed.TotalSeconds
    if ($elapsed - $lastReport -ge 30) {
        $lastReport = $elapsed
        $done = $i + 1
        $actual = if ($elapsed -gt 0) { [math]::Round($done / $elapsed, 2) } else { 0 }
        Write-Host ("  {0} 秒  已发 {1}/{2}  实际速率 {3}/秒" -f [int]$elapsed, $done, $totalPlanned, $actual)
    }
}

$sw.Stop()
$totalElapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$sent = ($codes.Values | Measure-Object -Sum).Sum
$actualRate = if ($totalElapsed -gt 0) { [math]::Round($sent / $totalElapsed, 2) } else { 0 }

# ---------- 汇总 ----------
$summary = @()
$summary += ''
$summary += "开始时间   : $($started.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
$summary += "结束时间   : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
$summary += "实际耗时   : $totalElapsed 秒"
$summary += "发送请求数 : $sent"
$summary += "目标速率   : $Rate 次/秒    实际速率：$actualRate 次/秒"
$summary += "响应码分布 :"
foreach ($k in ($codes.Keys | Sort-Object)) {
    $summary += "    $k -> $($codes[$k])"
}

$successCount = 0
foreach ($k in $codes.Keys) {
    if ($k -match '^2\d\d$') { $successCount += $codes[$k] }
}
$successPct = if ($sent -gt 0) { [math]::Round($successCount / $sent * 100, 2) } else { 0 }
$summary += "成功（2xx）: $successCount"
$summary += "成功率     : $successPct%"

$summary | ForEach-Object { Write-Host $_ }

if ($actualRate -lt $Rate * 0.9) {
    Write-Host ''
    Write-Host ("注意：实际速率 $actualRate 明显低于目标 $Rate，说明单次请求耗时偏长或机器忙。" ) -ForegroundColor Yellow
    Write-Host 'SLO 结论要附带实际速率，不能只写目标速率。' -ForegroundColor Yellow
}

# ---------- 存证 ----------
if ($Record) {
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
    $dir = Join-Path $EvidenceRoot "$stamp-load"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    @(
        "capture_time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "api_url        : $ApiUrl"
        "context        : $(kubectl config current-context)"
        "target_rate    : $Rate per second"
        "duration_min   : $DurationMinutes"
        "failure_percent: $FailurePercent"
        "failure_kind   : $FailureKind"
    ) | Set-Content (Join-Path $dir '00-capture.txt') -Encoding utf8

    $summary | Set-Content (Join-Path $dir '01-summary.txt') -Encoding utf8
    Write-Host ''
    Write-Host "证据已写入 $dir" -ForegroundColor Green
}

exit 0
