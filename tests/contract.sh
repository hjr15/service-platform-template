#!/usr/bin/env bash
# tests/contract.sh — dependency contract between this template (consumer)
# and lab-soe (upstream host-tooling prerequisite).
#
# Two checks:
#   1. PATH check    — every `role: core` tool in ./tools.yaml resolves on
#                      PATH. This is a HOST check; it only makes sense on a
#                      machine that has been provisioned (via lab-soe's
#                      bootstrap.sh or this repo's scripts/install-deps.sh).
#                      Skipped when CONTRACT_DIFF_ONLY=1 (e.g. on a bare CI
#                      runner — see .github/workflows/contract.yml).
#   2. Version diff  — pull lab-soe's public tools.yaml, intersect by tool
#                      name, and FAIL when a tool that is `core` HERE is
#                      concretely pinned on BOTH sides to DIFFERENT versions.
#                      Floating ("latest") pins can't diverge, so they're
#                      skipped. Divergence on non-core shared tools is a
#                      warning, not a failure.
#
# lab-soe is always the upstream we validate against, never the reverse.
#
# Env:
#   CONTRACT_DIFF_ONLY=1     skip the PATH check (CI / off-host)
#   LAB_SOE_TOOLS_URL=<url>  override the upstream manifest URL
#   LAB_SOE_TOOLS_FILE=<f>   read the upstream manifest from a local file
#                            (offline / testing) instead of curl
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
MANIFEST="${REPO_ROOT}/tools.yaml"
LAB_SOE_TOOLS_URL="${LAB_SOE_TOOLS_URL:-https://raw.githubusercontent.com/hjr15/lab-soe/main/tools.yaml}"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
ylw()   { printf '\033[1;33m%s\033[0m\n' "$*"; }
info()  { printf '       %s\n' "$*"; }

command -v yq  >/dev/null 2>&1 || { red "yq not on PATH — needed to read $MANIFEST"; exit 2; }
[ -f "$MANIFEST" ] || { red "manifest not found: $MANIFEST"; exit 2; }

# Strip a leading 'v' so v4.45.1 and 4.45.1 compare equal.
norm() { printf '%s' "${1#v}"; }

fail=0

# ── Check 1: core tools on PATH ──────────────────────────────────────
if [ "${CONTRACT_DIFF_ONLY:-0}" = "1" ]; then
  ylw "PATH check: skipped (CONTRACT_DIFF_ONLY=1)"
else
  echo "PATH check — core tools must resolve:"
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    if command -v "$tool" >/dev/null 2>&1; then
      grn "  ✓ $tool"
    else
      red "  ✗ $tool — not on PATH"
      fail=1
    fi
  done < <(yq -r '.tools[] | select(.role=="core") | .name' "$MANIFEST")
fi

# ── Check 2: version divergence vs lab-soe ───────────────────────────
echo "Version contract — diffing shared tools against lab-soe:"
LABSOE_YAML="$(mktemp)"
trap 'rm -f "$LABSOE_YAML"' EXIT

if [ -n "${LAB_SOE_TOOLS_FILE:-}" ]; then
  cp "$LAB_SOE_TOOLS_FILE" "$LABSOE_YAML" || { red "LAB_SOE_TOOLS_FILE not found: $LAB_SOE_TOOLS_FILE"; exit 2; }
  info "source: $LAB_SOE_TOOLS_FILE (local override)"
elif curl -fsSL "$LAB_SOE_TOOLS_URL" -o "$LABSOE_YAML" 2>/dev/null; then
  info "source: $LAB_SOE_TOOLS_URL"
else
  ylw "  could not fetch lab-soe manifest ($LAB_SOE_TOOLS_URL) — skipping diff"
  [ "$fail" -eq 0 ] && grn "contract: OK (diff skipped)" || red "contract: FAILED"
  exit "$fail"
fi

while IFS=$'\t' read -r name ours role; do
  [ -n "$name" ] || continue
  theirs="$(name="$name" yq -r '.tools[] | select(.name == strenv(name)) | .version' "$LABSOE_YAML" 2>/dev/null || true)"
  [ -n "$theirs" ] && [ "$theirs" != "null" ] || continue          # not shared
  # Floating pins can't meaningfully diverge, so we skip them. NOTE: this
  # means a tool the template pins but lab-soe floats (k3d/helm/kubectl
  # today) is never failed on here — the deliberate trade-off to avoid a
  # perpetually-red test (see INF-348). The PATH check + Renovate cover those.
  if [ "$ours" = "latest" ] || [ "$theirs" = "latest" ]; then
    info "~ $name: ours=$ours theirs=$theirs (floating — not compared)"
    continue
  fi
  if [ "$(norm "$ours")" = "$(norm "$theirs")" ]; then
    grn "  ✓ $name: $ours (matches lab-soe)"
  elif [ "$role" = "core" ]; then
    red "  ✗ $name: ours=$ours vs lab-soe=$theirs — CORE tool diverges"
    fail=1
  else
    ylw "  ! $name ($role): ours=$ours vs lab-soe=$theirs — divergence (non-core, allowed)"
  fi
done < <(yq -r '.tools[] | [.name, .version, .role] | @tsv' "$MANIFEST")

echo
if [ "$fail" -eq 0 ]; then
  grn "contract: OK"
else
  red "contract: FAILED"
fi
exit "$fail"
