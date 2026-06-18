#!/usr/bin/env bash
# scripts/init-env.sh — initialise .env from .env.example.
#
# Generates random values for any var in .env.example marked with the
# magic comment '# auto-generate: <command>'. Idempotent — runs the
# command for any var that's still set to its default placeholder.

set -euo pipefail

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"

log()  { printf '\033[1;34m[init-env]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[init-env]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[init-env]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$EXAMPLE_FILE" ] || fail "$EXAMPLE_FILE not found. Are you in the repo root?"

if [ ! -f "$ENV_FILE" ]; then
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  log "Created $ENV_FILE from $EXAMPLE_FILE"
fi

# Walk through .env.example for auto-generate markers.
prev_line=""
while IFS= read -r line; do
  if [[ "$prev_line" =~ ^#[[:space:]]auto-generate:[[:space:]](.+)$ ]] && [[ "$line" =~ ^([A-Z0-9_]+)= ]]; then
    var=$(echo "$line" | cut -d= -f1)
    cmd=$(echo "$prev_line" | sed 's/^#[[:space:]]auto-generate:[[:space:]]*//')
    current=$(grep "^${var}=" "$ENV_FILE" | head -1 | cut -d= -f2-)
    placeholder=$(echo "$line" | cut -d= -f2-)
    if [ "$current" = "$placeholder" ] || [ -z "$current" ]; then
      new_value=$(eval "$cmd")
      sed -i.bak "s|^${var}=.*|${var}=${new_value}|" "$ENV_FILE"
      rm -f "${ENV_FILE}.bak"
      log "  generated $var"
    else
      log "  $var already set, skipping"
    fi
  fi
  prev_line="$line"
done < "$EXAMPLE_FILE"

log "✅ $ENV_FILE ready."
