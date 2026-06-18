# GHCR chart mirror (opt-in)

The default template pulls Helm charts directly from upstream registries:

- cert-manager — `https://charts.jetstack.io`
- n8n — `8gears.container-registry.com/library`
- vaultwarden — `https://guerzon.github.io/vaultwarden`

This page describes an opt-in workflow that mirrors those charts into
`ghcr.io/<your-github-user>/charts` for supply-chain and reproducibility
reasons.

---

## Why a mirror?

- **Supply-chain control.** Once pushed to your GHCR namespace, the chart
  content is under your control. An upstream maintainer can push a new tgz
  over the same tag; your mirror stays frozen at the content you verified.
- **Reproducibility.** If an upstream maintainer yanks a chart version (rare
  but it happens), your cluster can still pull from the mirror. ArgoCD drifts
  won't block because the version is no longer resolvable.
- **Faster pulls (sometimes).** GHCR is co-located with GitHub Actions runners
  and may be closer to your infra than niche chart registries. On a typical
  home lab the difference is negligible, but it can matter in CI.

## Why NOT a mirror?

Most consumers don't need this. The default upstream-direct path is fine.

- **Ongoing maintenance.** Every time you upgrade a chart version you need
  to re-run the mirror workflow. If you forget, ArgoCD pulls the new version
  from upstream — which defeats the purpose.
- **GHCR storage costs.** Helm charts are small (a few hundred KB each) and
  GitHub's free tier covers the storage comfortably, but you're still
  accumulating artefacts that count against package storage.
- **One more moving part.** When something breaks at 02:00 you now have an
  extra potential failure point: the ArgoCD OCI Helm Secret, GHCR auth, and
  the mirror workflow history to check before you find the real cause.

If you value reproducibility over simplicity, proceed. Otherwise, skip this.

---

## Setup steps

### 1. Create a GitHub PAT

Go to <https://github.com/settings/tokens> and create a **classic** token
(or fine-grained token with repository write:packages scope) with:

- Scope: `write:packages`

Copy the token — you'll only see it once.

### 2. Store the token as a repo Secret

In your fork's GitHub repo:

```
Settings → Secrets and variables → Actions → New repository secret
```

Name: `GHCR_PAT`
Value: the token you just created.

> The mirror workflow uses `secrets.GITHUB_TOKEN` for the push itself. Storing
> `GHCR_PAT` as a repo secret also lets `scripts/k8s-up.sh` create the ArgoCD
> OCI Helm Secret from your `.env`.

### 3. Copy the workflow file

```bash
cp docs/examples/optional-ghcr-mirror/mirror-helm-chart.yml .github/workflows/
```

Commit and push. GitHub picks up the workflow on the next push to `main`.

### 4. Run the workflow

Via the GitHub UI — Actions → "Mirror Helm chart to GHCR" → "Run workflow" —
or with the `gh` CLI:

The workflow handles classic (HTTP-index) chart repos like cert-manager and
vaultwarden:

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

> **n8n is OCI-native — the workflow above does not handle it.** The 8gears
> registry (`8gears.container-registry.com/library`) is an OCI registry, so
> `helm repo add` (what the workflow uses) won't work against it. Mirror n8n
> by hand instead:
>
> ```bash
> helm pull oci://8gears.container-registry.com/library/n8n --version 2.0.1
> helm push n8n-2.0.1.tgz oci://ghcr.io/<your-github-user>/charts
> ```
>
> (or extend `mirror-helm-chart.yml` to detect an `oci://` upstream and use
> `helm pull oci://…` + `helm push`).

Check the "Verify" step in the workflow run — it pulls from your GHCR namespace
to confirm the push landed.

### 5. Update Application manifests

Change `repoURL` in each Application under `deploy/argocd/` to point at your
mirror. Example diff for cert-manager:

```diff
 spec:
   sources:
-    - repoURL: https://charts.jetstack.io
-      chart: cert-manager
+    - repoURL: ghcr.io/<your-github-user>/charts
+      chart: cert-manager
       targetRevision: v1.20.2
```

For n8n (`deploy/argocd/apps/n8n-app.yaml`):

```diff
-    - repoURL: 8gears.container-registry.com/library
+    - repoURL: ghcr.io/<your-github-user>/charts
       chart: n8n
       targetRevision: 2.0.1
```

For vaultwarden (`deploy/argocd/apps/vaultwarden-app.yaml`):

```diff
-    - repoURL: https://guerzon.github.io/vaultwarden
+    - repoURL: ghcr.io/<your-github-user>/charts
       chart: vaultwarden
       targetRevision: 0.36.3
```

### 6. Add the OCI Helm Secret to k8s-up.sh

ArgoCD needs credentials to pull from your private GHCR namespace. In
`scripts/k8s-up.sh`, add this to Phase 3 (use
`docs/examples/optional-ghcr-mirror/oci-helm-repo-secret.yaml.example` as
reference):

```bash
kubectl create secret generic helm-charts-ghcr -n argocd \
  --from-literal=type=helm \
  --from-literal=name="ghcr-${GITHUB_USER}-charts" \
  --from-literal=url="ghcr.io/${GITHUB_USER}/charts" \
  --from-literal=enableOCI="true" \
  --from-literal=username="${GITHUB_USER}" \
  --from-literal=password="${GHCR_PAT}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Add `GITHUB_USER` and `GHCR_PAT` to your `.env` (already commented out in
`.env.example`).

---

## Maintenance flow

When a new chart version is available (e.g., cert-manager v1.21.0):

1. Renovate notices the upstream bump and opens a PR updating
   `targetRevision` in your Application manifest.
2. Review the PR. Before merging, re-run the mirror workflow with the new
   version:
   ```bash
   gh workflow run mirror-helm-chart.yml \
     -f chart_name=cert-manager \
     -f upstream_repo=https://charts.jetstack.io \
     -f version=v1.21.0
   ```
3. Once the workflow succeeds (mirror confirmed pullable), merge the PR.
4. ArgoCD picks up the updated `targetRevision` and reconciles.

If you merge before mirroring, ArgoCD will fail to sync because the version
doesn't exist in your registry yet. The error is obvious (`helm pull` failing),
and the fix is just to run the mirror workflow then trigger a manual sync.

## Auto-mirror on Renovate PRs (optional)

You can trigger the mirror workflow automatically when a Renovate PR bumping a
chart version is merged. See GitHub's
[workflow_run](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#workflow_run)
and [repository_dispatch](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#repository_dispatch)
event docs. For a small number of charts the manual flow is reliable enough.

---

## Reverting

To go back to upstream-direct:

1. Change each Application manifest's `repoURL` back to the upstream URL
   (reverse the diff in step 5 above).
2. Remove the `kubectl create secret` block from `scripts/k8s-up.sh`.
3. Delete the GHCR Secret from the running cluster if you want to clean up:
   ```bash
   kubectl delete secret helm-charts-ghcr -n argocd
   ```

No state to worry about — GHCR retains your mirrored packages but ArgoCD
will stop using them as soon as the Applications point back upstream.
