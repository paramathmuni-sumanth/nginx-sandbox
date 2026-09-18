# KubeArmor preStop POC findings

## Run metadata

- Date:
- Operator:
- Cluster/context: `platform1-dev/ap-south-1/aws-eks`
- Namespace: `nginx-sandbox`
- nginx-sandbox commit:
- foundational-layers-helm-values commit:
- Evidence directory:
- KubeArmor alert capture:

## Results

| Assertion | Expected | Observed | Pass? |
|---|---|---|---|
| Shell blocked in `nginx-celigo` | `kubectl exec -- /bin/sh` fails | | |
| Shell blocked in `nginx-drain` | `kubectl exec -- /bin/sh` fails | | |
| Celigo preStop starts a shell | KubeArmor denies `/bin/sh` during deletion | | |
| Celigo preStop fails | `FailedPreStopHook`; `PRESTOP_RAN` absent | | |
| HTTP preStop reaches conn-mock | Mock log contains `GET /drain` (port 8080) | | |
| HTTP preStop succeeds | No `FailedPreStopHook` for drain pod UID | | |
| Deployments recover | Both deployments return to `1/1` | | |

## Timing (supporting data only)

- Celigo exec pod deletion:
- HTTP drain pod deletion:

A blocked exec hook may terminate quickly because kubelet proceeds as soon as
the hook fails. The grace period is a ceiling for a running/stuck hook, not a
mandatory delay after every hook error.

## Relevant KubeArmor records

Paste only the records associated with:

1. `nginx-celigo` preStop deletion.
2. Interactive `/bin/sh` against `nginx-celigo`.
3. Interactive `/bin/sh` against `nginx-drain`.

Compare `PodName`, `ProcessName`, `ParentProcessName`, `Source`, `Resource`, and
`Result`. Do not paste unrelated cluster alerts.

## Conclusion

- [ ] The current Celigo `exec` preStop is incompatible with shell blocking.
- [ ] kubelet `httpGet` completes while shell blocking remains enforced.
- [ ] No KubeArmor exception or `kubearmor-debug=true` label is required.
- [ ] The POC drain wait is **conn-mock** (`poc/mock-open-connections.py` on
      :8080), not nginx `:80` and not a real Celigo service.

## Recommendation

Keep KubeArmor changes scoped until application owners agree on a production
graceful-shutdown contract. Candidate contract:

1. Stop readiness/new-work admission.
2. Wait for tracked work to reach zero within an application-owned timeout
   shorter than `terminationGracePeriodSeconds`.
3. Return `2xx`.
4. Let kubelet send SIGTERM.

The route can be `/drain` or a blocking `/stopServer`; the required property is
that it does not return success before the workload is safe to terminate.
