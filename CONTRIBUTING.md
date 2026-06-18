# Contributing

This is a personal reference / template, not a maintained product. PRs are
welcome and will be reviewed, but there's no SLA. If something's broken for
you, the most likely outcome from opening an issue is a quick fix — just don't
expect a formal release cycle.

---

## Filing issues

Open an issue at:
**<https://github.com/hjr15/service-platform-template/issues>**

A useful issue includes:

- **Steps to reproduce** — exact commands, in order, from a fresh clone.
- **Environment** — OS, `kubectl version --short`, `k3d version`, which
  optional paths (Route53, GHCR mirror) are active.
- **Full output** — paste as a code block, not a screenshot.

If the issue is clearly upstream (cert-manager bug, 8gears chart bug, etc.),
file it with the upstream project instead — see the links in
`docs/troubleshooting.md`.

---

## Suggesting changes

1. Fork the repo.
2. Create a branch: `git checkout -b fix/thing-you-are-fixing`
3. Make your change.
4. Run the validation steps below.
5. Open a PR against `main` in this repo.

**Keep personal data out.** Use the same placeholder convention as the repo:
`<your-domain>`, `<your-user>`, `<your-acme-email>`, etc. No real hostnames,
email addresses, or account IDs in code or docs.

Match existing patterns — Ingress annotations, ArgoCD Application structure,
values file layout. Adding a new app? Follow `docs/adding-an-app.md`.

---

## Running validate.yml locally

The CI workflow at `.github/workflows/validate.yml` runs these checks. You
can run them locally before pushing:

**Install the tools:**

```bash
# Helm (if not already installed)
brew install helm   # or your distro's package manager

# yq
sudo wget -qO /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# kubeconform
curl -sL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz \
  | tar -xz -C /tmp
sudo install /tmp/kubeconform /usr/local/bin/
```

**Run the checks:**

```bash
# Lint the custom Jupyter chart
helm lint deploy/apps/jupyter/chart

# Render cert-manager and validate the output
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm template cert-manager jetstack/cert-manager \
  --version v1.20.2 -f cert-manager/values-dev.yaml -n cert-manager \
  | kubeconform -strict -summary -ignore-missing-schemas

# Validate ArgoCD Application manifests
find deploy/argocd -name '*.yaml' \
  -exec kubeconform -strict -summary -ignore-missing-schemas {} +

# YAML lint everything
find . -name '*.yaml' -not -path './.git/*' \
  -exec yq eval . {} \; > /dev/null
```

If all of these pass locally, CI will pass too (assuming you haven't changed
the tool version pins).

---

## Code style

- **Shell scripts** — `bash -n script.sh` before committing. Use `shellcheck`
  if you have it; the template's scripts are shellcheck-clean.
- **YAML** — `yq eval . <file>` for lint. Keep indentation consistent with the
  surrounding file (the Application manifests use 2-space; values files vary by
  upstream chart convention).
- **Markdown** — keep lines under 100 columns where reasonable. The existing
  docs are wrapped at ~80. No hard requirement, but it keeps diffs readable.
- **Commit messages** — short imperative subject line (`fix:`, `docs:`,
  `feat:`), body if the why isn't obvious from the diff.
