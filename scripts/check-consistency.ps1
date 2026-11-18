<#
.SYNOPSIS
    一致性检查：仓库里写的、集群里跑的、监控里加载的，三者是否对得上。

.DESCRIPTION
    检查项：
      1 清单 k8s/api.yaml 的镜像与集群 Deployment 的镜像一致
      2 Deployment 期望副本数与就绪 API Pod 数一致
      3 就绪 API Pod 数与 Service 后端数一致
      4 四个 Deployment 都存在且 Available
      5 告警规则已加载（需要 -PrometheusUrl）
      6 Grafana 面板数量正确（需要 -GrafanaUrl）

    第 1 到 4 项只要有失败，脚本以退出码 1 结束。第 5、6 项未提供地址时标 SKIP，不算失败。

.EXAMPLE
    .\scripts\check-consistency.ps1

.EXAMPLE
    .\scripts\check-consistency.ps1 -PrometheusUrl http://localhost:9090 -GrafanaUrl http://localhost:3000
#>

[CmdletBinding()]
param(
    [string]$Namespace = 'cloudp1',
    [string]$PrometheusUrl = '',
    [string]$GrafanaUrl = '',
    [string[]]$ExpectedAlerts = @('TodoApiScrapeAvailabilityLow', 'TodoApiHigh5xxRate', 'TodoApiTargetsMissing', 'TodoApiBlackboxProbeFailing'),
    [int]$ExpectedPanels = 7
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$results = @()
function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:results += [pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail }
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host ("  [{0}] {1} {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
}

Write-Host ''
Write-Host "一致性检查  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor Cyan
Write-Host "命名空间：$Namespace"
Write-Host ''

# ---------- 1 镜像 ----------
$manifestImage = ((Select-String -Path 'k8s/api.yaml' -Pattern '^\s*image:\s*(\S+)').Matches[0].Groups[1].Value).Trim()
$liveImage = ((& kubectl get deploy todo-api -n $Namespace -o 'jsonpath={.spec.template.spec.containers[0].image}') 2>$null)
$liveImage = ("$liveImage").Trim()
if ($manifestImage -eq $liveImage -and $manifestImage -ne '') {
    Add-Check -Name '清单镜像 = 集群镜像' -Status 'PASS' -Detail $manifestImage
} else {
    Add-Check -Name '清单镜像 = 集群镜像' -Status 'FAIL' -Detail "清单 $manifestImage / 集群 $liveImage"
}

# ---------- 2 副本数 ----------
$desired = ((& kubectl get deploy todo-api -n $Namespace -o 'jsonpath={.spec.replicas}') 2>$null)
$podLines = @((& kubectl get pods -n $Namespace -l app=todo-api --no-headers) 2>$null)
$readyPods = @($podLines | Where-Object { $_ -match '\s+1/1\s+Running' }).Count
if ("$desired".Trim() -eq "$readyPods") {
    Add-Check -Name '期望副本数 = 就绪 Pod 数' -Status 'PASS' -Detail "$readyPods"
} else {
    Add-Check -Name '期望副本数 = 就绪 Pod 数' -Status 'FAIL' -Detail "期望 $desired / 就绪 $readyPods"
}

# ---------- 3 后端数 ----------
$epText = ((& kubectl get endpointslice -n $Namespace -l 'kubernetes.io/service-name=todo-api' -o 'jsonpath={.items[*].endpoints[*].addresses[0]}') 2>$null)
$backends = @("$epText" -split '\s+' | Where-Object { $_ -ne '' }).Count
if ($backends -eq $readyPods) {
    Add-Check -Name '就绪 Pod 数 = Service 后端数' -Status 'PASS' -Detail "$backends"
} else {
    Add-Check -Name '就绪 Pod 数 = Service 后端数' -Status 'FAIL' -Detail "Pod $readyPods / 后端 $backends"
}

# ---------- 4 Deployment 状态 ----------
# 用 jsonpath 直接取 ready/spec，避免解析 kubectl 的列宽输出。
$deployText = ((& kubectl get deploy -n $Namespace -o 'jsonpath={range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas} {end}') 2>$null)
$deployParts = @("$deployText".Trim() -split '\s+' | Where-Object { $_ -match '=' })
$deployState = @{}
foreach ($part in $deployParts) {
    $kv = $part -split '='
    $deployState[$kv[0]] = $kv[1]
}
$badDeploys = @()
foreach ($name in @('redis', 'todo-api', 'prometheus', 'grafana', 'blackbox-exporter')) {
    if (-not $deployState.ContainsKey($name)) { $badDeploys += "$name 缺失"; continue }
    $pair = $deployState[$name] -split '/'
    if ($pair[0] -ne $pair[1]) { $badDeploys += "$name $($deployState[$name])" }
}
if ($badDeploys.Count -eq 0) {
    Add-Check -Name '全部 Deployment 均可用' -Status 'PASS' -Detail "$($deployParts.Count) 个"
} else {
    Add-Check -Name '全部 Deployment 均可用' -Status 'FAIL' -Detail ($badDeploys -join '; ')
}
# ---------- 5 告警规则 ----------
if ([string]::IsNullOrWhiteSpace($PrometheusUrl)) {
    Add-Check -Name '告警规则已加载' -Status 'SKIP' -Detail '未提供 -PrometheusUrl'
} else {
    try {
        $rules = (Invoke-RestMethod "$PrometheusUrl/api/v1/rules?type=alert" -TimeoutSec 10).data.groups.rules
        $loaded = @($rules | ForEach-Object { $_.name })
        $missingAlerts = @($ExpectedAlerts | Where-Object { $loaded -notcontains $_ })
        $unhealthy = @($rules | Where-Object { $_.health -ne 'ok' } | ForEach-Object { $_.name })
        if ($missingAlerts.Count -eq 0 -and $unhealthy.Count -eq 0) {
            Add-Check -Name '告警规则已加载' -Status 'PASS' -Detail "$($loaded.Count) 条"
        } else {
            Add-Check -Name '告警规则已加载' -Status 'FAIL' -Detail "缺失 $($missingAlerts -join ',') 异常 $($unhealthy -join ',')"
        }
    } catch {
        Add-Check -Name '告警规则已加载' -Status 'FAIL' -Detail "查询失败：$($_.Exception.Message)"
    }
}

# ---------- 6 面板 ----------
if ([string]::IsNullOrWhiteSpace($GrafanaUrl)) {
    Add-Check -Name 'Grafana 面板数量' -Status 'SKIP' -Detail '未提供 -GrafanaUrl'
} else {
    try {
        $dash = (Invoke-RestMethod "$GrafanaUrl/api/dashboards/uid/cloudp1-api" -TimeoutSec 10).dashboard
        if ($dash.panels.Count -eq $ExpectedPanels) {
            Add-Check -Name 'Grafana 面板数量' -Status 'PASS' -Detail "$($dash.panels.Count) 块"
        } else {
            Add-Check -Name 'Grafana 面板数量' -Status 'FAIL' -Detail "实际 $($dash.panels.Count) 块，期望 $ExpectedPanels"
        }
    } catch {
        Add-Check -Name 'Grafana 面板数量' -Status 'FAIL' -Detail "查询失败：$($_.Exception.Message)"
    }
}

# ---------- 信息项 ----------
$head = ((& git rev-parse --short=12 HEAD) 2>$null)
$deployedTag = ($liveImage -split ':')[-1]
Write-Host ''
if ($head -eq $deployedTag) {
    Write-Host "  部署版本与 HEAD 一致：$deployedTag" -ForegroundColor DarkGray
} else {
    Write-Host "  部署版本 $deployedTag，仓库 HEAD $head（部署按提交固定版本，属正常，但要知道差异）" -ForegroundColor DarkGray
}

Write-Host ''
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
$skipped = @($results | Where-Object { $_.Status -eq 'SKIP' })
Write-Host ("合计：{0} 项通过，{1} 项失败，{2} 项跳过" -f ($results.Count - $failed.Count - $skipped.Count), $failed.Count, $skipped.Count)

if ($failed.Count -gt 0) {
    Write-Host '存在不一致，按上面 FAIL 项的 Detail 逐条排查。' -ForegroundColor Red
    exit 1
}
Write-Host '全部一致。' -ForegroundColor Green
exit 0
