# 云阶：本地 Kubernetes 上的交付与可观测演练

一个 FastAPI 待办服务加 Redis，在本地单节点 Kubernetes 上跑通「部署 → 观测 → 告警 → 故障演练」这条链，
并且把每一步的测量结果和原始证据留在仓库里。

**先说清楚边界**：这是单节点本地环境（Docker Desktop / WSL2），不是云上部署，不是高可用，
Redis 单副本且无持久化，告警没有通知渠道。所有数字都带口径，不带这四个限定词的说法都是错的。

## 里面有什么

```
app/                  FastAPI 服务：待办接口、健康探针、Prometheus 指标
k8s/                  命名空间、Redis、API、Prometheus、Grafana、黑盒探测器的声明式清单
scripts/              bootstrap 重建、SLO 报告、流量发生器、两场演练脚本、一致性检查
docs/                 范围与边界、SLO 口径、观测说明、三场演练记录与横向复盘
evidence/             按时间归档的原始输出（集群状态、演练时间线、探针日志）
.github/workflows/    GitHub Actions：语法检查 + 按提交哈希构建镜像推到 GHCR
```

## 快速开始

前置条件只有三条：

1. 启动 Docker Desktop，等引擎显示 running
2. Settings → Resources → Kubernetes 勾选启用，等节点 Ready
3. 能拉取 `ghcr.io/cw-farewell/cloudp1` 和 Docker Hub 上的 `prom/prometheus`、`grafana/grafana`、`redis`

> **镜像源是第一个坑。** 如果网络直连不了 Docker Hub，必须先配置可用的镜像加速器，
> 否则重建会卡在 `ImagePullBackOff`。2026-11-18 实测过：加速器返回 500 时，Prometheus 和
> Grafana 拉不下来，而 GHCR 的镜像正常。

```powershell
kubectl config current-context      # 应为 docker-desktop
.\scripts\bootstrap.ps1             # 一条命令重建全部工作负载
```

脚本会依次预检、应用清单、等待四个 Deployment 就绪、打印 Pod 状态与耗时。成功时退出码 0。

访问服务需要端口转发（本环境下 NodePort 30080 不转发到 Windows 主机）：

```powershell
kubectl port-forward service/todo-api 8000:8000 -n cloudp1
kubectl port-forward service/prometheus 9090:9090 -n cloudp1
kubectl port-forward service/grafana 3000:3000 -n cloudp1
```

浏览器打开 `http://localhost:3000`（**注意是 http**，写成 https 会报证书错误），进 CloudP1 文件夹看七块面板。

## 怎么确认环境是对的

```powershell
.\scripts\check-consistency.ps1
```

它对照四件事：清单里的镜像 tag 与集群是否一致、副本数与就绪 Pod 数是否一致、
就绪 Pod 数与 Service 后端数是否一致、告警规则是否已加载。任何一项不符会以非 0 退出。

## 实测数据

全部来自本机，口径写在对应文档里，不做跨机器承诺。

| 项目 | 数值 | 口径 |
|---|---|---|
| 从零重建 | 7.8 秒 | 删命名空间后重建，镜像已在节点，不含拉取 |
| SLO 长测 | 1200 次请求，可用性 100%，95% 区间 [99.68%, 100%] | 1 小时窗口，每秒 1 次 |
| 依赖故障：用户受影响 | 3.3 秒 | Redis 停掉到探针首次 500 |
| 依赖故障：MTTD | 211 秒 → 89 秒 | 规则调优前后，同一场演练 |
| 依赖故障：恢复 | 6.2 秒 | 恢复操作到首次 200 |
| 删一个 API Pod | 0 次失败 / 54 条样本 | 双副本加就绪探针，2 秒内自愈 |
| 整体断流：MTTD | 无告警 → 110 秒 | 补 `absent()` 规则前后 |
| 依赖故障：MTTD（黑盒探测后） | **37 秒** | 每 5 秒探测 /todos，or: 30s |

三场演练的时间线、根因和改进闭环见 `docs/drills-summary.md`。

## 三条踩出来的经验

**一，观测方法本身要验证。** 删 Pod 演练第一次用 `kubectl port-forward` 探测，报告 39 次失败；
换成集群内探针是 0 次。原因是 `port-forward` 的隧道固定在被删的 Pod 上，Pod 一死隧道就断。
**测故障之前先问：观测工具会不会被这次故障波及。**

**二，告警要覆盖「没有数据」。** 比例类规则在空向量上不触发，导致服务整体断流时两条告警全程沉默。
`absent()` 专门补这个洞。

**三，改完 ConfigMap 要重启 Pod。** Prometheus 和 Grafana 都用 `subPath` 挂载配置文件，
`subPath` 不随 ConfigMap 更新刷新。改完必须 `kubectl rollout restart`，否则规则和面板不会生效。

## 常用操作

```powershell
.\scripts\slo-report.ps1                          # SLO 现状与威尔逊区间判定
.\scripts\load-generator.ps1 -Rate 1 -DurationMinutes 20 -Record   # 持续流量
.\scripts\drill-redis-down.ps1 -Record            # 依赖故障演练（带计时）
.\scripts\drill-pod-delete.ps1 -Record            # 删 Pod 自愈演练
```

所有脚本都需要先开启对应 Service 的端口转发，参数见脚本顶部注释。

清理环境：

```powershell
kubectl delete namespace cloudp1
```

会删除 Redis 与 Prometheus 的全部数据，这是预期行为。

## 文档索引

| 文档 | 内容 |
|---|---|
| `docs/scope.md` | 做什么、不做什么、为什么 |
| `docs/cluster-local.md` | 集群重建、已知限制、首次重建失败的原因 |
| `docs/slo.md` | SLO 定义、判定规则、置信区间、已知偏差 |
| `docs/phase-observability.md` | 指标、面板、告警规则与历史上踩过的坑 |
| `docs/drills-summary.md` | 三场演练横向复盘与单点分析 |
| `docs/status-baseline.md` | 某一次的状态快照（带时间，不随代码更新） |
| `docs/timeline-local.md` | 环境与脚本问题的时间线 |

## 明确不做

三节点集群与节点级容灾、反亲和与 PDB、TLS 与域名、多环境、ArgoCD、服务网格、
Alertmanager 通知渠道、高并发压测、云上部署。理由见 `docs/scope.md`。
