# 交付验收（2026-11-18）

按七类材料逐条核对，每类给出证据路径和判定。判定只有三种：PASS / PARTIAL / FAIL。

口径：本项目目标是"本地单节点 Kubernetes 上的可复现交付与可观测演练"，不是生产系统。
下面的结论都限定在这个范围内。

## 一、逐项核对

| # | 材料 | 判定 | 证据 | 说明 |
|---|---|---|---|---|
| 1 | 可重复部署 | PASS | `scripts/bootstrap.ps1`、`docs/cluster-local.md`、`evidence/2026-11-14-2343-rebuild/` | 删除命名空间后 7.8 秒恢复全部就绪；失败路径也验证过（预检缺陷、镜像拉取失败各一次） |
| 2 | CI 记录 | PARTIAL | `.github/workflows/container-ci.yml`、`k8s/api.yaml` 的镜像 tag、`evidence/2026-11-13-1504-rollout/` | 镜像按提交哈希打 tag，可追溯到提交；但 Actions 运行链接存在 GitHub 上，没有归档到仓库内 |
| 3 | 观测面板 | PASS | `k8s/grafana.yaml`、`scripts/check-consistency.ps1` | 七块面板，口径与 SLO 一致；检查脚本确认加载 7 块 |
| 4 | SLO 与实测 | PASS | `docs/slo.md`、`scripts/slo-report.ps1`、`evidence/2026-11-16-1337-load/` | 两条 SLO 有公式、有窗口、有 1200 次长测、有 Wilson 区间 |
| 5 | 演练记录 ×3 | PASS | `docs/drill-2026-11-16-redis-down.md`、`docs/drill-2026-11-18-pod-delete.md`、`docs/drill-2026-11-18-scale-zero.md` | 三场都有时间线与计时，依赖故障做了改进前后对比 |
| 6 | 复盘 | PASS | `docs/drills-summary.md` | 三场横向对比、单点分析、改进项闭环状态；两条改进已复测 |
| 7 | 边界声明 | PASS | `docs/scope.md`、README 首段 | 明确不做什么与原因，限定词固定写明 |

## 二、结论

**有条件可交付。**

条件有三条，都属于"说清楚"而不是"补功能"：

1. **所有量化数字必须与限定词一起出现**：单节点、本地 Docker Desktop、非高可用、Redis 单副本无持久化、告警无通知渠道。单独引用"MTTD 89 秒"而不带这些限定，就是夸大。
2. **耗时的口径必须写明**：7.8 秒重建不含镜像拉取；89 秒和 110 秒是"规则变红"的时间，不是"人收到消息"的时间。
3. **CI 记录需要补一次归档**：把 Actions 的运行链接和耗时写进 `evidence/`，否则第 2 类只能算 PARTIAL。

## 三、不构成交付缺陷、但必须知道的限制

| 限制 | 影响 |
|---|---|
| Redis 单副本、无持久化 | 停掉即业务不可用，恢复后数据丢失。这是当前环境唯一会直接打穿业务的单点 |
| 单节点集群 | 节点故障全部不可用，容器会随 Docker Desktop 重启一起重建（已发生三次） |
| 告警无通知渠道 | `firing` 只等于界面变红，值班流程没有被验证 |
| 依赖外部镜像源 | 网络不通时重建会卡在拉取阶段（11-18 实证） |
| 延迟 SLI 含失败请求 | 直方图无 status 标签，失败请求会拉低延迟达标比例 |

## 四、复现步骤（给别人用）

1. 启动 Docker Desktop，确认 Kubernetes 已启用
2. 确认能拉取 GHCR 与 Docker Hub 镜像（否则配镜像加速器）
3. `.\scripts\bootstrap.ps1`
4. `kubectl port-forward` 打开 Grafana，确认七块面板
5. `.\scripts\check-consistency.ps1 -PrometheusUrl ... -GrafanaUrl ...`，六项应全部 PASS
6. 想验证告警：`.\scripts\drill-redis-down.ps1`，观察 MTTD 是否在 1 到 2 分钟量级

## 五、如果继续做，优先级

1. 归档一次 CI 运行记录（补齐第 2 类）
2. 加黑盒探测，把依赖故障的发现耗时从 89 秒压到秒级
3. Redis 换成带持久化的方案，并做一次故障切换演练

第 1 条半小时，第 2 条两小时，第 3 条会改变架构，需要重新评估边界文档。
