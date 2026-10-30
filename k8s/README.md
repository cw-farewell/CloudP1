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

Compose 构建出的镜像名是 `cloudp1-api`。Docker Desktop Kubernetes 通常与本机 Docker 镜像共享镜像存储；如果 Pod 报 `ImagePullBackOff`，检查 `kubectl describe pod`。远端集群必须将镜像推送到集群可访问的 Registry，再把 `api.yaml` 的镜像名改为完整仓库地址。

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

访问 `http://localhost:30080/docs`。如果本机 Kubernetes 不支持 localhost NodePort，可用端口转发：

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
