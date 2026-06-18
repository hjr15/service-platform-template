#!/usr/bin/env bash
# scripts/argocd-pw.sh — print the initial ArgoCD admin password.

set -euo pipefail

kubectl --context k3d-service-platform -n argocd \
  get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
