.PHONY: install-deps init-env k8s-up k8s-down k8s-reset argocd-pw print-hosts help

help:
	@echo "Targets:"
	@echo "  install-deps  Install required CLI tools (k3d, helm, kubectl, etc.)"
	@echo "  init-env      Create + populate .env from .env.example"
	@echo "  k8s-up        Bootstrap k3d + ArgoCD + reconcile workloads"
	@echo "  k8s-down      Delete the k3d cluster"
	@echo "  k8s-reset     Destructive: delete + recreate"
	@echo "  argocd-pw     Print initial ArgoCD admin password"
	@echo "  print-hosts   Print /etc/hosts lines to add"

install-deps:
	./scripts/install-deps.sh

init-env:
	./scripts/init-env.sh

k8s-up:
	./scripts/k8s-up.sh

k8s-down:
	./scripts/k8s-down.sh

k8s-reset:
	./scripts/k8s-reset.sh

argocd-pw:
	./scripts/argocd-pw.sh

print-hosts:
	./scripts/print-hosts-entries.sh
