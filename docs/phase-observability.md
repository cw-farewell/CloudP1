# 阶段记录：Prometheus、Grafana 与告警演练

## 目标

把 API 已有的 `/metrics` 接入 Prometheus，使用 Grafana 展示请求指标，并验证告警规则能发现采集故障、在恢复后解除。

## 组件关系

```text
API 中间件记录请求指标
  -> /metrics 暴露 Prometheus 文本格式
  -> Prometheus 每 15 秒按 Pod 发现，逐个抓取 API Pod 的 /metrics 并保存时间序列
  -> Grafana 使用 Prometheus 数据源查询并展示面板
  -> Prometheus 根据规则评估告警状态
```

- `k8s/prometheus.yaml`：Prometheus 配置、Deployment、Service，以及两条告警规则。
- `k8s/grafana.yaml`：Grafana 数据源、仪表盘配置、Deployment 和 Service。
- `app/main.py`：定义请求计数器和耗时 Histogram，并由 HTTP 中间件更新；`/metrics` 调用 `generate_latest()` 输出。
- 本机访问 UI 使用 `kubectl port-forward`；Prometheus 通过 `kubernetes_sd_configs` 发现 Pod，直接抓 Pod IP，不经过 Service，两条网络路径不同。

## 本阶段完成

1. Prometheus 按 Pod 发现抓取，两个 API Pod 各有一个 target，状态都是 `UP`，PromQL 能按 `instance` 查到各自的 `todo_http_requests_total`。
2. Grafana 连接 Prometheus，并显示按 path/status 汇总的 API 请求速率面板。
3. Prometheus 加载 `TodoApiScrapeAvailabilityLow` 与 `TodoApiHigh5xxRate`，规则组和规则健康状态正常。
4. 临时改动 API Service selector 制造采集失败；告警进入 `firing`。恢复为 `app: todo-api` 后，Endpoints 恢复，告警在时间窗口重新评估后变为 `inactive`。

## 遇到的问题与处理

### Grafana 面板空白

数据源和面板引用的 UID 不一致。为 Prometheus 数据源显式设置 UID `prometheus`，与 dashboard JSON 一致后面板显示数据。

### Prometheus 因规则文件挂载失败

日志报 `/etc/prometheus/alerts.yml` 是目录。原因是整个 ConfigMap 目录挂载和单文件挂载产生路径冲突。改为用 `subPath` 分别挂载 `prometheus.yml` 与 `alerts.yml` 后，Pod 成功启动并加载规则。

### 端口转发拒绝连接

`kubectl port-forward` 找到了 Pod，但容器内没有监听 9090。查看 Pod、Service Endpoint 和 Prometheus 日志后发现 Pod 启动失败；这不是本机端口号错误。

### kubectl 连接与 Namespace 错误

Docker Desktop Kubernetes 关闭时，kubectl 无法访问 API Server。集群恢复后若 `cloudp1` Namespace 不存在，需要先创建 Namespace，再部署 Redis、API、Prometheus 和 Grafana。启动集群本身不会自动恢复 Namespace 资源。

### PowerShell patch JSON 引号问题

多种内联 JSON 写法传给 `kubectl patch` 后引号丢失。通过检查 Service 的 `spec.selector` 发现实际配置仍然是 `app: todo-api`。本次演练使用 `kubectl edit` 修改 selector，并在恢复后确认 Endpoints 有两个 API 后端。

### 抓取范围错误：两个副本混成一个 target（2026-11-15 修复）

早期配置把抓取目标写成 `todo-api:8000`，也就是 Service DNS。Service 后面有两个 Pod，
Prometheus 每次抓取可能落到不同的一个，而 `instance` 标签只有 `todo-api:8000` 这一个值。
两个 Pod 的计数器因此共用同一个 series 身份，Prometheus 看到的是计数器忽增忽减。

后果是查询结果不可信：`/todos` 的 P95 返回 `NaN`，速率对业务路径恒为 0；而探针流量一直在，
`up` 也是 1，面板上看起来"有曲线"，问题很隐蔽。

定位方式：查 `up{job="todo-api"}` 的 `instance` 只有一个值；再分别对两个 Pod 直连 `/metrics`，
一个有 42 条 `/todos` 相关序列，另一个是 0 条。证据在 `evidence/2026-11-14-2359-scrape-scope/`。

修复：给 Prometheus 建 ServiceAccount、Role、RoleBinding（只允许读本命名空间的 pods），
抓取配置改成 `kubernetes_sd_configs` 的 `role: pod`，限制命名空间，用 relabel 只保留
`app=todo-api` 且声明了 `http` 端口的 Pod，`instance` 改成 Pod 名。

修复后：两个 target 都是 `UP`，P95 返回具体数值（样例 0.0048 秒），计数按 Pod 分开。
证据在 `evidence/2026-11-15-1050-scrape-fix/`。

另一个观察：通过 `kubectl port-forward` 到 Service 造流量时，全部请求会落在同一个 Pod，
因为 port-forward 只建立一条 TCP 连接，Service 按连接做负载均衡。要覆盖两个副本，
需要多开连接或直接对每个 Pod 做转发。

### 告警恢复延迟

可用性表达式使用 5 分钟窗口，抓取间隔 15 秒，并有 `for: 1m`。恢复后历史窗口仍含 `up=0` 样本，所以告警不会立即解除；等窗口滚动并重新评估后转为 `inactive`。

## 面板（2026-11-16 补齐为 7 块）

| # | 面板 | 类型 | 回答的问题 |
|---|---|---|---|
| 1 | API 请求速率（按 path/status） | 时序 | 请求有没有在来，错误在增加还是只是量下降 |
| 2 | 待办业务 API 请求延迟 P95 | 时序 | 慢不慢 |
| 3 | API 可用性（2xx 占比） | 数值 | 与 SLO-1 同口径的即时可用性，阈值 99%/95%；无业务流量时显示 No data |
| 4 | 5xx 比例 | 数值 | 服务端错误占比，阈值 1%/5%；无业务流量时显示 No data，有流量无错误时显示 0% |
| 5 | 采集中的 API 实例数 | 数值 | `sum(up{job="todo-api"})` 应为 2，掉到 1 或 0 即异常 |
| 6 | 最近 5 分钟 2xx 与 5xx 速率 | 时序 | 两条曲线对照，区分"错误变多"和"流量变小" |
| 7 | 抓取状态（每 Pod） | 时序 | 每个 Pod 的 `up`，断流时最先掉的就是它 |

三个操作要点：

- **改完必须重启 Grafana。** Deployment 用 `subPath` 挂载单个 dashboard 文件，`subPath` 不会随
  ConfigMap 更新而刷新。`kubectl apply` 之后要 `kubectl rollout restart deployment/grafana -n cloudp1`，
  否则界面上还是旧面板。2026-11-16 就出现过一次：apply 完打开 Grafana 显示找不到 dashboard，
  重启后才加载出 7 块。
- **面板数字有 15 到 30 秒延迟。** 抓取间隔 15 秒，`rate()` 窗口 5 分钟，刚发完请求时数值可能还是
  0 或 No data，等一个采集周期再看，不要立刻判断配置错了。
- **可用性面板与 docs/slo.md 同口径**：排除 `/healthz`、`/readyz`、`/metrics`，分子只用 2xx。
## 告警与 SLO 边界

- `TodoApiScrapeAvailabilityLow` 的 `up` 衡量 Prometheus 抓取 `/metrics` 是否成功，不等于用户完整业务可用。
- `TodoApiHigh5xxRate` 衡量当前观测到的 5xx 比例；低流量下比例可能不稳定。
- 99%、5%、5 分钟和持续时间是教学阈值，不是业务承诺或正式 SLO。
- 当前没有配置 Alertmanager 和通知接收器，告警只在 Prometheus 中可见。
- API 指标能正常抓取时，Redis 或特定业务接口仍可能失败；后续可用真实业务探测补足。

## 复现与验证命令

部署（Docker Desktop Kubernetes 已启动）：

```powershell
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/api.yaml
kubectl apply -f k8s/prometheus.yaml
kubectl apply -f k8s/grafana.yaml
kubectl get pods -n cloudp1
```

访问 Prometheus：

```powershell
kubectl port-forward service/prometheus 9090:9090 -n cloudp1
```

另一个终端可查询规则：

```powershell
(Invoke-RestMethod http://localhost:9090/api/v1/rules).data |
  ConvertTo-Json -Depth 8
```

访问 Grafana（另开终端）：

```powershell
kubectl port-forward service/grafana 3000:3000 -n cloudp1
```

浏览器打开 `http://localhost:3000`，进入 CloudP1 文件夹查看仪表盘。故障演练结束后，必须确认 Service selector 为 `app: todo-api`，并验证：

```powershell
kubectl get service todo-api -n cloudp1 -o yaml
kubectl get endpoints todo-api -n cloudp1
```

## 复盘闭环

故障演练的预检、注入、观察、强制恢复和复盘模板见 [runbook-alert-drill.md](runbook-alert-drill.md)。

- **问题：**应用指标尚无持续采集、可视化和故障告警。
- **依据：**源码指标定义、Prometheus target、PromQL 结果、Grafana 面板、规则 API、Pod/Service 状态和日志。
- **变更：**新增 Prometheus 与 Grafana 清单、数据源/仪表盘及告警规则。
- **故障：**面板 UID 不一致、规则文件挂载冲突、API Server 暂不可用、selector patch 引号失败。
- **根因与修复：**记录在上方问题列表；以服务状态、Endpoint、target 和规则状态确认修复，不以命令成功作为唯一证据。
- **结果：**故障期间告警 `firing`；恢复后 Endpoints 重新包含两个 API Pod，规则最终 `inactive`。
- **后续行动：**考虑增加端到端业务探测、为延迟指标设计面板与目标；只有确定需要发送通知和接收渠道后再部署 Alertmanager。

## 理解检查

1. `up=1` 能证明什么，不能证明什么？
2. 为什么告警条件恢复后还要等一段时间才变为 `inactive`？
3. `kubectl port-forward` 的失败为什么需要同时检查 Pod 和 Service Endpoint？

## 一个必须记住的教训：0/0 不是 0%

面板第一次上线时，第 3 块在没有任何业务请求的情况下显示「0.00%，红色」。
原因不是查询写错，是表达式里用了 `clamp_min(分母, 0.001)`：

```
0 / 0.001 = 0
```

它把"没有请求"变成了"可用性为 0%"。这两件事完全不同：前者是不知道，后者是服务全挂。
把不知道显示成最坏情况，会让人误判，也会让面板失去可信度。

修复方式：

- 去掉 `clamp_min`，让分母为 0 时结果为 NaN，Grafana 显示 No data
- 分子加 `or vector(0)`，保证"有流量但没有 5xx"时正确显示 0%，而不是也变成 No data

三种情形现在的表现：

| 情形 | 修复前 | 修复后 |
|---|---|---|
| 没有业务流量 | 0.00% 红色 | No data |
| 有流量，全部 2xx | 100% | 100% |
| 有流量，部分 5xx | 比例 | 比例 |

另外第 6 块原来统计所有路径，包含探针。探针每秒都在跑，图上永远有一条 0.8 req/s 的线，
看着像业务在跑，其实一条业务请求都没有。现在只统计业务路径。
