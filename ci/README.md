# CI/CD 阶段：提交代码到 Kubernetes

## 为什么加这一阶段

之前需要手动构建镜像、补标签、修改 Deployment 并观察 Pod。步骤分散，容易漏做，也难以回答“集群现在跑的是哪次提交”。本阶段把检查、镜像构建与推送、Kubernetes 更新和 rollout 确认串成流水线，并用 Git commit SHA 作为镜像版本。

## 流水线

```text
提交代码
  -> verify-python：检查 Python 语法
  -> build-and-push：构建并推送 $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  -> 默认分支 deploy-kubernetes：更新 Deployment 并等待 rollout
```

非默认分支只检查并构建镜像；默认分支会继续自动部署。流水线由 `.gitlab-ci.yml` 定义。

## 一次性准备

1. 将项目推送到 GitLab，并启用项目 Container Registry。
2. 配置 GitLab Runner，启用 Docker-in-Docker 所需的 privileged 模式；Runner 需能访问 GitLab Registry。
3. 在 GitLab 项目 **Settings → CI/CD → Variables** 添加 `KUBECONFIG_FILE`，类型选择 **File**，值为目标集群 kubeconfig。启用 Masked/Protected（若 GitLab 版本允许）并仅在受信任的默认分支发布。
4. 目标集群需已部署 `cloudp1` namespace 与 `todo-api` Deployment。授予该 kubeconfig 的身份最小权限：只允许在 `cloudp1` 更新 Deployment、读取 rollout 状态。
5. 目标集群的节点必须能拉取 GitLab Registry 私有镜像。若仓库为私有，在 namespace 创建 `imagePullSecret`，并在 Deployment 的 Pod template 配置 `imagePullSecrets`；不要把 registry 密码提交到仓库。

## 本机集群限制

GitLab.com 托管 Runner 在云端，无法访问开发者电脑的 Docker Desktop Kubernetes。因此本地阶段可验证 `verify-python` 和 `build-and-push`，但完整自动部署需要可从 Runner 网络访问的集群（例如部署在云上），或自托管于可信网络内的 Runner。不要把本机 kubeconfig 或集群凭据交给公共 Runner。

## 发布与回滚

默认分支每次提交会构建独立 SHA 镜像，部署 Job 用 `kubectl set image` 更新 Deployment，并等待 rollout 成功。失败时流水线失败并保留之前的 ReplicaSet。排查可看 GitLab Job 日志以及：

```powershell
kubectl rollout history deployment/todo-api -n cloudp1
kubectl describe deployment/todo-api -n cloudp1
kubectl get pods -n cloudp1
```

确认当前集群 context 后，可运行 `scripts/rollback-k8s.ps1` 回退到上一修订。回滚仍需验证接口和数据依赖状态。

## 成功标准

- 每次提交生成可追溯的 commit SHA 镜像。
- 默认分支流水线能更新 API Deployment，并以 rollout 成功作为发布完成条件。
- 发布失败能从 Job 日志定位阶段；可通过 rollout history 和回滚脚本恢复上一个版本。

此配置不会自动创建云资源。kubeconfig、Registry 凭证和集群地址均由 GitLab/集群外部安全配置提供。
