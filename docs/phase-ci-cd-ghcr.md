# 阶段记录：GitHub Actions、GHCR 与 Kubernetes 镜像发布

## 阶段要解决的问题

此前应用已经运行在 Kubernetes 中，但代码更新需要人工构建镜像、标记版本、修改 Deployment 并检查 Pod。步骤容易遗漏，也不容易确认集群正在运行哪个代码版本。

本阶段把代码检查、镜像构建与发布、集群更新串起来，让同一个 Git commit SHA 能追踪到 GHCR 镜像和 Kubernetes Deployment。

## 完成的工作

1. 将项目推送到 GitHub，并保留已有 GitLab remote 配置。
2. 新增 `.github/workflows/container-ci.yml`：
   - `Verify Python` 使用 Python 3.12 对 `app/` 做 `compileall` 语法检查。
   - `Build and publish image` 在 push 事件后构建 Docker 镜像。
   - 工作流以 `GITHUB_TOKEN` 登录 GHCR，按 `ghcr.io/<owner>/<repo>:<12位commit SHA>` 发布镜像。
   - Pull Request 运行语法检查，但不执行有 GHCR 写权限的发布任务。
3. 在 GitHub Actions 中确认 `Container CI` 成功，并在 Packages 中看到 `cloudp1` 容器包。
4. 从包页面取得真实镜像地址和 SHA 标签，使用 `kubectl set image` 更新 Kubernetes 的 API Deployment。
5. 初次部署失败时，利用 Pod 状态、ReplicaSet 和 Events 定位问题。镜像字段误把占位符尖括号也带入：

   ```text
   ghcr.io/cw-farewell>/<cloudp1>:<7a2368f14848>
   ```

   Kubernetes 将其标记为 `InvalidImageName`。替换成合法的真实镜像路径和标签后，rollout 完成，API 可正常访问。

## 发布链路

```text
本地提交并推送
  -> GitHub Actions 执行语法检查
  -> 构建带 commit SHA 标签的容器镜像
  -> 推送到 GHCR
  -> 手动 kubectl set image 更新 Deployment
  -> Kubernetes 拉取镜像并进行滚动更新
  -> 检查 rollout 与 Pod readiness
```

目前 CI 到 Registry 已自动化；GHCR 到 Kubernetes 的部署仍是手动执行。GitHub 托管 Runner 无法直接访问本机 Docker Desktop Kubernetes，因此没有把本地 kubeconfig 放进 GitHub Secrets，也没有开启自动部署。

## 需要理解和能够解释的点

- **Git commit SHA 与镜像 tag 的关系**：SHA tag 指向由那次提交构建出的镜像，便于回溯；避免用含义会漂移的 `latest` 作为唯一版本标识。
- **Actions 权限**：工作流声明 `contents: read` 与 `packages: write`；`GITHUB_TOKEN` 是一次工作流运行使用的凭证，不需要个人 token。
- **PR 与 push 的区别**：PR 可做检查，但来自 fork 的 PR 不应获得发布包的写权限。
- **Registry 与 Kubernetes 的职责**：GHCR 存储镜像；Deployment 声明期望运行的镜像；节点负责拉取镜像并启动 Pod。
- **公共与私有镜像**：公共包可匿名拉取；私有包要为 Kubernetes 配置只读拉取 Secret，不能把凭证提交进仓库。
- **滚动更新**：Deployment 创建新 ReplicaSet/Pod，等待 readiness，通过后逐步替换旧副本；`kubectl rollout status` 等待这个过程达到成功条件。
- **错误分层排查**：`InvalidImageName` 是镜像引用格式错误；`ErrImagePull` / `ImagePullBackOff` 通常指镜像不存在、Registry 网络或认证问题；容器启动后再看日志、探针和应用错误。
- **声明式清单漂移**：`kubectl set image` 改的是集群中的 Deployment，不会自动改 `k8s/api.yaml`。后续要将 tag 纳入声明式配置或 GitOps 流程，避免仓库与集群期望状态不一致。

## 本阶段验证证据

- GitHub Actions 页面：`Container CI` 为成功状态。
- GitHub Packages：存在由 Actions 发布的 `cloudp1` 容器包及 SHA tag。
- Kubernetes：修正镜像地址后 `kubectl rollout status deployment/todo-api -n cloudp1` 成功，API Pod 达到 `1/1 Running`，并通过端口转发访问 API。

## 自测问题

1. 工作流为什么给镜像打 commit SHA tag？如果 Deployment 只写 `latest`，排查或回滚会更困难在哪里？
2. GitHub Actions 的 `GITHUB_TOKEN` 与 Kubernetes 的 `imagePullSecret` 分别用在发布链路的哪一段？两者为什么不能互相替代？
3. 为什么 PR 可以运行语法检查，却不应默认获得 GHCR 写权限？
4. `InvalidImageName`、`ImagePullBackOff` 和容器启动后 `CrashLoopBackOff` 分别提示你从哪一层开始查？
5. 为什么 `kubectl rollout status` 成功比“镜像已经推送到 GHCR”更能说明应用已在集群更新？
6. `kubectl set image` 成功后，Git 仓库中的 `k8s/api.yaml` 是否自动改变？长期如何避免集群配置与 Git 内容漂移？
7. 为什么 GitHub 托管 Runner 无法直接更新本机 Docker Desktop Kubernetes？若要自动部署，需要满足哪些网络与凭证条件？

## 后续工作

- 将 Kubernetes Deployment 的镜像改为仓库中可维护的版本值，减少手工 `set image` 与清单不一致。
- 若做自动部署，先准备 Runner 可访问的目标集群，并配置最小权限、受保护的部署凭证。
- 在 CI 中添加自动化 API/单元测试；当前 `compileall` 只检查语法，不验证业务行为。
- 公开项目时检查 GHCR 包可见性，并清理仓库中的本地 IDE 配置和任何敏感信息。
