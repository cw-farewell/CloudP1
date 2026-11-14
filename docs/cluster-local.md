# 本地集群：重建与访问

这套环境跑在本地 Docker Desktop 内置的 Kubernetes 上（WSL2，单节点，v1.36.1）。
用途是学习与演示，不是生产环境：没有节点级冗余，Redis 和 Prometheus 都没有持久卷。

## 前置条件

- Docker Desktop 已启动，设置里启用了 Kubernetes
- `kubectl` 可用，`kubectl config current-context` 输出 `docker-desktop`
- 仓库完整（`k8s/` 下五个清单文件存在）
- 能从 GHCR 拉取 `ghcr.io/cw-farewell/cloudp1`（包是公开的）

## 执行方式

```powershell
cd E:\CloudProject\CloudP1
.\scripts\bootstrap.ps1
```

若提示禁止运行脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1
```

脚本只做创建或对齐，不删除任何资源，可以重复执行。想验证"从零重建"，先删除命名空间：

```powershell
kubectl delete namespace cloudp1 --timeout=240s
.\scripts\bootstrap.ps1
```

## 预期输出

依次出现五段：预检通过、五个 `apply`、四个 `successfully rolled out`、Pod 就绪 `5 / 5`、一张耗时表。
最后打印总耗时和三行端口转发命令，退出码 0。

失败时打印失败原因，附 Pod 列表和最近 15 条事件，退出码 1。

## 实测数据（2026-11-14 23:43，Docker Desktop 已运行，镜像已在节点上）

| 阶段 | 耗时 | 说明 |
|---|---|---|
| 删除命名空间 | 9.7 秒 | `kubectl delete namespace cloudp1 --timeout=240s` |
| 重建（脚本自报） | 7.8 秒 | 预检 0.3 + 应用清单 1.5 + 等待就绪 5.5 |
| 重建（墙钟） | 8.2 秒 | 含 powershell 进程启动 |
| 从删到可用 | 约 18 秒 | 两个数相加，不是同一进程内的连续测量 |

重建后 `/healthz` 与 `/readyz` 均返回 200，Service 后端 2 个，镜像 `77481d1fab6e`。

**这些数字的统计口径**：单次测量，镜像已在节点本地（`IfNotPresent` 命中，没有发生拉取），
Docker Desktop 与 WSL2 已经预热。如果镜像需要重新拉取，或者 Docker Desktop 刚启动，
耗时会更长，目前没有测过。

## 重建后会丢什么

- Redis 里的待办数据全部清空（无持久卷）
- Prometheus 的历史指标全部清空，Grafana 面板初期没有数据，需要等采集积累
- Pod 名称和 IP 会变，Service 名称和端口不变

这些都是预期行为，不是故障。

## 已知限制

- **NodePort 不能从 Windows 主机访问。** 30080 端口由 WSL2 内的节点监听，不转发到主机。
  实测 `Test-NetConnection 127.0.0.1 -Port 30080` 返回 False。访问只能用端口转发：

  ```powershell
  kubectl port-forward service/todo-api 8000:8000 -n cloudp1
  kubectl port-forward service/prometheus 9090:9090 -n cloudp1
  kubectl port-forward service/grafana 3000:3000 -n cloudp1
  ```

- **Docker Desktop 重启会重建全部容器。** 11-12 和 11-14 各发生过一次，详见 `docs/timeline-local.md`。
- **`kubectl diff` 不可用。** 本机没有 `diff.exe`，需要比较时用 `kubectl get -o yaml` 存档后比对。

## 首次从零重建失败的原因（2026-11-14）

第一次执行 `kubectl delete namespace cloudp1` 后跑脚本，预检阶段就失败，退出码 1：

```
失败：Error from server (NotFound): namespaces "cloudp1" not found
```

原因：预检要判断命名空间是否停在 `Terminating`，做法是查询它的 phase。
命名空间不存在时 kubectl 把 `NotFound` 写到 stderr，而脚本设置了
`$ErrorActionPreference = 'Stop'`，这条 stderr 被当成终止错误抛出，于是预检直接失败。

修复：新增 `Get-NamespacePhase`，内部临时把 `$ErrorActionPreference` 降为 `Continue`，
只按退出码判断，不存在时返回空字符串。修复后同一条命令退出码 0，总耗时 7.8 秒。

证据：`evidence/2026-11-14-2343-rebuild/03-bootstrap-failure.txt`（失败那次）与
`04-bootstrap.txt`（修复后那次）。

## 不再做的事

节点高可用、反亲和、PodDisruptionBudget、TLS 与域名、Ingress、多环境、GitOps。
这些在单节点演示环境里无法真实验证，写进文档会造成误导。
