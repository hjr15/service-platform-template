#!/usr/bin/env bash
# scripts/print-hosts-entries.sh — print the /etc/hosts lines you'll need.

set -euo pipefail

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

DOMAIN="${DOMAIN:-svc.localhost}"

cat <<EOM
# Add these to /etc/hosts:
127.0.0.1 argocd.${DOMAIN} jupyter.${DOMAIN} n8n.${DOMAIN} vaultwarden.${DOMAIN}

# Or via sudo one-liner:
sudo sh -c 'cat >> /etc/hosts <<HOSTS
127.0.0.1 argocd.${DOMAIN} jupyter.${DOMAIN} n8n.${DOMAIN} vaultwarden.${DOMAIN}
HOSTS'
EOM
