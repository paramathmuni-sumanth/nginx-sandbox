# KubeArmor preStop POC — two nginx apps on platform1-dev

Two Helm releases in `nginx-sandbox`. Same policy. Different preStop.

| Release | preStop | Expected on `kubectl delete pod` |
|---|---|---|
| `nginx-celigo` | Celigo `exec sh` + wget `/openConnections` | **Blocked** · ~60s · `FailedPreStopHook` · no `PRESTOP_RAN` |
| `nginx-drain` | `httpGet /drain` | **Runs** · a few seconds · `GET /drain` in logs · no failed hook |

Both pods must still reject `kubectl exec -- sh`. That is the policy working.

`/drain` here is **this chart’s nginx config**, not an app-team endpoint. Body is always `drained`. It only proves kubelet can finish preStop without spawning `sh`.

## 0. Login

```bash
aws login
CTX=platform1-dev/ap-south-1/aws-eks
kubectl --context $CTX get pods -n kubearmor
```

## 1. Policy (once)

Do **not** hand-edit live `block-exec`. Argo will revert it.

Apply the POC policy from the other worktree. If Argo prunes it, merge
`foundational-layers-helm-values` branch `kubearmor-prestop-poc` into `platform1-dev`
and wait for the kubearmor Application to sync.

```bash
kubectl --context $CTX apply -f \
  ~/Desktop/projects/worktrees/foundational-layers-helm-values/kubearmor-prestop-poc/kubearmor/policies/poc-prestop-block-exec.yaml

kubectl --context $CTX get kubearmorclusterpolicy poc-prestop-block-exec
```

Confirm it selects namespace `nginx-sandbox` and excludes `kubearmor-debug=true`.

## 2. Alerts (leave running)

```bash
AGENT=$(kubectl --context $CTX get pod -n kubearmor -l kubearmor-app=kubearmor \
  -o jsonpath='{.items[0].metadata.name}')
kubectl --context $CTX port-forward -n kubearmor $AGENT 32767:32767 &
karmor logs --gRPC localhost:32767 --json | tee /tmp/armor-poc.jsonl
```

## 3. Both apps

```bash
cd ~/Desktop/projects/worktrees/nginx-sandbox/kubearmor-prestop-poc

helm upgrade --install nginx-celigo . \
  --kube-context $CTX \
  -n nginx-sandbox --create-namespace \
  -f values.yaml -f poc/values-celigo-exec.yaml

helm upgrade --install nginx-drain . \
  --kube-context $CTX \
  -n nginx-sandbox \
  -f values.yaml -f poc/values-httpget-drain.yaml

kubectl --context $CTX get pods -n nginx-sandbox -o wide
```

You should see one `nginx-celigo-*` and one `nginx-drain-*`.

## 4. Sanity: /drain and /openConnections exist

```bash
CELIGO=$(kubectl --context $CTX get pod -n nginx-sandbox -l poc-arm=celigo-exec -o jsonpath='{.items[0].metadata.name}')
DRAIN=$(kubectl --context $CTX get pod -n nginx-sandbox -l poc-arm=httpget-drain -o jsonpath='{.items[0].metadata.name}')

# httpGet into the pod network namespace without a shell — if this fails, fix the ConfigMap first
kubectl --context $CTX exec -n nginx-sandbox $DRAIN -- wget -qO- http://127.0.0.1/drain; echo
kubectl --context $CTX exec -n nginx-sandbox $CELIGO -- wget -qO- http://127.0.0.1/openConnections; echo
```

`exec wget` may itself be blocked (busybox). If exec is denied, skip this and go to step 5 —
kubelet’s `httpGet` does not use exec.

## 5. Delete both, time them

```bash
kubectl --context $CTX logs -n nginx-sandbox $CELIGO > /tmp/poc-celigo.log &
kubectl --context $CTX logs -n nginx-sandbox $DRAIN > /tmp/poc-drain.log &

echo "=== celigo exec preStop ==="
time kubectl --context $CTX delete pod -n nginx-sandbox $CELIGO --wait=true

echo "=== httpGet /drain ==="
time kubectl --context $CTX delete pod -n nginx-sandbox $DRAIN --wait=true
```

Then:

```bash
grep PRESTOP_RAN /tmp/poc-celigo.log || echo "NO PRESTOP_RAN on celigo (expected if blocked)"
grep drain /tmp/poc-drain.log || echo "look for GET /drain in drain pod logs"

kubectl --context $CTX get events -n nginx-sandbox \
  --field-selector reason=FailedPreStopHook --sort-by=.lastTimestamp | tail -10
```

| | celigo | drain |
|---|---|---|
| wall clock | ~60s | a few seconds |
| `PRESTOP_RAN` | absent | n/a (no shell) |
| access log `GET /drain` | no | yes |
| `FailedPreStopHook` | yes | no |

## 6. Policy still blocks shells

After the deployments recreate pods:

```bash
CELIGO=$(kubectl --context $CTX get pod -n nginx-sandbox -l poc-arm=celigo-exec -o jsonpath='{.items[0].metadata.name}')
DRAIN=$(kubectl --context $CTX get pod -n nginx-sandbox -l poc-arm=httpget-drain -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CTX exec -n nginx-sandbox $CELIGO -- /bin/sh -c 'echo hi'; echo "celigo rc=$?"
kubectl --context $CTX exec -n nginx-sandbox $DRAIN -- /bin/sh -c 'echo hi'; echo "drain rc=$?"
```

Non-zero on **both** is success.

## Cleanup

```bash
helm uninstall nginx-celigo --kube-context $CTX -n nginx-sandbox
helm uninstall nginx-drain --kube-context $CTX -n nginx-sandbox
kubectl --context $CTX delete ns nginx-sandbox
kubectl --context $CTX delete kubearmorclusterpolicy poc-prestop-block-exec
```

If the policy was merged to `platform1-dev`, remove the file there and let Argo prune.

## What this does *not* prove

Real Celigo services still need a **blocking** `/drain` (or equivalent) in process code.
This nginx `/drain` always returns 200 immediately. It only answers: does `httpGet`
survive `block-exec`.
