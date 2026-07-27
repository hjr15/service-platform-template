#!/usr/bin/env bash
# scripts/k8s-up.sh — bootstrap a single k3d cluster + ArgoCD + workloads.
#
# Idempotent: re-running brings the cluster to the desired state without
# duplication.

set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────
CLUSTER="service-platform"
K3S_IMAGE="rancher/k3s:v1.31.4-k3s1"
ARGOCD_CHART_VERSION="9.5.10"
ARGOCD_NS="argocd"
KUBE_CTX="k3d-${CLUSTER}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES_FILE="${REPO_ROOT}/argocd/values-dev.yaml"
ROOT_APP_FILE="${REPO_ROOT}/deploy/argocd/service-platform-root-app.yaml"
ENV_FILE="${REPO_ROOT}/.env"

log()  { printf '\033[1;34m[k8s-up]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[k8s-up]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[k8s-up]\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Phase 0: prerequisites ──────────────────────────────────────────
log "Phase 0: checking prerequisites"

# argocd CLI is NOT required here — the script drives everything with helm
# and kubectl. install-deps.sh still installs it for interactive debugging.
for bin in k3d helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not on PATH. Run ./scripts/install-deps.sh"
done

[ -f "$ENV_FILE" ] || fail ".env not found. Run ./scripts/init-env.sh first."

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

for var in DOMAIN N8N_ENCRYPTION_KEY VAULTWARDEN_ADMIN_TOKEN; do
  [ -n "${!var:-}" ] || fail ".env is missing $var (re-run ./scripts/init-env.sh)"
done

# repoURL gate: ArgoCD deploys whatever repo the Application manifests name.
# If you forked but didn't rewrite repoURL, ArgoCD watches the upstream
# template (which your pushes never reach) and your changes never deploy.
# Warn only when origin is NOT the upstream — the template's own owner runs
# this legitimately with the upstream repoURL.
ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo '')"
if grep -rqs 'hjr15/service-platform-template' "${REPO_ROOT}/deploy/argocd" \
   && [[ "$ORIGIN_URL" != *"hjr15/service-platform-template"* ]]; then
  warn "ArgoCD manifests still reference 'hjr15/service-platform-template'."
  warn "Forked? Point every repoURL at your fork before continuing:"
  warn "  find deploy/argocd -name '*.yaml' -exec sed -i 's|hjr15/service-platform-template|<you>/<fork>|g' {} +"
  warn "See docs/setup.md Step 1. (Ignore this if it really is your repo.)"
fi

# ─── Phase 1: create k3d cluster ─────────────────────────────────────
log "Phase 1: creating k3d cluster '$CLUSTER' (idempotent)"

if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER"; then
  log "  cluster already exists — skipping create"
else
  k3d cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    -p "127.0.0.1:80:80@loadbalancer" \
    -p "127.0.0.1:443:443@loadbalancer" \
    --wait
fi

kubectl config use-context "$KUBE_CTX" >/dev/null
log "  active context: $KUBE_CTX"

# ─── Phase 2: install ArgoCD ─────────────────────────────────────────
log "Phase 2: installing ArgoCD chart $ARGOCD_CHART_VERSION (upstream — argo-helm)"

kubectl get ns "$ARGOCD_NS" >/dev/null 2>&1 || kubectl create ns "$ARGOCD_NS"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo 2>/dev/null

helm upgrade --install argo-cd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace "$ARGOCD_NS" \
  -f "$VALUES_FILE" \
  --set "global.domain=argocd.${DOMAIN}" \
  --set "server.ingress.hostname=argocd.${DOMAIN}" \
  --wait --timeout 5m

log "  helm upgrade: ok"
kubectl -n "$ARGOCD_NS" rollout status deploy/argo-cd-argocd-server --timeout=5m

# ─── Phase 3: bootstrap workload secrets ─────────────────────────────
log "Phase 3: applying workload secrets from .env"

kubectl get ns n8n >/dev/null 2>&1 || kubectl create ns n8n
kubectl apply -n n8n -f - <<NS
apiVersion: v1
kind: Secret
metadata:
  name: n8n-secrets
  namespace: n8n
type: Opaque
stringData:
  N8N_ENCRYPTION_KEY: "${N8N_ENCRYPTION_KEY}"
NS

kubectl get ns vaultwarden >/dev/null 2>&1 || kubectl create ns vaultwarden
kubectl apply -n vaultwarden -f - <<NS
apiVersion: v1
kind: Secret
metadata:
  name: vaultwarden-secrets
  namespace: vaultwarden
type: Opaque
stringData:
  ADMIN_TOKEN: "${VAULTWARDEN_ADMIN_TOKEN}"
NS

log "  n8n-secrets: ok"
log "  vaultwarden-secrets: ok"

# ─── Phase 4: apply root app-of-apps ─────────────────────────────────
log "Phase 4: applying service-platform-root Application"

kubectl apply -f "$ROOT_APP_FILE"
log "  applied: service-platform-root"

echo
log "✅ ArgoCD ready. ArgoCD will reconcile cert-manager + the 3 workloads (~5 min)."
log "   Watch: argocd app list  /  kubectl get app -n argocd"
log "   Get admin password: ./scripts/argocd-pw.sh"
log "   Get /etc/hosts entries: ./scripts/print-hosts-entries.sh"
