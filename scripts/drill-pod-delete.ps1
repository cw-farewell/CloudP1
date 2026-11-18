<#
.SYNOPSIS
    自愈演练：删除一个 API Pod，用集群内探针测量用户影响与自愈耗时。

.DESCRIPTION
    为什么必须在集群内探测：
    早期版本用 kubectl port-forward 到 Service 发请求。port-forward 只建立一条 TCP 连接并固定到某个 Pod，
    那个 Pod 一被删除，隧道立即断开，客户端连续收到连接失败，看起来像"用户大面积受影响"，其实是测量方法坏了。
    2026-11-18 第一次跑就踩了这个坑：报告 39 次失败，实际服务一次都没失败。

.EXAMPLE
    .\scripts\drill-pod-delete.ps1 -ObserveSeconds 45 -Record
#>

[CmdletBinding()]
param(
    [string]$Namespace = 'cloudp1',
    [string]$AppLabel = 'todo-api',
    [string]$ProbeImage = 'curlimages/curl:8.10.1',
    [int]$ObserveSeconds = 60,
    [switch]$Record
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$probeName = 'drill-probe-' + (Get-Date -Format 'HHmmss')

function Get-BackendCount {
    $text = (& kubectl get endpointslice -n $Namespace -l "kubernetes.io/service-name=$AppLabel" -o 'jsonpath={.items[*].endpoints[*].addresses[0]}') 2>$null
    return @("$text" -split '\s+' | Where-Object { $_ -ne '' }).Count
}

function Remove-Probe {
    kubectl delete pod -n $Namespace -l app=drill-probe --ignore-not-found --wait=true --timeout=60s 2>$null | Out-Null
}

$probeTemplate = @'
apiVersion: v1
kind: Pod
metadata:
  name: __PROBE__
  namespace: __NS__
  labels:
    app: drill-probe
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: __IMAGE__
      command:
        - sh
        - -c
        - |
          while true; do
            code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://__APP__:8000/todos)
            echo "$(date +%H:%M:%S) ${code:-000}"
            sleep 1
          done
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
'@

Write-Host ''
Write-Host "自愈演练（删除一个 API Pod）  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor Cyan

$backends = Get-BackendCount
if ($backends -lt 1) {
    Write-Host "预检失败：$AppLabel 后端 $backends 个。" -ForegroundColor Red
    exit 2
}
Write-Host "预检通过：后端 $backends 个"

Remove-Probe
$probeYaml = $probeTemplate.Replace('__PROBE__', $probeName).Replace('__NS__', $Namespace).Replace('__IMAGE__', $ProbeImage).Replace('__APP__', $AppLabel)
$tmp = Join-Path $env:TEMP 'drill-probe.yaml'
$probeYaml | Set-Content $tmp -Encoding utf8
kubectl apply -f $tmp 2>&1 | Out-Null
kubectl wait --for=condition=Ready "pod/$probeName" -n $Namespace --timeout=120s 2>&1 | Out-Null
Write-Host "探针 $probeName 已启动"

# 容器刚起来时前几秒可能解析不到服务名，以"最近 5 条都是 200"作为基线。
$baselineOk = $false
$tail = @()
for ($attempt = 1; $attempt -le 8; $attempt++) {
    Start-Sleep -Seconds 5
    $logs = @(kubectl logs $probeName -n $Namespace 2>&1)
    $tail = @($logs | Select-Object -Last 5)
    if ($tail.Count -eq 5 -and @($tail | Where-Object { $_ -match '\s200$' }).Count -eq 5) {
        $baselineOk = $true
        break
    }
}
if (-not $baselineOk) {
    Write-Host "基线不稳定，最近 5 条：$($tail -join ' | ')" -ForegroundColor Red
    Write-Host '诊断：kubectl exec 进探针手工 curl 一次，看是 DNS 还是连接问题。' -ForegroundColor Yellow
    Remove-Probe
    exit 2
}
Write-Host '基线稳定（最近 5 条均为 200）'

$victim = (& kubectl get pods -n $Namespace -l "app=$AppLabel" -o jsonpath='{.items[0].metadata.name}').Trim()
$injectAt = Get-Date
Write-Host "注入：删除 pod/$victim  $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Yellow
kubectl delete pod $victim -n $Namespace --wait=false 2>&1 | Out-Null

Start-Sleep -Seconds $ObserveSeconds

$logs = @(kubectl logs $probeName -n $Namespace 2>&1)
Remove-Probe

$bad = @($logs | Where-Object { $_ -notmatch '\s200$' })
Write-Host ''
Write-Host '结果' -ForegroundColor Cyan
Write-Host "  探针样本总数   : $($logs.Count)"
Write-Host "  非 200 样本数  : $($bad.Count)"
if ($bad.Count -gt 0) {
    Write-Host "  首个失败       : $($bad[0])" -ForegroundColor Red
    Write-Host "  末个失败       : $($bad[-1])" -ForegroundColor Red
}
Write-Host "  当前后端数     : $(Get-BackendCount)"
Write-Host '  当前 Pod       :'
kubectl get pods -n $Namespace -l "app=$AppLabel" --no-headers | ForEach-Object { Write-Host "    $_" }
Write-Host ''
if ($bad.Count -eq 0) {
    Write-Host '结论：删除一个 Pod 期间没有一次请求失败。' -ForegroundColor Green
} else {
    Write-Host "结论：出现 $($bad.Count) 次失败，先确认是真实影响还是测量方法问题。" -ForegroundColor Yellow
}

if ($Record) {
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
    $dir = "evidence/$stamp-drill-pod-delete"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        "capture_time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "context         : $(kubectl config current-context)"
        "scenario        : 删除一个 API Pod，集群内探针观测"
        "victim_pod      : $victim"
        "inject_time     : $($injectAt.ToString('HH:mm:ss'))"
        "observe_seconds : $ObserveSeconds"
        "probe_samples   : $($logs.Count)"
        "non_200         : $($bad.Count)"
    ) | Set-Content "$dir/00-capture.txt" -Encoding utf8
    $logs | Set-Content "$dir/01-probe-log.txt" -Encoding utf8
    Write-Host "证据已写入 $dir" -ForegroundColor Green
}
exit 0
