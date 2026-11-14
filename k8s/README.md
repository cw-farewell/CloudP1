  # Kubernetes 部署说明

## 这阶段要解决的问题

Compose 适合单机启动；Kubernetes 则通过声明式配置持续维护期望状态。这里演示 API 副本、稳定服务发现、健康探针、资源边界和滚动发布。Redis 仍是单副本，所以本配置用于学习和演示，不提供数据层高可用。

## 请求和控制关系

```text
浏览器/客户端
  -> NodePort 30080
  -> todo-api Service
  -> 任一就绪的 API Pod（Deployment 维护 2 个副本）
  -> redis:6379（Redis Service 的集群 DNS）
  -> Redis Pod
```

- `namespace.yaml`：建立隔离空间 `cloudp1`。
- `redis.yaml`：运行 Redis，并提供稳定的 `redis` Service DNS。
- `api.yaml`：提供 API 配置、2 副本 Deployment 和 NodePort Service。
- API 的 `/healthz` 是存活检查；`/readyz` 会 ping Redis，失败时 Pod 不接收新流量。

## 前置条件

需要 Docker Desktop 已启动，并在 Settings 中启用 Kubernetes；`kubectl` 当前 context 应指向本机集群。先从项目根目录构建镜像：

```powershell
docker compose build api
```

Compose 构建出的镜像名是 `cloudp1-api`。Docker Desktop Kubernetes 通常与本机 Docker 镜像共享镜像存储；如果 Pod 报 `ImagePullBackOff`，检查 `kubectl describe pod`。下面的 GHCR 部署练习会改用 GitHub Actions 发布的镜像。

## 从 GHCR 部署指定版本（本地 Kubernetes）

这一步解决“CI 构建出来的镜像如何由 Kubernetes 实际运行”，并验证镜像版本可追踪。先在 GitHub 仓库 **Packages → cloudp1** 页面确认镜像的完整地址及提交 SHA 标签。工作流生成的地址格式是 `ghcr.io/<小写owner>/<小写repo>:<12位commit-sha>`。

### 推荐方式：将 GHCR 包设为 Public

对公开演示项目，公开容器包最简单，Kubernetes 无需认证即可拉取：

1. 在 GitHub 的 Packages 中打开 `cloudp1`，进入 **Package settings → Change visibility → Public**。只在你确实希望镜像公开时这样设置。
2. 用本次 Actions run 的提交 SHA 组成镜像地址，例如 `ghcr.io/myname/cloudp1:0123456789ab`（用真实 owner 和标签替换示例）。
3. 确保本机 Docker Desktop Kubernetes 已启用。然后执行：

```powershell
$image = "ghcr.io/<小写owner>/<小写repo>:<提交SHA标签>"
kubectl set image deployment/todo-api api=$image -n cloudp1
kubectl rollout status deployment/todo-api -n cloudp1 --timeout=180s
kubectl get pods -n cloudp1
```

4. 两个 API Pod 都为 `1/1 Running` 后，用端口转发验证：

```powershell
kubectl port-forward service/todo-api 8000:8000 -n cloudp1
```

另开一个窗口访问 `http://localhost:8000/healthz` 或 `/docs`。用完后在运行端口转发的窗口按 `Ctrl+C`。

### 如果 GHCR 包保持 Private

需要在本机创建只读权限的 GitHub token（classic PAT，勾选 `read:packages`；若组织启用 SSO，还需按组织流程授权），再创建 namespace 级 `imagePullSecret`：

```powershell
kubectl create secret docker-registry ghcr-pull `
  --namespace cloudp1 `
  --docker-server=ghcr.io `
  --docker-username=<GitHub用户名> `
  --docker-password=<只读token>
```

不要把 token 放进 shell 历史、仓库文件、截图或聊天。更安全的做法是在 PowerShell 提示时读取密钥后通过安全的 Secret 管理流程创建。然后编辑 Deployment 的 Pod template，在 `spec.template.spec` 下添加：

```yaml
imagePullSecrets:
  - name: ghcr-pull
```

之后再执行上面的 `kubectl set image` 和 rollout 检查。若看到 `ImagePullBackOff`，用 `kubectl describe pod -n cloudp1 -l app=todo-api` 查看 Events，核对镜像地址、tag 和拉取权限。

> 通过 `kubectl set image` 做的版本变更保存在集群中，不会自动改仓库里的 `k8s/api.yaml`。后续 GitOps 阶段再把镜像 tag 写回声明式清单，避免集群状态和 Git 配置漂移。

## 部署

从项目根目录依次执行：

```powershell
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/api.yaml
kubectl rollout status deployment/redis -n cloudp1
kubectl rollout status deployment/todo-api -n cloudp1
kubectl get pods,svc -n cloudp1 -o wide
```

NodePort 30080 在 Docker Desktop 下不会转发到 Windows 主机（实测 Test-NetConnection 返回 False），
因此只能用端口转发访问：
```powershell
kubectl port-forward service/todo-api 8000:8000 -n cloudp1
```

再访问 `http://localhost:8000/docs`。

## 观察和练习

查看控制器、事件与日志：

```powershell
kubectl get deployment,replicaset,pods,svc -n cloudp1
kubectl describe pod -n cloudp1
kubectl logs deployment/todo-api -n cloudp1
kubectl get events -n cloudp1 --sort-by=.metadata.creationTimestamp
```

删除一个 API Pod，观察 Deployment 自动创建替代 Pod：

```powershell
kubectl delete pod -n cloudp1 -l app=todo-api
kubectl get pods -n cloudp1 -w
```

改代码后重新构建并重启 Deployment：

```powershell
docker compose build api
kubectl rollout restart deployment/todo-api -n cloudp1
kubectl rollout status deployment/todo-api -n cloudp1
```

删除本阶段资源（会删除 Redis Pod 和其临时容器文件，不会删除其它 namespace）：

```powershell
kubectl delete namespace cloudp1
```

## 重要边界

- Redis 没有 PVC，Pod 被重建或 namespace 删除后数据会丢失；这里优先保持 Demo 易懂。
- 两个 API 副本提升应用层容错，但单节点本地集群或单副本 Redis 仍是单点。
- 远端集群不能直接使用本机镜像；需要推送镜像并配置拉取凭证（凭证不提交到 Git）。
- 公有云部署时下一步再增加 Ingress、TLS、持久化存储与安全组规则。
