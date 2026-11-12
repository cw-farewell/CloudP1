# 本地告警演练操作手册

> 仅用于 Docker Desktop 本地学习集群。故障注入会让 API Service 暂时没有后端；演练前确认没有其他使用者。不要在生产环境照搬。

## 目的与影响

验证 Prometheus 抓取失败告警能否触发，以及 Service 恢复后告警能否解除。演练通过修改 `todo-api` Service 的 selector 让它暂时找不到 API Pod；Deployment、Pod 和 Redis 数据不作改动。

## 安全约束

- 操作者保持两个终端：一个查看 Prometheus，另一个执行 kubectl。
- 记录演练开始时间，并记下原 selector（预期 `app: todo-api`）。
- 故障期间不要对 `k8s/api.yaml` 执行 `kubectl apply`，它会把 selector 恢复为清单中的 `app: todo-api`，导致实验提前结束。
- 若意外中断或不确定当前状态，第一优先级是恢复 selector，然后验证 Endpoints。
- 不删除 Namespace、Pod 或数据，不操作凭证。

## A. 预检（任一项不符合就停止）

```powershell
kubectl config current-context
kubectl get nodes
kubectl get pods -n cloudp1
kubectl get service todo-api -n cloudp1 -o yaml
kubectl get endpoints todo-api -n cloudp1
```

确认 context 为 `docker-desktop`、节点 `Ready`、API Pod 就绪、selector 为 `app: todo-api`，且 Endpoints 有 API Pod 地址。记录输出和时间。

确认 Prometheus 当前健康：在一个终端运行并保持：

```powershell
kubectl port-forward service/prometheus 9090:9090 -n cloudp1
```

另一个终端执行：

```powershell
(Invoke-RestMethod 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22todo-api%22%7D').data.result
```

预检应有结果且 value 为 `1`。记录告警初始状态（预期 inactive）。

## B. 注入故障

使用 `kubectl edit` 避免 PowerShell 内联 JSON 引号转义问题：

```powershell
kubectl edit service todo-api -n cloudp1
```

只把 `spec.selector.app` 从 `todo-api` 改成 `todo-api-drill`，保存退出。不要改其它字段。

立即核对：

```powershell
kubectl get service todo-api -n cloudp1 -o yaml
kubectl get endpoints todo-api -n cloudp1
```

应看到 selector 为 `todo-api-drill`，Endpoints 为空。若 selector 仍为 `todo-api`，故障没有注入成功，不要声称告警测试通过。若发生意外，跳到恢复步骤。

## C. 观察告警

Prometheus 每 15 秒抓取，规则以 5 分钟窗口计算并设置 `for: 1m`。因此保持 selector 故障至少约 6 分钟，再查看：

- `http://localhost:9090/targets`：todo-api target 是否 DOWN。
- `http://localhost:9090/alerts` 或规则 API：`TodoApiScrapeAvailabilityLow` 是否从 inactive 到 pending/firing。

记录故障注入时间、Endpoints、target、告警状态和观察时间。若没有按预期变化，不要延长故障无限等待；进入恢复，再依据证据调查。

## D. 恢复（无论告警是否触发都必须做）

```powershell
kubectl edit service todo-api -n cloudp1
```

将 `spec.selector.app` 改回 `todo-api`，保存退出。随后验证：

```powershell
kubectl get service todo-api -n cloudp1 -o yaml
kubectl get endpoints todo-api -n cloudp1
kubectl get pods -n cloudp1 -l app=todo-api
```

selector 应为 `app: todo-api`，Endpoints 应重新列出就绪 API Pod 地址。再检查 Prometheus target 回到 UP。等待 5 分钟窗口滚动和规则重新评估后，告警预期回到 inactive。

若 Service selector 已正确但 Endpoints 为空，检查 API Pod 标签和 readiness：

```powershell
kubectl get pods -n cloudp1 -l app=todo-api --show-labels
kubectl describe pod -n cloudp1 -l app=todo-api
kubectl get events -n cloudp1 --sort-by=.metadata.creationTimestamp
```

## 通过标准

- 故障前：selector 正确、Endpoints 有后端、target UP、告警 inactive。
- 故障中：selector 不匹配、Endpoints 为空、target DOWN、可用性告警 firing。
- 恢复后：selector 恢复、Endpoints 有后端、target UP、告警最终 inactive。

每项都要记录实际证据；若任何一项不符合，结论写“未通过/部分通过”并说明差异，不要用预期代替实际观察。

## 复盘模板

- 演练日期与开始/结束时间：
- 预期影响与范围：
- 故障前证据：selector、Endpoints、target、告警
- 注入操作与故障中证据：
- 告警触发耗时：
- 恢复操作与恢复证据：
- 告警解除耗时：
- 预期与实际差异：
- 根因（区分证据与推测）：
- 后续改进及验收标准：
