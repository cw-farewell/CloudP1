# GitHub Actions 与 GHCR

工作流位于 `.github/workflows/container-ci.yml`：所有 push/PR 运行 Python 语法检查；push 事件在检查成功后构建镜像，推送事件使用 `ghcr.io/<owner>/<repo>:<commit-sha>` 标签发布到 GitHub Container Registry。PR 不会拿到 GHCR 写入步骤。

## 验证

1. 将 `.github/workflows/container-ci.yml` 提交并推送到 GitHub。
2. 在仓库页面打开 **Actions → Container CI**，等待 `Verify Python` 和 `Build and publish image` 成功。
3. 打开仓库的 **Packages**（或个人/组织的 Packages），确认有以提交 SHA 命名的容器镜像。
4. 若包为私有，GHCR 包页面可设置为 Public（仅当你希望公开镜像时）；公开仓库源码不一定会自动让包公开。

工作流使用仓库自动提供的 `GITHUB_TOKEN`，无需把个人访问令牌保存为 Secret。若将来加 Kubernetes 部署，不要把本机 Docker Desktop kubeconfig 提供给 GitHub 托管 Runner；需要一个 Runner 可达的集群和权限受限的部署凭证。
