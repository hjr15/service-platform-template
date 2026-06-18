# Adding an app

This is a worked walkthrough for adding a new application to the platform. The example uses **Pi-hole**, a DNS sinkhole and ad-blocker that's a common selfhost target. Pi-hole isn't included in the template's defaults, so it makes a clean example with no special cases.

This is a **structural example**, not a validated installation guide. The steps show the correct pattern for the repo — values file, ArgoCD Application manifest, secret handling, hosts entry. You should verify the specific Helm chart values against the chart's own documentation before expecting it to work in your cluster.

## What you'll do

1. Find an upstream Helm chart for Pi-hole
2. Create `deploy/apps/pihole/values-dev.yaml` with your configuration
3. Create `deploy/argocd/apps/pihole-app.yaml` with an ArgoCD Application manifest
4. Add a secret if Pi-hole needs one (optional pattern)
5. Push to main and watch ArgoCD sync
6. Add an `/etc/hosts` entry for the new hostname
7. Verify it's working

## Step 1: Find or write a chart

Start at [Artifact Hub](https://artifacthub.io/) — search for the app name. For Pi-hole, a commonly used chart is **mojo2600/pihole-kubernetes**:

```bash
# Search from the CLI (helm must be installed)
helm search hub pihole
```

Check the chart's source, maintenance status, and star count on Artifact Hub before committing to it. For Pi-hole you'd find something like:

- **Repo:** `https://mojo2600.github.io/pihole-kubernetes/`
- **Chart:** `pihole`
- **Artifact Hub:** https://artifacthub.io/packages/helm/mojo2600/pihole

Inspect the chart values to understand what's configurable:

```bash
helm repo add mojo2600 https://mojo2600.github.io/pihole-kubernetes/
helm repo update
helm show values mojo2600/pihole | less
```

**If there's no upstream chart:** Write your own. The Jupyter chart in `deploy/apps/jupyter/chart/` is the template repo's own example. It's a minimal chart with a Deployment, Service, Ingress, and PVC template. Copy it as a starting point, update `Chart.yaml` with the new app's name and version, and write your templates. Use that chart as a single-source Application (like Jupyter's `jupyter-app.yaml`) rather than multi-source.

**Chart sources comparison:**

| Source type | Example | When to use |
|-------------|---------|-------------|
| HTTP Helm repo | `mojo2600/pihole-kubernetes` | Most community charts — add repo, reference chart + version |
| OCI registry | `8gears.container-registry.com/library/n8n` | Growing standard; no `helm repo add` needed |
| In-repo path | `deploy/apps/jupyter/chart/` | You wrote or heavily modified the chart; want it version-controlled |

## Step 2: Create the values file

Create `deploy/apps/pihole/values-dev.yaml`. This file holds all your customizations for the dev environment. Keep it focused — only override what you need; the chart defaults handle the rest.

```yaml
# deploy/apps/pihole/values-dev.yaml
# Pi-hole DNS sinkhole — local dev values.
# Chart: mojo2600/pihole, version: ~2.x.x
# Ref: https://github.com/MojoJojo/pi-hole-kubernetes

# Pin the Pi-hole image tag. Renovate will track upstream releases.
image:
  tag: "2024.07.0"

# Admin web password — we'll reference a pre-applied Secret here.
# (See Step 4 for how the Secret gets created.)
adminPassword:
  # Tell the chart to use an existing Secret instead of creating one.
  existingSecret: pihole-secrets
  existingSecretKey: PIHOLE_WEBPASSWORD

# Persistence: Pi-hole stores blocklists and custom DNS entries here.
# Wipe on cluster reset is acceptable for local dev.
persistentVolumeClaim:
  enabled: true
  size: 2Gi

# Resource limits sized for a laptop cluster.
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Ingress for the admin web UI.
ingress:
  enabled: true
  ingressClassName: traefik
  annotations:
    cert-manager.io/cluster-issuer: selfsigned
  hosts:
    - host: pihole.svc.localhost
      paths:
        - path: /admin
          pathType: Prefix
  tls:
    - hosts:
        - pihole.svc.localhost
      secretName: pihole-tls
```

**Fields to customise for your domain:** Replace `pihole.svc.localhost` with `pihole.${DOMAIN}` if you've changed the `DOMAIN` var in `.env`. If you're hardcoding the hostname (as in this example), keep it consistent with what you'll add to `/etc/hosts`.

**Note on Pi-hole's DNS service:** Pi-hole also runs a DNS server on UDP port 53. Exposing that through k3d requires a separate LoadBalancer Service or NodePort configuration. The example above only covers the web UI ingress. Check the chart's `serviceDns` values section for DNS exposure options.

## Step 3: Create the ArgoCD Application

For a chart from an HTTP Helm repo (like mojo2600), use the multi-source pattern: one source for the chart, one source for the values. This is the same pattern n8n and Vaultwarden use.

Create `deploy/argocd/apps/pihole-app.yaml`:

```yaml
# deploy/argocd/apps/pihole-app.yaml
# Pi-hole Application — workload tier (apps-app-of-apps cascade).
# Multi-source: chart from HTTP repo, values from this repo.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pihole
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    # Source 1: the upstream Helm chart
    - repoURL: https://mojo2600.github.io/pihole-kubernetes/
      chart: pihole
      targetRevision: 2.27.0    # pin to a specific chart version
      helm:
        releaseName: pihole
        valueFiles:
          - $values/deploy/apps/pihole/values-dev.yaml

    # Source 2: this repo as the values reference
    - repoURL: https://github.com/<your-username>/service-platform-template.git
      targetRevision: main
      ref: values               # makes this source available as $values

  destination:
    server: https://kubernetes.default.svc
    namespace: pihole

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true    # creates the 'pihole' namespace if it doesn't exist
```

Replace `<your-username>` with your GitHub username (matching the other Application manifests in `deploy/argocd/apps/`). Pin `targetRevision` to a specific chart version — don't use `*` or `latest` for charts; you want reproducible deploys.

**If you wrote your own chart** (in-repo path), use single-source instead:

```yaml
source:
  repoURL: https://github.com/<your-username>/service-platform-template.git
  targetRevision: main
  path: deploy/apps/pihole/chart
  helm:
    releaseName: pihole
    valueFiles:
      - ../values-dev.yaml
```

## Step 4: Add a secret if needed

Pi-hole requires a web admin password. Hardcoding it in `values-dev.yaml` would commit it to the repo — don't do that. Use the same bootstrap-applied Secret pattern the other workloads use.

**4a. Add the var to `.env.example`:**

```bash
# ─── Pi-hole admin password ──────────────────────────────────────────
# auto-generate: openssl rand -hex 16
PIHOLE_WEBPASSWORD=replace_me
```

The `# auto-generate:` comment tells `scripts/init-env.sh` to generate a value automatically. Re-run `make init-env` to get a value in your `.env`.

**4b. Extend `scripts/k8s-up.sh` Phase 3:**

Add these lines to the Phase 3 block (after the existing `vaultwarden-secrets` block):

```bash
kubectl get ns pihole >/dev/null 2>&1 || kubectl create ns pihole
kubectl apply -n pihole -f - <<NS
apiVersion: v1
kind: Secret
metadata:
  name: pihole-secrets
  namespace: pihole
type: Opaque
stringData:
  PIHOLE_WEBPASSWORD: "${PIHOLE_WEBPASSWORD}"
NS
log "  pihole-secrets: ok"
```

**4c. Reference the Secret in your values file:**

This is already shown in Step 2 — the `adminPassword.existingSecret` field points to the Secret by name. The chart reads the password from the Secret at startup.

**4d. Re-run `make k8s-up`** to apply the new Secret. The script is idempotent — it won't recreate anything that already exists.

## Step 5: Push and watch

```bash
git add deploy/apps/pihole/values-dev.yaml deploy/argocd/apps/pihole-app.yaml
git commit -m "feat: add pihole workload"
git push origin main
```

ArgoCD polls the repo approximately every 60 seconds. Within about a minute, you'll see the new Application appear:

```bash
# Watch the new Application appear and sync
kubectl get app -n argocd -w

# Or trigger a manual sync immediately (no waiting)
argocd app sync apps-app-of-apps   # re-syncs the parent, picks up new app
```

Expected sequence:
1. `apps-app-of-apps` detects the new `pihole-app.yaml` and creates the `pihole` Application
2. `pihole` Application starts syncing: namespace created, chart downloaded, resources applied
3. `pihole` reaches `Synced / Healthy`

Typical time from push to healthy: **2–5 minutes** on a good connection (image pull dominates).

## Step 6: Add /etc/hosts entry

Add the new hostname to your `/etc/hosts`:

```bash
sudo sh -c 'echo "127.0.0.1 pihole.svc.localhost" >> /etc/hosts'
```

If you used a custom `DOMAIN`, substitute accordingly. You can also run `make print-hosts` — it only prints the default four hostnames, so you'll need to add the Pi-hole line manually.

## Step 7: Verify

```bash
# Check the pod is running
kubectl get pods -n pihole

# Check TLS cert was minted
kubectl get secret pihole-tls -n pihole

# Check the ingress is configured
kubectl get ingress -n pihole

# Smoke test — expect HTTP 200 or redirect
curl -kI https://pihole.svc.localhost/admin
```

Open https://pihole.svc.localhost/admin in your browser. Accept the TLS warning (self-signed cert). You should see the Pi-hole admin login page. Log in with the password from `PIHOLE_WEBPASSWORD` in your `.env`.

**Common failures:**

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod `ImagePullBackOff` | Wrong image tag, or registry rate-limited | Check `kubectl describe pod -n pihole`; try `docker pull` manually |
| Application stuck `OutOfSync` | Chart version not found, or repo URL wrong | Check the ArgoCD UI → Application → Events tab |
| Browser shows "502 Bad Gateway" | Pod is starting up or crashed | `kubectl logs -n pihole deploy/pihole` |
| Browser shows "404" | Ingress path mismatch | Check `kubectl get ingress -n pihole -o yaml` |
| TLS cert not issued | cert-manager not ready, or annotation typo | `kubectl describe certificate pihole-tls -n pihole` |

See [docs/troubleshooting.md](troubleshooting.md) for more detailed debugging steps.

## Notes on chart sources

**HTTP Helm repos** (like `https://mojo2600.github.io/pihole-kubernetes/`) are the traditional format. You add the repo once locally for inspection, but ArgoCD fetches charts directly by URL without needing `helm repo add` on the server side. Reference them in Application manifests with `repoURL` set to the repo base URL and `chart` set to the chart name.

**OCI registries** (like `oci://8gears.container-registry.com/library/n8n`) are the newer standard. No repo list needed — the URL is self-contained. ArgoCD supports OCI natively. Prefer OCI when the chart publisher supports it; it's faster and more reliable.

**In-repo chart paths** (like `deploy/apps/jupyter/chart/`) are simplest for charts you maintain yourself or have customised heavily. No external dependency. Single-source Applications. The downside is chart versioning is tied to your repo commits rather than SemVer tags.

When choosing, prefer upstream OCI > upstream HTTP repo > in-repo, unless you need to patch the chart or there's no maintained upstream option.
