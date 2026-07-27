#!/usr/bin/env bash
# scripts/k8s-down.sh — delete the k3d cluster (preserves nothing).

set -euo pipefail

CLUSTER="service-platform"

if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER"; then
  k3d cluster delete "$CLUSTER"
  echo "✅ Cluster '$CLUSTER' deleted."
else
  echo "Cluster '$CLUSTER' not found — nothing to delete."
fi
