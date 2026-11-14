# 现状基线 2026-11-13

数据采集于 2026-11-12 13:10，文档写于 2026-11-13。下面的状态只对应采集那一刻，之后有变化就重新采一份，不要在这页上改历史。

## 1. 交付形态

这套环境跑在本地 Docker Desktop 内置的 Kubernetes 上，WSL2 虚拟机，单节点，v1.36.1。不是云服务器，没有节点级冗余。机器重启、Docker Desktop 退出或 WSL 重启时，全部 Pod 会被一起重建，这段时间服务不可用。

证据：`evidence/2026-11-12-1310-baseline/02-nodes.txt`

## 2. 各阶段状态

| 阶段 | 状态 | 证据 | 最大风险 |
|---|---|---|---|
| 1 基础设施与集群 | 单节点集群可用；有了一键重建脚本，实测从零到全部就绪 7.8 秒（镜像已在节点）；云上未实施，已决定不做 | `scripts/bootstrap.ps1`、`docs/cluster-local.md`、`evidence/2026-11-14-2343-rebuild/` | 单节点无容灾。Docker Desktop 重启会重建全部容器，11-12 与 11-14 各一次；重建后 Redis 与 Prometheus 数据清空 |
| 2 容器化与 CI/CD | 镜像构建和推送到 GHCR 已自动化，tag 用提交哈希前 12 位；集群当前运行的仍是手工验证过的旧 tag，CI 产出的镜像从未部署过 | `k8s/api.yaml`、`.github/workflows/container-ci.yml` | 链路没验证过：集群能不能拉到 CI 的镜像、滚动更新是不是真的不停机，都没有实测 |
| 3 可观测性与 SLO | Prometheus 能抓到指标，两条告警规则已加载，Grafana 面板已连通；SLO 没有定义，告警触发耗时从未记录 | `k8s/prometheus.yaml`、`docs/phase-observability.md` | 告警会响，但不知道响得多快。阶段四拿不出可量化的发现耗时 |
| 4 故障演练与文档 | 有一次 Service selector 演练的过程记录和操作手册；五个时间点没记，复盘模板是空的 | `docs/runbook-alert-drill.md`、`docs/phase-observability.md` | 演练结论只有定性描述，撑不住任何量化说法 |

## 3. 已知不一致

### 3.1 清单固定了旧镜像 tag，仓库已经往前走了（已关闭 2026-11-13）

- 关闭依据：清单与集群都指向 `77481d1fab6e`，两条命令输出一致，见 `evidence/2026-11-13-1504-rollout/02-after.txt`。
- 遗留：每次新提交都会产生新镜像，清单不会自动跟随。这是刻意的版本固定，处置办法是每次部署后手动回写 tag。

### 3.2 README 说配了 startupProbe，清单里没有

- `README.md` 第 74 行写的是"Kubernetes 中会分别配置 startup/readiness/liveness probes"。
- 实际 `k8s/api.yaml` 只有 `livenessProbe`（45 行）和 `readinessProbe`（54 行），没有 startupProbe。
- 这句话用的是计划语气，严格说不算虚假描述。但它写在"当前边界"一节里，读者会理解成已经这么做。
- 处置：把措辞改成明确时态；startupProbe 暂时不加，记为待办，触发条件是实测 `/healthz` 冷启动耗时超过 2 秒。

### 3.3 证据文件第一次提交时是 UTF-16

- 首版证据文件是 UTF-16 编码，被 git 判为二进制，在 GitHub 上不能逐行查看，也搜不到内容。
- 已在提交 `21eb364` 里统一改成 UTF-8，现在可以正常检索。
- 历史里那两个二进制版本还在，不打算改写历史。代价是回看那次提交时 diff 仍显示为 Bin，容易让人误以为现在还是二进制。

### 3.4 NodePort 无法从 Windows 主机访问

- `k8s/api.yaml` 使用 NodePort 30080，但节点跑在 WSL2 里，端口不转发到 Windows 主机。
- 实测：`Test-NetConnection 127.0.0.1 -Port 30080` 返回 False；改用 `kubectl port-forward` 后访问正常。
- 影响：文档里"访问 localhost:30080"的说法在本环境不成立。
- 处置：`k8s/README.md` 的说明已改成结论，明确只能用端口转发。

## 4. 证据索引

| 目录 | 内容 | 证明了什么 |
|---|---|---|
| `evidence/2026-11-12-1310-baseline/` | `00-capture.txt` 采集时刻和客户端版本；`01-context.txt` 上下文；`02-nodes.txt` 节点；`03-workloads.txt` 工作负载；`04-endpoints.txt` 后端地址；`05-events.txt` 最近 40 条事件 | 2026-11-12 13:10 那一刻：集群是单节点的 docker-desktop，五个工作负载都是 Running，todo-api 有两个后端。采集前约 34 分钟发生过一次全量沙箱重建，随后出现 readiness 503 并自行恢复，没有人工干预 |

## 5. 下一阶段的准入条件

M1 已完成：集群跑的是 CI 产物 `77481d1fab6e`，清单已回写，接口读写正常，前后证据在 `evidence/2026-11-13-1504-rollout/`。

M2 已完成：`scripts/bootstrap.ps1` 支持一键重建，删命名空间后实测 7.8 秒恢复，失败路径也验证过（第一次从零重建因预检缺陷退出码 1，修复后通过），说明写在 `docs/cluster-local.md`。

下一阶段做 M3：补齐延迟指标，做一块能回答"现在服务好不好"的面板。开工前还差三件事。

- 确认 `/metrics` 里直方图的指标名与标签，Prometheus 已经抓到，但没有任何查询和面板用过它。
- 确定面板要展示哪几个数：请求速率、5xx 比例、p95 延迟、目标就绪状态。
- 面板配置要能入库。Grafana 现在通过 ConfigMap 提供 provisioning，改动需要写回 `k8s/grafana.yaml`，不能在界面上改完就算完成。

通过标准：面板上的每个数字都能对应到一条 PromQL，面板配置在仓库里，重建后能自动恢复。
