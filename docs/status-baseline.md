# 现状基线 2026-11-13

数据采集于 2026-11-12 13:10，文档写于 2026-11-13。下面的状态只对应采集那一刻，之后有变化就重新采一份，不要在这页上改历史。

## 1. 交付形态

这套环境跑在本地 Docker Desktop 内置的 Kubernetes 上，WSL2 虚拟机，单节点，v1.36.1。不是云服务器，没有节点级冗余。机器重启、Docker Desktop 退出或 WSL 重启时，全部 Pod 会被一起重建，这段时间服务不可用。

证据：`evidence/2026-11-12-1310-baseline/02-nodes.txt`

## 2. 各阶段状态

| 阶段 | 状态 | 证据 | 最大风险 |
|---|---|---|---|
| 1 基础设施与集群 | 单节点集群可用，五个 Pod（四个 Deployment）全部 Running；部署靠手工执行 kubectl apply，没有重建脚本；云上未实施，已决定不做 | `02-nodes.txt`、`03-workloads.txt` | 没有重建脚本。Docker Desktop 一旦重启，只能照文档手工恢复，恢复要多久没测过，每次都不一样 |
| 2 容器化与 CI/CD | 镜像构建和推送到 GHCR 已自动化，tag 用提交哈希前 12 位；集群当前运行的仍是手工验证过的旧 tag，CI 产出的镜像从未部署过 | `k8s/api.yaml`、`.github/workflows/container-ci.yml` | 链路没验证过：集群能不能拉到 CI 的镜像、滚动更新是不是真的不停机，都没有实测 |
| 3 可观测性与 SLO | Prometheus 能抓到指标，两条告警规则已加载，Grafana 面板已连通；SLO 没有定义，告警触发耗时从未记录 | `k8s/prometheus.yaml`、`docs/phase-observability.md` | 告警会响，但不知道响得多快。阶段四拿不出可量化的发现耗时 |
| 4 故障演练与文档 | 有一次 Service selector 演练的过程记录和操作手册；五个时间点没记，复盘模板是空的 | `docs/runbook-alert-drill.md`、`docs/phase-observability.md` | 演练结论只有定性描述，撑不住任何量化说法 |

## 3. 已知不一致

### 3.1 清单固定了旧镜像 tag，仓库已经往前走了

- 清单写的是 `ghcr.io/cw-farewell/cloudp1:7a2368f14848`，集群里 Deployment 也是这个 tag，两边一致。
- 但仓库 HEAD 已经是 `21eb364`，比这个 tag 多 5 个提交。CI 会给新提交产出新镜像，只是还没部署。（仓库head是什么）
- 这是有意的版本固定，不是事故。问题在于文档没写明"部署版本不等于仓库最新"，看仓库的人容易以为集群跑的是最新代码。
- 处置：保留固定 tag，在文档里注明；新镜像的部署放到 M1 做。

### 3.2 README 说配了 startupProbe，清单里没有

- `README.md` 第 74 行写的是"Kubernetes 中会分别配置 startup/readiness/liveness probes"。
- 实际 `k8s/api.yaml` 只有 `livenessProbe`（45 行）和 `readinessProbe`（54 行），没有 startupProbe。
- 这句话用的是计划语气，严格说不算虚假描述。但它写在"当前边界"一节里，读者会理解成已经这么做。
- 处置：把措辞改成明确时态；startupProbe 暂时不加，记为待办，触发条件是实测 `/healthz` 冷启动耗时超过 2 秒。

### 3.3 证据文件第一次提交时是 UTF-16

- 首版证据文件是 UTF-16 编码，被 git 判为二进制，在 GitHub 上不能逐行查看，也搜不到内容。
- 已在提交 `21eb364` 里统一改成 UTF-8，现在可以正常检索。
- 历史里那两个二进制版本还在，不打算改写历史。代价是回看那次提交时 diff 仍显示为 Bin，容易让人误以为现在还是二进制。

## 4. 证据索引

| 目录 | 内容 | 证明了什么 |
|---|---|---|
| `evidence/2026-11-12-1310-baseline/` | `00-capture.txt` 采集时刻和客户端版本；`01-context.txt` 上下文；`02-nodes.txt` 节点；`03-workloads.txt` 工作负载；`04-endpoints.txt` 后端地址；`05-events.txt` 最近 40 条事件 | 2026-11-12 13:10 那一刻：集群是单节点的 docker-desktop，五个工作负载都是 Running，todo-api 有两个后端。采集前约 34 分钟发生过一次全量沙箱重建，随后出现 readiness 503 并自行恢复，没有人工干预 |

## 5. 下一阶段的准入条件

下一阶段做 M1：把从提交到部署这条链走通一次。开工前还差三件事。

- 知道 CI 最近一次运行是成功还是失败，以及产出的镜像 tag 是什么。【未测】
- 确认 GHCR 上的镜像包是公开还是私有，集群能不能直接拉取。【未测】
- 回滚手段已具备：`kubectl rollout undo deployment/todo-api -n cloudp1` 可用。

通过标准：集群里运行的镜像 tag 等于本次 CI 产出的 tag，清单已回写为同一个 tag，接口读写正常，部署前后各有证据文件。
