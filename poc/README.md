# KubeArmor block-exec vs. preStop hook — POC (platform1-dev)

## The question

The `celigo/helm-charts` microservice chart ships this preStop by default:

```yaml
preStop:
  exec:
    command: ["sh", "-c", "... wget ... /openConnections ... /stopServer ..."]
```

The `block-exec` KubeArmorClusterPolicy blocks `/bin/sh`, `/usr/bin/sh`, `/bin/busybox` and
`/usr/bin/busybox` in `di, ia, io, core, ui`. If an `exec` preStop trips that policy, every pod
termination in those namespaces loses connection draining and runs to the full
`terminationGracePeriodSeconds` before SIGKILL — on every deploy, scale-down and node rotation.

This POC answers two things:

1. Does an `exec` preStop actually get blocked?
2. Can KubeArmor distinguish a preStop exec from an interactive `kubectl exec`?
   (If not, `fromSource` whitelisting is impossible and `httpGet` is the only fix.)

## Safety

- The POC policy is `poc-prestop-block-exec`, scoped to the **`nginx-sandbox` namespace only**.
  The live `block-exec` policy is not modified.
- Nothing here targets `di/ia/io/core/ui`.
- The KubeArmor Argo app runs `prune: true, selfHeal: true`. Never hand-edit `block-exec` on the
  cluster — Argo reverts it within minutes and you will misread your results.

## Arms

| Arm | Policy applies? | preStop | Expected |
|-----|-----------------|---------|----------|
| A — control | no (`kubearmor-debug=true`) | `exec` shell | hook runs, fast termination |
| B — enforced | yes | `exec` shell | **hook blocked**, ~60s to terminate |
| C — fix | yes | `httpGet` | hook runs, fast termination |

Arm A is the harness check. **If Arm A fails, stop** — the test is broken, not the policy.

## Prerequisites

```bash
aws login                      # session expires often
CTX=platform1-dev/ap-south-1/aws-eks
kubectl --context $CTX get pods -n kubearmor
```

Deploy the POC policy by merging this branch of `foundational-layers-helm-values`
(`kubearmor-prestop-poc` → `platform1-dev`) and letting Argo sync, then confirm:

```bash
kubectl --context $CTX get kubearmorclusterpolicy poc-prestop-block-exec
```

## Capturing KubeArmor alerts

`kubearmorRelay.enabled: false` in platform1-dev values, so plain `karmor logs` finds nothing.
Talk to the node agent directly:

```bash
AGENT=$(kubectl --context $CTX get pod -n kubearmor -l kubearmor-app=kubearmor \
  -o jsonpath='{.items[0].metadata.name}')
kubectl --context $CTX port-forward -n kubearmor $AGENT 32767:32767 &
karmor logs --gRPC localhost:32767 --json | tee /tmp/armor-poc.jsonl
```

Start this **before** deleting pods.

## Running an arm

Arms share one release, so run them sequentially.

```bash
CTX=platform1-dev/ap-south-1/aws-eks
ARM=a-control        # then b-enforced, then c-httpget

helm upgrade --install nginx-sandbox . \
  --kube-context $CTX \
  -n nginx-sandbox --create-namespace \
  -f values.yaml -f poc/values-arm-$ARM.yaml

kubectl --context $CTX rollout status -n nginx-sandbox deploy/nginx-sandbox

POD=$(kubectl --context $CTX get pod -n nginx-sandbox -l app.kubernetes.io/name=nginx-sandbox \
  -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CTX logs -n nginx-sandbox $POD -f > /tmp/poc-$ARM.log 2>&1 &
time kubectl --context $CTX delete pod -n nginx-sandbox $POD --wait=true

grep PRESTOP_RAN /tmp/poc-$ARM.log || echo "NO PRESTOP MARKER"
kubectl --context $CTX get events -n nginx-sandbox \
  --field-selector reason=FailedPreStopHook --sort-by=.lastTimestamp | tail -5
```

For Arm C the marker never appears by design — the kubelet makes the HTTP call, so look for the
`GET /` in the nginx access log instead, and confirm no `FailedPreStopHook` event.

## Also test the intended behaviour still works

```bash
kubectl --context $CTX exec -n nginx-sandbox $POD -- /bin/sh -c "echo hi"; echo "rc=$?"
```

Non-zero is correct — that is the attack path the policy exists to stop.

## Reading the result

| Observation | Meaning |
|---|---|
| A runs, B blocked, C runs | Collision confirmed, `httpGet` is the fix |
| A blocked too | Harness broken — check the `kubearmor-debug` label landed |
| B runs | Policy not applied — check namespace selector and Argo sync |
| C blocked | Unexpected; capture the alert, `httpGet` should spawn no process |

## The decisive comparison

```bash
jq -r 'select(.Resource | test("sh"))
       | [.Timestamp, .PodName, .ProcessName, .ParentProcessName, .Source, .Result]
       | @tsv' /tmp/armor-poc.jsonl
```

Compare the Arm B (preStop) record against the `kubectl exec` record. If `ParentProcessName` and
`Source` are indistinguishable, **no `fromSource` rule can allow one without allowing the other** —
which makes `httpGet` migration plus an interim `Audit` posture the only viable path. If they
differ, a narrow whitelist is worth pursuing.

`matchArgs: true` is already set in platform1-dev values, so `Resource` carries full argv. Even
where enforcement cannot distinguish the two, telemetry can — which is what makes an Audit-mode
baseline usable as evidence.

## Cleanup

```bash
helm uninstall nginx-sandbox --kube-context $CTX -n nginx-sandbox
kubectl --context $CTX delete ns nginx-sandbox
```

Then revert the policy by removing `kubearmor/policies/poc-prestop-block-exec.yaml` from the
`platform1-dev` branch and letting Argo prune it.
