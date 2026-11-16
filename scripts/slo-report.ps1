<#
.SYNOPSIS
    输出当前的 SLO 达成情况、置信区间与判定。

.DESCRIPTION
    口径（与 docs/slo.md 保持一致，改口径时两边一起改）：
      - 统计窗口：滚动 1 小时
      - 可用性 SLO：99%。成功定义为 HTTP 2xx，4xx 与 5xx 一律计为失败
      - 延迟 SLO：95% 的业务请求在 100 毫秒内完成（直方图桶 le="0.1"）
      - 判定规则：区间整体在目标之上才算达标，整体之下才算不达标，跨线写"无法判定"

    为什么用 rate 的比值而不是 increase 的次数：
    increase() 只看窗口内首尾样本的差值。计数器序列如果在窗口中途才第一次出现，
    它"出生时"的那次跳变看不见，计数会被低估。比值里分子分母同受这个影响，
    偏差方向一致，比绝对次数稳。绝对次数仍然打印，但标注为近似值。

    置信区间用 Wilson 方法，不用正态近似：
    正态近似在比例接近 0 或 1 时会给出超过 100% 或低于 0% 的荒谬区间，
    本项目失败数经常很小，必须用 Wilson。

.EXAMPLE
    .\scripts\slo-report.ps1
#>

[CmdletBinding()]
param(
    [string]$PrometheusUrl = 'http://localhost:19090',
    [int]$WindowHours = 1,
    [double]$AvailabilityTarget = 99.0,
    [double]$LatencyTarget = 95.0,
    [double]$LatencyThresholdSeconds = 0.1,
    [int]$MinimumSamples = 1000,
    [ValidateSet(0.90, 0.95, 0.99)][double]$Confidence = 0.95
)

$ErrorActionPreference = 'Stop'

function Get-ZValue {
    param([double]$Level)
    switch ($Level) {
        0.90 { return 1.645 }
        0.95 { return 1.960 }
        0.99 { return 2.576 }
        default { return 1.960 }
    }
}

function Get-WilsonInterval {
    # Wilson 得分区间：比例接近 0 或 1 时仍然给出落在 [0,1] 内的合理区间。
    param(
        [double]$Success,
        [double]$Total,
        [double]$Z
    )

    if ($Total -le 0) { return $null }
    $p = $Success / $Total
    $denominator = 1 + ($Z * $Z / $Total)
    $center = ($p + $Z * $Z / (2 * $Total)) / $denominator
    $half = ($Z * [math]::Sqrt($p * (1 - $p) / $Total + $Z * $Z / (4 * $Total * $Total))) / $denominator
    return [pscustomobject]@{
        Low  = [math]::Max(0.0, $center - $half)
        High = [math]::Min(1.0, $center + $half)
    }
}

function Get-Verdict {
    param([double]$Low, [double]$High, [double]$Target)

    if ($Low * 100 -ge $Target) { return '达标' }
    if ($High * 100 -lt $Target) { return '未达标' }
    return '无法判定'
}

function Invoke-PromQuery {
    param([string]$Expr)

    $encoded = [uri]::EscapeDataString($Expr)
    try {
        $response = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/query?query=$encoded" -TimeoutSec 20
    }
    catch {
        throw "查询 Prometheus 失败（$PrometheusUrl）。先确认 9090 的 port-forward 还在运行。原因：$($_.Exception.Message)"
    }
    if ($response.status -ne 'success') { throw "PromQL 返回失败状态：$($response.status)" }
    @($response.data.result)
}

function Get-Scalar {
    param([string]$Expr)
    $result = Invoke-PromQuery -Expr $Expr
    if ($result.Count -eq 0) { return $null }
    return [double]$result[0].value[1]
}

$business = 'job="todo-api",path!~"/healthz|/readyz|/metrics"'
$w = "${WindowHours}h"
$z = Get-ZValue -Level $Confidence
$confidencePct = [math]::Round($Confidence * 100, 0)

Write-Host ''
Write-Host "SLO 报告  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor Cyan
Write-Host "窗口：滚动 $WindowHours 小时    置信水平：$confidencePct%    数据源：$PrometheusUrl"
Write-Host ''

# ---------- 可用性 ----------
$availability = Get-Scalar "sum(rate(todo_http_requests_total{$business,status=~`"2..`"}[$w])) / sum(rate(todo_http_requests_total{$business}[$w]))"
$totalApprox = Get-Scalar "sum(increase(todo_http_requests_total{$business}[$w]))"
$failedApprox = Get-Scalar "sum(increase(todo_http_requests_total{$business,status!~`"2..`"}[$w]))"

if ($null -eq $availability) {
    Write-Host '窗口内没有业务请求，无法计算。先造流量再跑本脚本。' -ForegroundColor Yellow
    Write-Host '  kubectl port-forward service/todo-api 8000:8000 -n cloudp1'
    exit 2
}

Write-Host '可用性 SLI' -ForegroundColor White
$availabilityPct = [math]::Round($availability * 100, 2)
Write-Host "  可用性（rate 比值）      : $availabilityPct%"
Write-Host "  SLO 目标                 : $AvailabilityTarget%"

if ($null -ne $totalApprox -and $totalApprox -ge 1) {
    $totalRounded = [math]::Round($totalApprox, 0)
    $failedRounded = if ($null -eq $failedApprox) { 0 } else { [math]::Round($failedApprox, 0) }
    if ($failedRounded -gt $totalRounded) { $failedRounded = $totalRounded }
    $successRounded = $totalRounded - $failedRounded

    $ci = Get-WilsonInterval -Success $successRounded -Total $totalRounded -Z $z
    Write-Host "  请求数（近似）           : $totalRounded"
    Write-Host "  失败数（近似）           : $failedRounded"
    Write-Host ("  {0}% 置信区间（Wilson）  : [{1:N2}%, {2:N2}%]" -f $confidencePct, ($ci.Low * 100), ($ci.High * 100))

    $verdict = Get-Verdict -Low $ci.Low -High $ci.High -Target $AvailabilityTarget
    switch ($verdict) {
        '达标' {
            Write-Host "  判定                     : 达标（区间下限 $([math]::Round($ci.Low*100,2))% 高于目标）" -ForegroundColor Green
        }
        '未达标' {
            Write-Host "  判定                     : 未达标（区间上限 $([math]::Round($ci.High*100,2))% 低于目标）" -ForegroundColor Red
        }
        default {
            Write-Host "  判定                     : 无法判定（区间 [$([math]::Round($ci.Low*100,2))%, $([math]::Round($ci.High*100,2))%] 跨过目标 $AvailabilityTarget%）" -ForegroundColor Yellow
        }
    }

    $budget = [math]::Round($totalRounded * (1 - $AvailabilityTarget / 100), 1)
    Write-Host "  错误预算（近似）         : 允许失败 $budget 次，实际 $failedRounded 次"
}
else {
    Write-Host '  请求数不足，无法计算置信区间。' -ForegroundColor Yellow
}

# ---------- 延迟 ----------
$latRatio = Get-Scalar "sum(rate(todo_http_request_duration_seconds_bucket{$business,le=`"$LatencyThresholdSeconds`"}[$w])) / sum(rate(todo_http_request_duration_seconds_count{$business}[$w]))"
$latOk = Get-Scalar "sum(increase(todo_http_request_duration_seconds_bucket{$business,le=`"$LatencyThresholdSeconds`"}[$w]))"
$latTotal = Get-Scalar "sum(increase(todo_http_request_duration_seconds_count{$business}[$w]))"

Write-Host ''
Write-Host "延迟 SLI（阈值 $([math]::Round($LatencyThresholdSeconds * 1000, 0)) 毫秒）" -ForegroundColor White
if ($null -eq $latRatio) {
    Write-Host '  窗口内没有延迟样本。' -ForegroundColor Yellow
} else {
    $latPct = [math]::Round($latRatio * 100, 2)
    Write-Host "  达标比例                 : $latPct%"
    Write-Host "  SLO 目标                 : $LatencyTarget%"

    if ($null -ne $latTotal -and $latTotal -ge 1 -and $null -ne $latOk) {
        $latTotalRounded = [math]::Round($latTotal, 0)
        $latOkRounded = [math]::Round($latOk, 0)
        if ($latOkRounded -gt $latTotalRounded) { $latOkRounded = $latTotalRounded }
        $latCi = Get-WilsonInterval -Success $latOkRounded -Total $latTotalRounded -Z $z
        Write-Host ("  {0}% 置信区间（Wilson）  : [{1:N2}%, {2:N2}%]" -f $confidencePct, ($latCi.Low * 100), ($latCi.High * 100))
        $latVerdict = Get-Verdict -Low $latCi.Low -High $latCi.High -Target $LatencyTarget
        switch ($latVerdict) {
            '达标' { Write-Host '  判定                     : 达标' -ForegroundColor Green }
            '未达标' { Write-Host '  判定                     : 未达标' -ForegroundColor Red }
            default { Write-Host '  判定                     : 无法判定（区间跨过目标）' -ForegroundColor Yellow }
        }
    }
}

# ---------- 样本量 ----------
Write-Host ''
if ($null -ne $totalApprox -and $totalApprox -lt $MinimumSamples) {
    Write-Host "注意：样本量约 $([math]::Round($totalApprox,0)) 次，低于 $MinimumSamples 次门槛。" -ForegroundColor Yellow
    Write-Host '置信区间已经反映这一点，但结论仍不宜作为达标依据。' -ForegroundColor Yellow
} elseif ($null -ne $totalApprox) {
    Write-Host "样本量约 $([math]::Round($totalApprox,0)) 次，达到 $MinimumSamples 次门槛。" -ForegroundColor Green
}

Write-Host ''
Write-Host '口径提醒：' -ForegroundColor DarkGray
Write-Host '  - 4xx 与 5xx 都算失败，客户端发错请求也会消耗错误预算。' -ForegroundColor DarkGray
Write-Host '  - 延迟 SLI 的分母是全部业务请求，直方图没有 status 标签，无法只看 2xx。' -ForegroundColor DarkGray
Write-Host '  - 置信区间只覆盖抽样误差，不覆盖采集口径错误和系统误差。' -ForegroundColor DarkGray
