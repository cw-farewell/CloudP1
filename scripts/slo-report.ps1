<#
.SYNOPSIS
    输出当前的 SLO 达成情况。

.DESCRIPTION
    口径（与 docs/slo.md 保持一致，改口径时两边一起改）：
      - 统计窗口：滚动 1 小时
      - 可用性 SLO：99%。成功定义为 HTTP 2xx，4xx 与 5xx 一律计为失败
      - 延迟 SLO：95% 的业务请求在 100 毫秒内完成（直方图桶 le="0.1"）
      - 样本量不足 1000 次时，结论只作参考，报告里会显式标注

    分母排除 /healthz、/readyz、/metrics，否则探针流量会稀释真实业务请求。

    为什么用 rate 的比值而不是 increase 的次数：
    increase() 只看窗口内首尾样本的差值。计数器序列如果在窗口中途才第一次出现
    （prometheus_client 只在第一次自增后才暴露该标签组合），那么它"出生时"的
    那一次跳变是看不见的，计数会被低估。比值里分子分母同受这个影响，偏差方向一致，
    比绝对次数稳。绝对次数仍然打印，但标注为近似值。

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
    [int]$MinimumSamples = 1000
)

$ErrorActionPreference = 'Stop'

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

Write-Host ''
Write-Host "SLO 报告  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor Cyan
Write-Host "窗口：滚动 $WindowHours 小时    数据源：$PrometheusUrl"
Write-Host ''

# ---------- 可用性：rate 比值 ----------
$availability = Get-Scalar "sum(rate(todo_http_requests_total{$business,status=~`"2..`"}[$w])) / sum(rate(todo_http_requests_total{$business}[$w]))"
$totalApprox = Get-Scalar "sum(increase(todo_http_requests_total{$business}[$w]))"
$failedApprox = Get-Scalar "sum(increase(todo_http_requests_total{$business,status!~`"2..`"}[$w]))"

Write-Host '可用性 SLI' -ForegroundColor White
if ($null -eq $availability) {
    Write-Host '  窗口内没有业务请求，无法计算。先造流量再跑本脚本。' -ForegroundColor Yellow
    Write-Host '  kubectl port-forward service/todo-api 8000:8000 -n cloudp1'
    exit 2
}
$availabilityPct = [math]::Round($availability * 100, 2)
Write-Host "  可用性（rate 比值）    : $availabilityPct%"
Write-Host "  SLO 目标               : $AvailabilityTarget%"
if ($availabilityPct -ge $AvailabilityTarget) {
    Write-Host '  结论                   : 达标' -ForegroundColor Green
} else {
    Write-Host '  结论                   : 未达标' -ForegroundColor Red
}

if ($null -ne $totalApprox) {
    $totalApprox = [math]::Round($totalApprox, 0)
    $failedApprox = if ($null -eq $failedApprox) { 0 } else { [math]::Round($failedApprox, 0) }
    $budget = [math]::Round($totalApprox * (1 - $AvailabilityTarget / 100), 1)
    Write-Host "  请求数（1 小时，近似） : $totalApprox"
    Write-Host "  失败数（近似）         : $failedApprox"
    Write-Host "  错误预算（近似）       : 允许失败 $budget 次"
}

# ---------- 延迟：落在阈值桶内的比例 ----------
$latRatio = Get-Scalar "sum(rate(todo_http_request_duration_seconds_bucket{$business,le=`"$LatencyThresholdSeconds`"}[$w])) / sum(rate(todo_http_request_duration_seconds_count{$business}[$w]))"

Write-Host ''
Write-Host "延迟 SLI（阈值 $([math]::Round($LatencyThresholdSeconds * 1000, 0)) 毫秒）" -ForegroundColor White
if ($null -eq $latRatio) {
    Write-Host '  窗口内没有延迟样本。' -ForegroundColor Yellow
} else {
    $latPct = [math]::Round($latRatio * 100, 2)
    Write-Host "  达标比例               : $latPct%"
    Write-Host "  SLO 目标               : $LatencyTarget%"
    if ($latPct -ge $LatencyTarget) {
        Write-Host '  结论                   : 达标' -ForegroundColor Green
    } else {
        Write-Host '  结论                   : 未达标' -ForegroundColor Red
    }
}

# ---------- 样本量 ----------
Write-Host ''
if ($null -ne $totalApprox -and $totalApprox -lt $MinimumSamples) {
    Write-Host "注意：样本量约 $totalApprox 次，低于 $MinimumSamples 次。" -ForegroundColor Yellow
    Write-Host '结论仅供参考，不能作为 SLO 达标与否的依据。' -ForegroundColor Yellow
} elseif ($null -ne $totalApprox) {
    Write-Host "样本量约 $totalApprox 次，达到 $MinimumSamples 次门槛。" -ForegroundColor Green
}

Write-Host ''
Write-Host '口径提醒：' -ForegroundColor DarkGray
Write-Host '  - 4xx 与 5xx 都算失败，客户端发错请求也会消耗错误预算。' -ForegroundColor DarkGray
Write-Host '  - 延迟 SLI 的分母是全部业务请求，直方图没有 status 标签，无法只看 2xx。' -ForegroundColor DarkGray
Write-Host '  - 请求数与失败数是 increase 近似值，稀疏流量下会低估，以比例为准。' -ForegroundColor DarkGray
