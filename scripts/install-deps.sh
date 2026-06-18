#!/usr/bin/env bash
# scripts/install-deps.sh — install the tools the cluster bootstrap needs.
#
# OS-detected: Linux (apt) and macOS (brew). Windows users: use WSL.
# Idempotent: skips tools that are already installed.

set -euo pipefail

OS="$(uname -s)"

log()  { printf '\033[1;34m[install-deps]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-deps]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[install-deps]\033[0m %s\n' "$*" >&2; exit 1; }

# Pinned versions. Renovate will track these.
K3D_VERSION="v5.7.5"
HELM_VERSION="v3.20.2"
KUBECTL_VERSION="v1.32.0"
ARGOCD_VERSION="v3.3.8"
SOPS_VERSION="v3.9.4"
AGE_VERSION="v1.2.1"
YQ_VERSION="v4.45.1"
KUBECONFORM_VERSION="v0.6.7"

install_linux() {
  log "Detected Linux. Installing missing tools to ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "~/.local/bin not on PATH. Add 'export PATH=\$HOME/.local/bin:\$PATH' to your shell rc." ;;
  esac

  if command -v docker >/dev/null 2>&1; then
    log "  docker already installed: $(docker --version)"
  else
    fail "Docker is required but not installed. Install via the official Docker Desktop or 'sudo apt install docker.io'."
  fi

  command -v jq >/dev/null 2>&1 || sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends jq curl ca-certificates

  command -v k3d >/dev/null 2>&1 || {
    log "  installing k3d $K3D_VERSION"
    curl -sSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64" \
      -o "$HOME/.local/bin/k3d" && chmod +x "$HOME/.local/bin/k3d"
  }

  command -v helm >/dev/null 2>&1 || {
    log "  installing helm $HELM_VERSION"
    curl -sSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
    install -m 0755 /tmp/linux-amd64/helm "$HOME/.local/bin/helm" && rm -rf /tmp/linux-amd64
  }

  command -v kubectl >/dev/null 2>&1 || {
    log "  installing kubectl $KUBECTL_VERSION"
    curl -sSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o "$HOME/.local/bin/kubectl" && chmod +x "$HOME/.local/bin/kubectl"
  }

  command -v argocd >/dev/null 2>&1 || {
    log "  installing argocd CLI $ARGOCD_VERSION"
    curl -sSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" \
      -o "$HOME/.local/bin/argocd" && chmod +x "$HOME/.local/bin/argocd"
  }

  command -v sops >/dev/null 2>&1 || {
    log "  installing sops $SOPS_VERSION"
    curl -sSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
      -o "$HOME/.local/bin/sops" && chmod +x "$HOME/.local/bin/sops"
  }

  command -v age >/dev/null 2>&1 || {
    log "  installing age $AGE_VERSION"
    curl -sSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
    install -m 0755 /tmp/age/age "$HOME/.local/bin/age"
    install -m 0755 /tmp/age/age-keygen "$HOME/.local/bin/age-keygen"
    rm -rf /tmp/age
  }

  command -v yq >/dev/null 2>&1 || {
    log "  installing yq $YQ_VERSION"
    curl -sSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
      -o "$HOME/.local/bin/yq" && chmod +x "$HOME/.local/bin/yq"
  }

  command -v kubeconform >/dev/null 2>&1 || {
    log "  installing kubeconform $KUBECONFORM_VERSION"
    curl -sSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" | tar -xz -C /tmp
    install -m 0755 /tmp/kubeconform "$HOME/.local/bin/kubeconform" && rm -f /tmp/kubeconform
  }
}

install_macos() {
  log "Detected macOS. Using Homebrew."

  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is required. Install from https://brew.sh/"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is required but not installed. Install Docker Desktop from https://docker.com/"
  fi

  for tool in jq curl k3d helm kubectl argocd sops age yq kubeconform; do
    if command -v "$tool" >/dev/null 2>&1; then
      log "  $tool already installed"
    else
      log "  installing $tool"
      brew install "$tool"
    fi
  done
}

case "$OS" in
  Linux)  install_linux ;;
  Darwin) install_macos ;;
  *) fail "Unsupported OS: $OS. Linux + macOS only. Windows: use WSL." ;;
esac

log "✅ All tools installed. Versions:"
for tool in k3d helm kubectl argocd sops age yq kubeconform; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf "  %-15s %s\n" "$tool" "$($tool version --short 2>/dev/null || $tool --version 2>/dev/null | head -1)"
  fi
done
