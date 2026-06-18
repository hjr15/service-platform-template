# GHCR chart mirror — hands-on walkthrough

## What this is

An opt-in private chart mirror at `ghcr.io/<your-github-user>/charts`. The
default template path pulls charts directly from upstream registries (jetstack,
8gears, guerzon). Mirroring copies those charts into your GHCR namespace for
supply-chain control and reproducibility.

Files in this directory:

- `mirror-helm-chart.yml` — GitHub Actions workflow: pull from upstream, push
  to your GHCR namespace
- `oci-helm-repo-secret.yaml.example` — ArgoCD Helm Repository Secret template

## When you'd want this

See `docs/ghcr-mirror.md` for the why-yes / why-no analysis. Most people using
this template for personal infra don't need a mirror — the upstream-direct
default is fine.

---

## Step-by-step setup

### 1. Create a GitHub PAT

Go to <https://github.com/settings/tokens> and create a **classic** PAT with
scope `write:packages`. Copy it — you won't see it again.

### 2. Add it as a repo Secret

In your fork: Settings → Secrets and variables → Actions → New repository
secret. Name: `GHCR_PAT`, value: the token.

Also add `GITHUB_USER` and `GHCR_PAT` to your local `.env` (already commented
out in `.env.example`):
```bash
GITHUB_USER=your-github-user
GHCR_PAT=ghp_xxxxxxxxxxxxxxxxxxxx
```

### 3. Copy the workflow

```bash
cp docs/examples/optional-ghcr-mirror/mirror-helm-chart.yml .github/workflows/
```

Also edit `mirror-helm-chart.yml` to replace `<your-github-user>` with your
actual GitHub username in the `helm push` and verify steps.

Commit and push. GitHub picks up the workflow.

### 4. Mirror each chart

```bash
# cert-manager
gh workflow run mirror-helm-chart.yml \
  -f chart_name=cert-manager \
  -f upstream_repo=https://charts.jetstack.io \
  -f version=v1.20.2

# vaultwarden
gh workflow run mirror-helm-chart.yml \
  -f chart_name=vaultwarden \
  -f upstream_repo=https://guerzon.github.io/vaultwarden \
  -f version=0.36.3
```

The workflow's final "Verify" step pulls the chart back from your GHCR
namespace to confirm the push landed.

> **n8n gotcha.** The 8gears registry is OCI-native; `helm repo add` won't
> work against it. Pull locally with `helm pull oci://8gears.container-registry.com/library/n8n --version 2.0.1`,
> then `helm push` the tgz to `oci://ghcr.io/<your-user>/charts` manually.

### 5. Update Application manifests

Change `repoURL` in each Application under `deploy/argocd/` to point at your
mirror. For cert-manager (`deploy/argocd/infra/cert-manager-app.yaml`):

```diff
 spec:
   sources:
-    - repoURL: https://charts.jetstack.io
+    - repoURL: ghcr.io/<your-github-user>/charts
       chart: cert-manager
       targetRevision: v1.20.2
```

Apply the same change in `n8n-app.yaml` and `vaultwarden-app.yaml`.

### 6. Add the OCI Helm Secret to k8s-up.sh

ArgoCD needs credentials to pull from your private GHCR namespace. Use
`oci-helm-repo-secret.yaml.example` as reference. In Phase 3 of
`scripts/k8s-up.sh`, add:
```bash
kubectl create secret generic helm-charts-ghcr -n argocd \
  --from-literal=type=helm --from-literal=name="ghcr-${GITHUB_USER}-charts" \
  --from-literal=url="ghcr.io/${GITHUB_USER}/charts" \
  --from-literal=enableOCI="true" --from-literal=username="${GITHUB_USER}" \
  --from-literal=password="${GHCR_PAT}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Test it

```bash
helm pull oci://ghcr.io/<your-user>/charts/cert-manager \
  --version v1.20.2 --destination /tmp
ls /tmp/cert-manager-v1.20.2.tgz   # should exist
```

If this fails with an auth error, check that your GHCR PAT has `read:packages`
scope and that the package visibility is set correctly on GitHub
(Settings → Packages → cert-manager).

---

## Maintenance flow

When Renovate opens a PR bumping a chart version:

1. Re-run the mirror workflow with the new version before merging:
   ```bash
   gh workflow run mirror-helm-chart.yml \
     -f chart_name=cert-manager \
     -f upstream_repo=https://charts.jetstack.io \
     -f version=v1.21.0
   ```
2. Merge the PR once the workflow confirms the chart is pullable.
3. ArgoCD reconciles automatically.

If you merge before mirroring, ArgoCD fails to sync (`helm pull` can't find
the version). Fix: run the mirror workflow, then trigger a manual ArgoCD sync.
