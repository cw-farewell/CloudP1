capture_time : 2026-11-18 09:45
purpose      : 删 Pod 演练第一次尝试，用 kubectl port-forward 探测
result       : 报告 39 次失败（错误结论）
root_cause   : port-forward 的 TCP 连接固定在被删除的 Pod 上，Pod 一删隧道即断，探针收到 000
correction   : 改用集群内探针后为 0 次失败，见 evidence/2026-11-18-0946-drill-pod-delete/ 与 docs/drill-2026-11-18-pod-delete.md
keep_reason  : 保留这次误判，作为'观测方法本身会影响结论'的实证
