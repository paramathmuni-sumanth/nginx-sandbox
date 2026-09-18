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
- Nothing in this branch deploys automatically. You invoke each cluster action.

## Files

| File | Purpose |
|---|---|
| `poc/values-celigo-exec.yaml` | Current Celigo shell-based preStop |
| `poc/values-httpget-drain.yaml` | Proposed kubelet `httpGet` preStop |
| `templates/configmap.yaml` | nginx `/openConnections`, `/stopServer`, and `/drain` stand-ins |
| `poc/run-poc.sh` | Validates, deploys, tests, and collects evidence |
| `poc/FINDINGS.md` | Result sheet to complete after the run |

The policy is in the separate worktree:

`~/Desktop/projects/worktrees/foundational-layers-helm-values/kubearmor-prestop-poc/kubearmor/policies/poc-prestop-block-exec.yaml`

## Run

```bash
cd ~/Desktop/projects/worktrees/nginx-sandbox/kubearmor-prestop-poc
chmod +x poc/run-poc.sh

# Local only: lint and render both releases.
./poc/run-poc.sh validate

aws login
export CTX=platform1-dev/ap-south-1/aws-eks

# Cluster actions: run these yourself, in order.
./poc/run-poc.sh policy
./poc/run-poc.sh deploy
./poc/run-poc.sh status
```

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
./poc/run-poc.sh cleanup
```

If the policy was merged into `platform1-dev`, remove it through Git and let
Argo prune it instead of deleting it manually.
