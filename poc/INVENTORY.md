# POC inventory — do not lose these

`conn-mock` is **not** in `helm-charts` or in Celigo microservices. It only
exists on the nginx-sandbox POC branch.

## Repos / worktrees / branches

| Repo | Worktree | Branch | Fork |
|---|---|---|---|
| `nginx-sandbox` | `~/Desktop/projects/worktrees/nginx-sandbox/kubearmor-prestop-poc` | `kubearmor-prestop-poc` | `paramathmuni-sumanth/nginx-sandbox` |
| `foundational-layers-helm-values` | `~/Desktop/projects/worktrees/foundational-layers-helm-values/kubearmor-prestop-poc` | `kubearmor-prestop-poc` | `paramathmuni-sumanth/foundational-layers-helm-values` |

ArgoCD on platform1-dev: Applications `nginx-celigo` and `nginx-drain` in
namespace `argocd`, dest `nginx-sandbox`, `targetRevision: kubearmor-prestop-poc`.

## conn-mock (connection counter)

Sidecar container `conn-mock`, image `python:3.12-alpine`, listen **8080**.

| File | Role |
|---|---|
| `poc/mock-open-connections.py` | Counter: `/openConnections`, `/hold`, `/drain`, `/stopServer` |
| `templates/configmap-conn-mock.yaml` | Mounts that script as `/mock/server.py` |
| `templates/deployment.yaml` | Container `conn-mock` when `connectionMock.enabled` |
| `templates/service.yaml` | Service port `mock` → 8080 |
| `values.yaml` | `connectionMock:` defaults |
| `poc/values-celigo-exec.yaml` | wget `localhost:8080/openConnections` |
| `poc/values-httpget-drain.yaml` | kubelet `httpGet` `/drain` port **8080** |

Not conn-mock (easy to confuse):

| File | Role |
|---|---|
| `templates/configmap.yaml` | nginx `:80` stubs — `/openConnections` here is **always 0** |
| `poc/argocd/*.yaml` | Argo Applications only |
| flhv `kubearmor/policies/poc-prestop-block-exec.yaml` | KubeArmor policy, no HTTP routes |

## What is not in git

- Live `/drain` on real Celigo services — does not exist yet
- Chart default in `celigo/helm-charts` — still `exec` + wget `:5000`
- `test.sh` in this worktree — local leftover; use `poc/run-poc.sh`
