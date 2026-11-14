<#
.SYNOPSIS
    从零重建 cloudp1 命名空间内的全部工作负载。

.DESCRIPTION
    按顺序应用 k8s/ 下的清单，等待四个 Deployment 就绪，最后打印可核对的结论。
    只做「创建或对齐」，不删除任何资源，不碰凭证。

    仅适用于本地 Docker Desktop Kubernetes。单节点，无高可用，
    Redis 与 Prometheus 都没有持久卷，重建或重启后数据会清空，这是预期行为。

.EXAMPLE
    .\scripts\bootstrap.ps1

.EXAMPLE
    .\scripts\bootstrap.ps1 -TimeoutSeconds 600
#>

[CmdletBinding()]
param(
    [string]$Context = 'docker-desktop',
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

# 固定工作目录：脚本在 scripts/ 下，仓库根是它的上一级。
# 不依赖调用时所在的位置，避免文件被写到别处。
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:startedAt = Get-Date
$script:steps = @()

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Add-Result {
    param(
        [string]$Name,
        [datetime]$Started,
        [bool]$Ok = $true
    )
    $script:steps += [pscustomobject]@{
        Step    = $Name
        Seconds = [math]::Round(((Get-Date) - $Started).TotalSeconds, 1)
        Ok      = $Ok
    }
}

function Invoke-Kubectl {
    # kubectl 是外部程序，失败时只设置退出码，不会抛异常，必须自己检查。
    # 参数名不能用 $Args，那是 PowerShell 的自动变量。
    param([string[]]$KubeArgs)

    & kubectl @KubeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($KubeArgs -join ' ') 失败，退出码 $LASTEXITCODE"
    }
}

function Get-NamespacePhase {
    # 查询不存在的命名空间时，kubectl 会把 NotFound 写到 stderr。在
    # $ErrorActionPreference='Stop' 下这条 stderr 会被当成终止错误，
    # 让预检直接失败。这里临时放宽，只按退出码判断。
    param([string]$Name)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $phase = & kubectl get namespace $Name -o jsonpath='{.status.phase}' 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        return (($phase -join '').Trim())
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

$manifests = @(
    'k8s/namespace.yaml'
    'k8s/redis.yaml'
    'k8s/api.yaml'
    'k8s/prometheus.yaml'
    'k8s/grafana.yaml'
)

$deployments = @('redis', 'todo-api', 'prometheus', 'grafana')

try {
    # ---------- 1 预检 ----------
    Write-Step '预检环境'
    $stepStart = Get-Date

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw '找不到 kubectl。请先启动 Docker Desktop，并在设置里启用 Kubernetes。'
    }

    $currentContext = (& kubectl config current-context).Trim()
    Write-Host "当前 context：$currentContext"
    if ($currentContext -ne $Context) {
        throw "context 是 $currentContext，不是 $Context。为避免部署到其它集群，停止执行。"
    }

    foreach ($file in $manifests) {
        if (-not (Test-Path $file)) {
            throw "缺少清单文件 $file（工作目录：$(Get-Location)）"
        }
    }

    # 命名空间若停在 Terminating，apply 会失败，必须等它消失。
    # 不存在时 Get-NamespacePhase 返回空字符串，属于正常情况。
    $phase = Get-NamespacePhase -Name 'cloudp1'
    if ($phase -eq 'Terminating') {
        Write-Host "命名空间 cloudp1 正在删除，等待其消失（最多 $TimeoutSeconds 秒）..."
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline -and $phase -ne '') {
            Start-Sleep -Seconds 2
            $phase = Get-NamespacePhase -Name 'cloudp1'
        }
        if ($phase -ne '') {
            throw "命名空间 cloudp1 一直停留在 Terminating，超过 $TimeoutSeconds 秒。"
        }
    }

    Add-Result -Name '预检' -Started $stepStart
    Write-Host '预检通过'

    # ---------- 2 应用清单 ----------
    Write-Step '应用清单（apply 是幂等的，可重复执行）'
    $stepStart = Get-Date

    foreach ($file in $manifests) {
        Write-Host "apply $file"
        Invoke-Kubectl @('apply', '-f', $file)
    }

    Add-Result -Name '应用清单' -Started $stepStart

    # ---------- 3 等待就绪 ----------
    Write-Step "等待工作负载就绪（每个最多 $TimeoutSeconds 秒）"
    $stepStart = Get-Date

    foreach ($name in $deployments) {
        Write-Host "等待 deployment/$name"
        Invoke-Kubectl @(
            'rollout', 'status', "deployment/$name",
            '-n', 'cloudp1',
            "--timeout=${TimeoutSeconds}s"
        )
    }

    Add-Result -Name '等待就绪' -Started $stepStart

    # ---------- 4 汇总 ----------
    Write-Step '结果'

    $pods = Invoke-Kubectl @(
        'get', 'pods', '-n', 'cloudp1', '--no-headers',
        '-o', 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase'
    )
    $rows = @($pods | Where-Object { $_ -match '\S' })

    if ($rows.Count -lt 4) {
        throw "Pod 列表只有 $($rows.Count) 行，可能查询失败。"
    }

    $total = $rows.Count
    $ready = @($rows | Where-Object { $_ -match '\s+True\s+Running' }).Count

    Write-Host "Pod 就绪：$ready / $total"
    $rows | ForEach-Object { Write-Host "  $_" }

    $image = Invoke-Kubectl @(
        'get', 'deploy', 'todo-api', '-n', 'cloudp1',
        '-o', 'jsonpath={.spec.template.spec.containers[0].image}'
    )
    Write-Host "API 镜像：$image"

    # EndpointSlice 取代了已弃用的 v1 Endpoints（集群 1.33+）。
    # jsonpath 里不要写双引号：PowerShell 5.1 传给外部程序时会吃掉引号，
    # kubectl 收到 {\n} 就报错。这里输出空格分隔的地址，再由脚本拆分。
    $endpointText = Invoke-Kubectl @(
        'get', 'endpointslice', '-n', 'cloudp1',
        '-l', 'kubernetes.io/service-name=todo-api',
        '-o', 'jsonpath={.items[*].endpoints[*].addresses[0]}'
    )
    $backends = @($endpointText -split '\s+' | Where-Object { $_ -ne '' })

    Write-Host "API 后端数量：$($backends.Count)"
    $backends | ForEach-Object { Write-Host "  $_" }

    # 就绪的 API Pod 数与 Service 后端数必须吻合。对不上通常说明 selector 错了，
    # 这正是告警演练里注入的那类故障，让脚本自己发现比事后查更快。
    $readyApiPods = @($rows | Where-Object { $_ -match 'todo-api' -and $_ -match '\s+True\s+Running' }).Count
    if ($backends.Count -ne $readyApiPods) {
        throw "就绪的 API Pod 有 $readyApiPods 个，但 Service 后端有 $($backends.Count) 个，两者不一致。"
    }

    # ---------- 5 耗时 ----------
    Write-Step '耗时'
    $script:steps | Format-Table -AutoSize | Out-String | Write-Host
    $totalSeconds = [math]::Round(((Get-Date) - $script:startedAt).TotalSeconds, 1)
    Write-Host "总耗时：$totalSeconds 秒"

    if ($ready -lt $total) {
        throw "有 $($total - $ready) 个 Pod 未就绪，环境没有完全起来。"
    }

    Write-Host ''
    Write-Host '重建完成。' -ForegroundColor Green
    Write-Host '本机访问接口（另开一个终端，保持前台运行）：'
    Write-Host '  kubectl port-forward service/todo-api 8000:8000 -n cloudp1'
    Write-Host '  kubectl port-forward service/prometheus 9090:9090 -n cloudp1'
    Write-Host '  kubectl port-forward service/grafana 3000:3000 -n cloudp1'
    Write-Host '注意：NodePort 30080 在 Docker Desktop 下不转发到 Windows 主机，只能用端口转发。'
    exit 0
}
catch {
    # 诊断命令本身也可能失败（比如命名空间已不存在），不要再让它们抛异常。
    $ErrorActionPreference = 'Continue'
    Write-Host ''
    Write-Host "失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '--- 诊断信息：cloudp1 里的 Pod 与最近事件 ---'
    kubectl get pods -n cloudp1 2>$null
    kubectl get events -n cloudp1 --sort-by=.metadata.creationTimestamp 2>$null |
        Select-Object -Last 15
    exit 1
}
