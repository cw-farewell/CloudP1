"""FastAPI 服务入口。

这个最小 Demo 把 HTTP 接口、Redis 访问和 Prometheus 指标放在一个模块中，
方便先理解请求如何经过应用；规模增大后再拆分 routers、services 和存储层。
"""

import json
import os
import time
from contextlib import asynccontextmanager
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, HTTPException, Response, status
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, CONTENT_TYPE_LATEST, generate_latest
from redis.asyncio import Redis


# 通过环境变量配置依赖地址，避免把开发机或云上地址写死在代码里。
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
TODO_KEY_PREFIX = "todo:"

# 这些指标由 /metrics 暴露给 Prometheus 抓取。
HTTP_REQUESTS = Counter(
    "todo_http_requests_total", "HTTP 请求总数", ["method", "path", "status"]
)
HTTP_REQUEST_DURATION = Histogram(
    "todo_http_request_duration_seconds",
    "HTTP 请求处理耗时（秒）",
    ["method", "path"],
)


class TodoCreate(BaseModel):
    """创建待办时客户端需要提供的字段。"""

    title: str = Field(min_length=1, max_length=200, description="待办标题")


class Todo(BaseModel):
    """接口返回的待办数据结构。"""

    id: str
    title: str
    done: bool = False


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用启动时建立 Redis 客户端，退出时释放连接池。"""

    app.state.redis = Redis.from_url(REDIS_URL, decode_responses=True)
    try:
        yield
    finally:
        await app.state.redis.aclose()


app = FastAPI(
    title="Cloud Native Todo API",
    description="用于演示容器化、Kubernetes、监控和故障排查的最小服务。",
    version="0.1.0",
    lifespan=lifespan,
    # 改用下方自定义文档路由，以便清楚地区分文档示例和实际响应。
    docs_url=None,
)


@app.get("/docs", include_in_schema=False)
async def custom_swagger_docs() -> HTMLResponse:
    """Swagger UI 文档页：在文档响应示例与真实执行结果间加视觉分隔。"""

    page = get_swagger_ui_html(
        openapi_url=app.openapi_url,
        title=f"{app.title} - Swagger UI",
        swagger_favicon_url="https://fastapi.tiangolo.com/img/favicon.png",
    )
    # Swagger UI 的执行结果区会在点击 Execute 后动态出现，因此用 MutationObserver
    # 监听页面变化；只改文档页 DOM，不影响 API 的响应内容或状态码。
    divider_script = r"""
<style>
  .actual-response-divider {
    border-top: 3px solid #2563eb;
    margin: 24px 0 16px;
    padding-top: 16px;
    color: #1d4ed8;
    font-size: 16px;
    font-weight: 700;
  }
</style>
<script>
(() => {
  const markActualResponse = () => {
    document.querySelectorAll('h4, h3, span, div').forEach((element) => {
      if (element.children.length !== 0 || element.textContent.trim() !== 'Server response') return;
      if (element.dataset.responseDivider === 'added') return;
      element.dataset.responseDivider = 'added';
      const divider = document.createElement('div');
      divider.className = 'actual-response-divider';
      divider.textContent = '实际请求返回结果（Server response）';
      // 紧贴实际结果标题插入，保证分隔线恰好位于示例响应和真实结果之间。
      element.before(divider);
    });
  };
  new MutationObserver(markActualResponse).observe(document.body, { childList: true, subtree: true });
  markActualResponse();
})();
</script>
"""
    html = page.body.decode("utf-8").replace("</body>", f"{divider_script}</body>")
    return HTMLResponse(content=html, status_code=page.status_code)


@app.middleware("http")
async def observe_http_request(request, call_next):
    """统一统计请求数与处理耗时，避免每个业务接口重复埋点。"""

    started_at = time.perf_counter()
    code = status.HTTP_500_INTERNAL_SERVER_ERROR
    try:
        response = await call_next(request)
        code = response.status_code
        return response
    finally:
        # 标签只用固定路由路径，不用 URL 中的动态 ID，避免指标基数失控。
        route = request.scope.get("route")
        path = getattr(route, "path", request.url.path)
        HTTP_REQUESTS.labels(request.method, path, str(code)).inc()
        HTTP_REQUEST_DURATION.labels(request.method, path).observe(
            time.perf_counter() - started_at
        )


def get_redis() -> Redis:
    """从应用状态中读取启动时创建的 Redis 客户端。"""

    return app.state.redis


@app.get("/healthz", tags=["health"])
async def liveness() -> dict[str, str]:
    """存活探针：只确认进程还能响应，不依赖 Redis。"""

    return {"status": "alive"}


@app.get("/readyz", tags=["health"])
async def readiness() -> dict[str, str]:
    """就绪探针：只有 Redis 可用时才让服务接收业务流量。"""

    try:
        await get_redis().ping()
    except Exception as exc:
        # Kubernetes 会据此暂时把这个 Pod 从 Service 后端摘除。
        raise HTTPException(status_code=503, detail="redis is unavailable") from exc
    return {"status": "ready"}


@app.post("/todos", response_model=Todo, status_code=status.HTTP_201_CREATED)
async def create_todo(payload: TodoCreate) -> Todo:
    """生成唯一 ID 并将待办序列化后写入 Redis。"""

    todo = Todo(id=str(uuid4()), title=payload.title)
    await get_redis().set(f"{TODO_KEY_PREFIX}{todo.id}", todo.model_dump_json())
    return todo


@app.get("/todos", response_model=list[Todo])
async def list_todos() -> list[Todo]:
    """扫描待办键并返回数据；小 Demo 易读，生产场景应改用有序索引。"""

    redis: Redis = get_redis()
    todos: list[Todo] = []
    # 使用 SCAN 而不是 KEYS，避免键数量变大时阻塞 Redis 主线程。
    async for key in redis.scan_iter(match=f"{TODO_KEY_PREFIX}*"):
        raw: Any = await redis.get(key)
        if raw is not None:
            todos.append(Todo.model_validate(json.loads(raw)))
    return todos


@app.get("/todos/{todo_id}", response_model=Todo)
async def get_todo(todo_id: str) -> Todo:
    """按 ID 获取待办；缺失时返回标准 404。"""

    raw = await get_redis().get(f"{TODO_KEY_PREFIX}{todo_id}")
    if raw is None:
        raise HTTPException(status_code=404, detail="todo not found")
    return Todo.model_validate_json(raw)


@app.patch("/todos/{todo_id}/done", response_model=Todo)
async def mark_todo_done(todo_id: str) -> Todo:
    """将待办标记为完成，并覆盖 Redis 中保存的 JSON。"""

    redis: Redis = get_redis()
    key = f"{TODO_KEY_PREFIX}{todo_id}"
    raw = await redis.get(key)
    if raw is None:
        raise HTTPException(status_code=404, detail="todo not found")
    todo = Todo.model_validate_json(raw)
    completed = todo.model_copy(update={"done": True})
    await redis.set(key, completed.model_dump_json())
    return completed


@app.delete("/todos/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_todo(todo_id: str) -> Response:
    """删除待办；Redis 返回 0 表示这个 ID 原本不存在。"""

    removed = await get_redis().delete(f"{TODO_KEY_PREFIX}{todo_id}")
    if removed == 0:
        raise HTTPException(status_code=404, detail="todo not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/metrics", include_in_schema=False)
async def metrics() -> Response:
    """Prometheus 以文本格式抓取应用指标。"""

    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
