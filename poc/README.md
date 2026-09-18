# KubeArmor preStop POC — platform1-dev

Two one-replica nginx releases run in `nginx-sandbox`. They use the same
KubeArmor policy and differ only in their preStop handler.

| Release | preStop | Expected evidence |
|---|---|---|
| `nginx-celigo` | Current Celigo `exec` → `sh` → wget loop | KubeArmor denies `/bin/sh`; `FailedPreStopHook`; `PRESTOP_RAN` absent |
| `nginx-drain` | `httpGet /drain` | nginx logs `GET /drain`; no failed-hook event |

Both replacement pods must reject `kubectl exec -- /bin/sh`. This proves the
HTTP solution does not weaken shell enforcement.

> Timing is supporting data, not the assertion. Kubernetes starts the
> termination grace-period clock before preStop, but a hook denied immediately
> normally fails immediately and termination continues. A hook that remains
> stuck is bounded by the grace period (plus Kubernetes' small one-off
> extension), after which the container is forcibly terminated.

## Scope and limitations

- The POC policy selects only the `nginx-sandbox` namespace.
- The existing policy for `di`, `ia`, `io`, `core`, and `ui` is not changed.
- `/drain` is implemented by this chart's nginx ConfigMap and returns `200`
  immediately. It proves the kubelet HTTP path, not production connection
  draining.
- Real services still need a blocking app endpoint (or equivalent design) that
  stops admission, waits for tracked work, and returns success before the
  grace-period deadline.
- You apply the two ArgoCD Applications yourself. Do not change the live
  `nginx-sandbox` Application on `main`.

## Files

| File | Purpose |
|---|---|
| `poc/values-celigo-exec.yaml` | Current Celigo shell-based preStop |
| `poc/values-httpget-drain.yaml` | Proposed kubelet `httpGet` preStop |
| `templates/configmap.yaml` | nginx `/openConnections`, `/stopServer`, and `/drain` stand-ins |
| `poc/run-poc.sh` | Validates, tests, and collects evidence |
| `poc/argocd/nginx-celigo.yaml` | ArgoCD Application for the Celigo shell hook |
| `poc/argocd/nginx-drain.yaml` | ArgoCD Application for the httpGet `/drain` hook |
| `poc/FINDINGS.md` | Result sheet to complete after the run |

The policy is in the separate worktree:

`~/Desktop/projects/worktrees/foundational-layers-helm-values/kubearmor-prestop-poc/kubearmor/policies/poc-prestop-block-exec.yaml`

## Mock open connections

nginx `:80/openConnections` is still a stub (`0`). PreStop uses `conn-mock` on **:8080**.

| Path | Behaviour |
|---|---|
| `GET /openConnections` | current count (in-flight `/hold` requests) |
| `GET /hold?seconds=25` | count +1, sleep 25s, count −1 |
| `GET /drain` | wait until count is 0, then 200 |
| `GET /stopServer` | 200 `stopping` |

```bash
kubectl --context "$CTX" -n nginx-sandbox port-forward svc/nginx-drain 8080:8080 &
curl "http://127.0.0.1:8080/openConnections"; echo    # 0
curl "http://127.0.0.1:8080/hold?seconds=40" &         # count becomes 1
sleep 1
curl "http://127.0.0.1:8080/openConnections"; echo    # 1
kubectl --context "$CTX" -n nginx-sandbox delete pod -l poc-arm=httpget-drain --wait=true
```

While `/hold` is running, `/drain` must not return until that hold finishes (or 50s).

## Run

```bash
cd ~/Desktop/projects/worktrees/nginx-sandbox/kubearmor-prestop-poc
chmod +x poc/run-poc.sh

# Local only: lint and render both releases.
./poc/run-poc.sh validate

aws login
export CTX=platform1-dev/ap-south-1/aws-eks

# 1. POC-only policy (nginx-sandbox namespace). Do not edit live block-exec.
./poc/run-poc.sh policy

# 2. Two ArgoCD Applications. Apply after this branch is on origin.
./poc/run-poc.sh deploy-argocd
./poc/run-poc.sh status
```

Wait until both Applications are `Synced`/`Healthy` in ArgoCD (`default` project),
or:

```bash
kubectl --context "$CTX" -n argocd get applications nginx-celigo nginx-drain
kubectl --context "$CTX" -n nginx-sandbox get deploy,pods -l poc-arm
```

Leave the existing `nginx-sandbox` Application on `main` alone. These two apps
use different Helm release names (`nginx-celigo`, `nginx-drain`).

If Argo prunes a manually applied policy, merge the
`foundational-layers-helm-values` branch `kubearmor-prestop-poc` into
`platform1-dev` and wait for the `kubearmor` Application to sync. Do not edit
the live `block-exec` policy.

## Capture KubeArmor alerts

Run this in a second terminal before the test:

```bash
AGENT=$(kubectl --context "$CTX" get pod -n kubearmor \
  -l kubearmor-app=kubearmor \
  -o jsonpath='{.items[0].metadata.name}')

kubectl --context "$CTX" port-forward -n kubearmor "$AGENT" 32767:32767 &
karmor logs --gRPC localhost:32767 --json |
  tee /tmp/kubearmor-prestop-alerts.jsonl
```

Then run:

```bash
./poc/run-poc.sh test
```

The script prints the evidence directory. Copy its observations into
`poc/FINDINGS.md` and attach the relevant KubeArmor records.

## Pass criteria

| Assertion | Pass |
|---|---|
| Policy applies to both pods | `/bin/sh` via `kubectl exec` is denied on both |
| Celigo hook collides with policy | Celigo pod has `FailedPreStopHook`; marker absent; KubeArmor records `/bin/sh` denial |
| HTTP hook bypasses process execution safely | nginx records `GET /drain`; no failed-hook event |
| Workloads recover | Deployments return to `1/1` after both test pods are deleted |

Wall-clock duration is recorded for context only. Do not fail the POC merely
because the blocked hook terminates faster than 60 seconds.

## Cleanup

```bash
# Deletes the two Argo Applications (finalizer prunes their workloads).
# Does not delete the live nginx-sandbox Application or the namespace.
./poc/run-poc.sh cleanup-argocd
kubectl --context "$CTX" delete kubearmorclusterpolicy poc-prestop-block-exec
```

If the policy was merged into `platform1-dev`, remove it through Git and let
Argo prune it instead of deleting it manually.
