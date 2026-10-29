# 云阶：云原生应用交付与可观测运维 Demo

这是项目的最小可运行版本：一个 FastAPI 待办 API、Redis 存储、Docker 镜像和 Docker Compose 本地编排。代码中的中文注释说明了组件职责及后续扩展 Kubernetes 时会用到的设计。

## 整体请求路径

```text
客户端 -> FastAPI (/todos) -> Redis
                     |-> /healthz、/readyz（健康探针）
                     |-> /metrics（Prometheus 指标）
```

`app/main.py` 是服务入口；`Dockerfile` 描述应用镜像；`compose.yaml` 把 API 和 Redis 作为两个服务启动。当前阶段先把应用行为和容器边界跑通，之后再增加 Kubernetes、CI/CD、Grafana Dashboard 和告警规则。

## 本地启动

需要已安装 Docker Desktop 或 Docker Engine 与 Compose 插件：

```bash
docker compose up --build -d
docker compose ps
```

浏览器访问 `http://localhost:8000/docs` 可以交互查看 API。也可用 curl：

```bash
curl http://localhost:8000/healthz
curl http://localhost:8000/readyz
curl -X POST http://localhost:8000/todos \
  -H 'Content-Type: application/json' \
  -d '{"title":"理解容器与健康检查"}'
curl http://localhost:8000/todos
curl http://localhost:8000/metrics
```

停止服务但保留 Redis 数据：

```bash
docker compose down
```

删除服务和本地 Redis 数据卷（会清空数据）：

```bash
docker compose down -v
```

## 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/healthz` | 进程存活检查，不依赖 Redis |
| GET | `/readyz` | 检查 Redis 可用性，供流量就绪判断 |
| POST | `/todos` | 创建待办，JSON body 为 `{"title":"..."}` |
| GET | `/todos` | 列出待办 |
| GET | `/todos/{todo_id}` | 按 ID 查询 |
| PATCH | `/todos/{todo_id}/done` | 标记完成 |
| DELETE | `/todos/{todo_id}` | 删除待办 |
| GET | `/metrics` | Prometheus 格式的请求计数和延迟指标 |

## 阅读顺序

1. 看 `compose.yaml`：理解服务、环境变量、健康检查和数据卷。
2. 看 `app/main.py` 的 `lifespan`：理解应用如何创建并释放 Redis 连接。
3. 看 `/healthz` 与 `/readyz`：区分存活检查和依赖就绪检查。
4. 看待办接口：理解 JSON 模型校验、Redis 键和值的读写。
5. 看 HTTP 中间件和 `/metrics`：理解请求指标如何交给 Prometheus。
6. 看 `Dockerfile`：理解依赖安装、镜像构建缓存和非 root 运行。

## 当前边界

- 这是教学和面试演示用的最小骨架，不包含认证、限流、迁移或生产级数据备份。
- Redis SCAN 适合演示和小数据量；正式业务需要设计索引、分页和并发更新策略。
- Compose 的健康检查只负责本地启动顺序；Kubernetes 中会分别配置 startup/readiness/liveness probes。
- 不要把真实密码、云账号、访问密钥、kubeconfig 或告警接收地址提交到公开仓库。
