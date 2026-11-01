# 手动回滚 API Deployment 到 Kubernetes 保存的上一条成功修订。
# 先确认目标集群和 namespace，避免误操作其他环境。
kubectl config current-context
kubectl rollout history deployment/todo-api -n cloudp1
kubectl rollout undo deployment/todo-api -n cloudp1
kubectl rollout status deployment/todo-api -n cloudp1
