#!/usr/bin/env bash
# scripts/k8s-reset.sh — destructive: delete + recreate the cluster.
# Workload data WILL be lost (PVCs deleted with the cluster).

set -euo pipefail

read -p "This deletes ALL data in the local cluster. Type 'yes' to continue: " confirm
[ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/k8s-down.sh"
"$SCRIPT_DIR/k8s-up.sh"
