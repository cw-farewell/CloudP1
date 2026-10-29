# 使用轻量 Python 基础镜像；真实部署时建议按架构和安全更新策略维护版本。
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv/app

# 先复制依赖清单，让源码变更时可以复用 Docker 构建缓存。
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# 容器内不以 root 运行，降低应用被攻陷后的权限范围。
RUN useradd --system --no-create-home appuser
USER appuser

EXPOSE 8000

# 使用 exec 形式让 Uvicorn 正确接收容器停止信号。
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
