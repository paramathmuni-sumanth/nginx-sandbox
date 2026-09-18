#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly DEFAULT_CONTEXT="platform1-dev/ap-south-1/aws-eks"
readonly CONTEXT="${CTX:-$DEFAULT_CONTEXT}"
readonly NAMESPACE="${NAMESPACE:-nginx-sandbox}"
readonly CELIGO_RELEASE="nginx-celigo"
readonly DRAIN_RELEASE="nginx-drain"
readonly POLICY_NAME="poc-prestop-block-exec"
readonly POLICY_FILE="${POLICY_FILE:-${HOME}/Desktop/projects/worktrees/foundational-layers-helm-values/kubearmor-prestop-poc/kubearmor/policies/poc-prestop-block-exec.yaml}"
readonly ARGOCD_NS="${ARGOCD_NS:-argocd}"
readonly ARGOCD_DIR="${SCRIPT_DIR}/argocd"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  validate       Lint and render both releases locally (no cluster access)
  policy         Apply the POC-only KubeArmor policy
  deploy-argocd  Apply the two ArgoCD Applications (preferred)
  deploy         Helm-install both releases (fallback, not Argo)
  status         Show the policy, pods, hooks, and recent failed-hook events
  test           Delete one pod from each release and collect evidence
  cleanup-argocd Delete the two ArgoCD Applications
  cleanup        Helm-uninstall both releases and delete the POC policy/namespace

Environment:
  CTX          Kubernetes context (default: ${DEFAULT_CONTEXT})
  NAMESPACE    POC namespace (default: nginx-sandbox)
  ARGOCD_NS    ArgoCD Applications namespace (default: argocd)
  POLICY_FILE  Absolute path to the POC policy
EOF
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$command_name" >&2
      exit 1
    fi
  done
}

validate() {
  require_commands helm
  helm lint "$CHART_DIR" \
    -f "$CHART_DIR/values.yaml" \
    -f "$SCRIPT_DIR/values-celigo-exec.yaml"
  helm lint "$CHART_DIR" \
    -f "$CHART_DIR/values.yaml" \
    -f "$SCRIPT_DIR/values-httpget-drain.yaml"

  local render_dir
  render_dir="$(mktemp -d "${TMPDIR:-/tmp}/kubearmor-prestop-render.XXXXXX")"
  helm template "$CELIGO_RELEASE" "$CHART_DIR" \
    -f "$CHART_DIR/values.yaml" \
    -f "$SCRIPT_DIR/values-celigo-exec.yaml" \
    > "$render_dir/celigo-exec.yaml"
  helm template "$DRAIN_RELEASE" "$CHART_DIR" \
    -f "$CHART_DIR/values.yaml" \
    -f "$SCRIPT_DIR/values-httpget-drain.yaml" \
    > "$render_dir/httpget-drain.yaml"

  printf 'Rendered manifests: %s\n' "$render_dir"
}

apply_policy() {
  require_commands kubectl
  if [[ ! -f "$POLICY_FILE" ]]; then
    printf 'POC policy not found: %s\n' "$POLICY_FILE" >&2
    exit 1
  fi
  kubectl --context "$CONTEXT" apply -f "$POLICY_FILE"
  kubectl --context "$CONTEXT" get kubearmorclusterpolicy "$POLICY_NAME"
}

deploy_argocd() {
  require_commands kubectl
  kubectl --context "$CONTEXT" get kubearmorclusterpolicy "$POLICY_NAME" >/dev/null
  kubectl --context "$CONTEXT" apply -n "$ARGOCD_NS" -f "$ARGOCD_DIR"
  kubectl --context "$CONTEXT" -n "$ARGOCD_NS" get applications \
    -l poc=kubearmor-prestop
}

deploy() {
  require_commands helm kubectl
  kubectl --context "$CONTEXT" get kubearmorclusterpolicy "$POLICY_NAME" >/dev/null

  helm upgrade --install "$CELIGO_RELEASE" "$CHART_DIR" \
    --kube-context "$CONTEXT" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$CHART_DIR/values.yaml" \
    -f "$SCRIPT_DIR/values-celigo-exec.yaml" \
    --wait \
    --timeout 3m

  helm upgrade --install "$DRAIN_RELEASE" "$CHART_DIR" \
    --kube-context "$CONTEXT" \
    --namespace "$NAMESPACE" \
    -f "$CHART_DIR/values.yaml" \
    -f "$SCRIPT_DIR/values-httpget-drain.yaml" \
    --wait \
    --timeout 3m

  status
}

pod_for_arm() {
  local arm="$1"
  local pod
  pod="$(kubectl --context "$CONTEXT" get pods \
    --namespace "$NAMESPACE" \
    --selector "poc-arm=${arm}" \
    --field-selector status.phase=Running \
    --output jsonpath='{.items[0].metadata.name}')"
  if [[ -z "$pod" ]]; then
    printf 'No running pod found for poc-arm=%s\n' "$arm" >&2
    exit 1
  fi
  printf '%s' "$pod"
}

status() {
  require_commands kubectl helm
  kubectl --context "$CONTEXT" get kubearmorclusterpolicy "$POLICY_NAME"
  kubectl --context "$CONTEXT" -n "$ARGOCD_NS" get applications \
    nginx-celigo nginx-drain \
    --ignore-not-found
  helm list --kube-context "$CONTEXT" --namespace "$NAMESPACE"
  kubectl --context "$CONTEXT" get pods \
    --namespace "$NAMESPACE" \
    --label-columns poc-arm,kubearmor-policy \
    --output wide
  kubectl --context "$CONTEXT" get deployments \
    --namespace "$NAMESPACE" \
    --output jsonpath='{range .items[*]}{.metadata.name}{" => "}{.spec.template.spec.containers[0].lifecycle.preStop}{"\n"}{end}'
  kubectl --context "$CONTEXT" get events \
    --namespace "$NAMESPACE" \
    --field-selector reason=FailedPreStopHook \
    --sort-by=.lastTimestamp || true
}

assert_shell_blocked() {
  local pod="$1"
  local output_file="$2"
  set +e
  kubectl --context "$CONTEXT" exec \
    --namespace "$NAMESPACE" \
    "$pod" \
    -- /bin/sh -c 'echo unexpected-shell-success' \
    >"$output_file" 2>&1
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    printf 'FAIL: /bin/sh was allowed in pod %s\n' "$pod" >&2
    return 1
  fi
  printf 'PASS: /bin/sh was blocked in pod %s (exit=%s)\n' "$pod" "$exit_code"
}

delete_and_capture() {
  local arm="$1"
  local pod="$2"
  local evidence_dir="$3"
  local pod_uid
  local log_pid
  local started_at
  local finished_at

  pod_uid="$(kubectl --context "$CONTEXT" get pod \
    --namespace "$NAMESPACE" \
    "$pod" \
    --output jsonpath='{.metadata.uid}')"

  kubectl --context "$CONTEXT" logs \
    --namespace "$NAMESPACE" \
    --follow \
    "$pod" \
    >"$evidence_dir/${arm}-container.log" 2>&1 &
  log_pid=$!
  sleep 1

  started_at="$(date +%s)"
  kubectl --context "$CONTEXT" delete pod \
    --namespace "$NAMESPACE" \
    "$pod" \
    --wait=true
  finished_at="$(date +%s)"

  wait "$log_pid" 2>/dev/null || true
  printf '%s\n' "$((finished_at - started_at))" >"$evidence_dir/${arm}-termination-seconds.txt"

  kubectl --context "$CONTEXT" get events \
    --namespace "$NAMESPACE" \
    --field-selector "involvedObject.uid=${pod_uid}" \
    --sort-by=.lastTimestamp \
    >"$evidence_dir/${arm}-events.txt" 2>&1 || true
}

test_poc() {
  require_commands kubectl helm
  local evidence_dir
  local celigo_pod
  local drain_pod
  local shell_failure=0

  evidence_dir="${EVIDENCE_DIR:-${TMPDIR:-/tmp}/kubearmor-prestop-poc-$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$evidence_dir"

  celigo_pod="$(pod_for_arm celigo-exec)"
  drain_pod="$(pod_for_arm httpget-drain)"

  kubectl --context "$CONTEXT" get kubearmorclusterpolicy "$POLICY_NAME" \
    --output yaml >"$evidence_dir/policy.yaml"
  kubectl --context "$CONTEXT" get pods \
    --namespace "$NAMESPACE" \
    --output yaml >"$evidence_dir/pods-before.yaml"
  kubectl --context "$CONTEXT" get deployments \
    --namespace "$NAMESPACE" \
    --output yaml >"$evidence_dir/deployments.yaml"

  assert_shell_blocked "$celigo_pod" "$evidence_dir/celigo-shell-exec.txt" || shell_failure=1
  assert_shell_blocked "$drain_pod" "$evidence_dir/drain-shell-exec.txt" || shell_failure=1

  delete_and_capture "celigo-exec" "$celigo_pod" "$evidence_dir"
  delete_and_capture "httpget-drain" "$drain_pod" "$evidence_dir"

  kubectl --context "$CONTEXT" rollout status \
    --namespace "$NAMESPACE" \
    "deployment/${CELIGO_RELEASE}" \
    --timeout=2m
  kubectl --context "$CONTEXT" rollout status \
    --namespace "$NAMESPACE" \
    "deployment/${DRAIN_RELEASE}" \
    --timeout=2m

  {
    printf 'Evidence directory: %s\n\n' "$evidence_dir"
    printf 'Celigo exec termination: %ss\n' "$(cat "$evidence_dir/celigo-exec-termination-seconds.txt")"
    printf 'HTTP drain termination: %ss\n\n' "$(cat "$evidence_dir/httpget-drain-termination-seconds.txt")"
    printf 'Celigo FailedPreStopHook events:\n'
    grep 'FailedPreStopHook' "$evidence_dir/celigo-exec-events.txt" || printf 'NONE\n'
    printf '\nHTTP drain FailedPreStopHook events:\n'
    grep 'FailedPreStopHook' "$evidence_dir/httpget-drain-events.txt" || printf 'NONE\n'
    printf '\nHTTP drain access log:\n'
    grep 'GET /drain ' "$evidence_dir/httpget-drain-container.log" || printf 'GET /drain NOT FOUND\n'
    printf '\nCeligo shell marker (must be absent when blocked):\n'
    grep 'PRESTOP_RAN' "$evidence_dir/celigo-exec-container.log" || printf 'ABSENT\n'
  } | tee "$evidence_dir/summary.txt"

  if [[ "$shell_failure" -ne 0 ]]; then
    printf 'FAIL: policy did not block /bin/sh in both pods\n' >&2
    exit 1
  fi
}

cleanup_argocd() {
  require_commands kubectl
  kubectl --context "$CONTEXT" delete -n "$ARGOCD_NS" -f "$ARGOCD_DIR" --ignore-not-found
}

cleanup() {
  require_commands helm kubectl
  helm uninstall "$CELIGO_RELEASE" \
    --kube-context "$CONTEXT" \
    --namespace "$NAMESPACE" \
    --ignore-not-found
  helm uninstall "$DRAIN_RELEASE" \
    --kube-context "$CONTEXT" \
    --namespace "$NAMESPACE" \
    --ignore-not-found
  kubectl --context "$CONTEXT" delete namespace "$NAMESPACE" --ignore-not-found
  kubectl --context "$CONTEXT" delete kubearmorclusterpolicy "$POLICY_NAME" --ignore-not-found
}

main() {
  case "${1:-}" in
    validate) validate ;;
    policy) apply_policy ;;
    deploy-argocd) deploy_argocd ;;
    deploy) deploy ;;
    status) status ;;
    test) test_poc ;;
    cleanup-argocd) cleanup_argocd ;;
    cleanup) cleanup ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
