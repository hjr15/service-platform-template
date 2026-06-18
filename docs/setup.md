# Setup

This is the detailed walkthrough for getting the platform running from scratch. If you just want the fastest path, the five commands in [README.md](../README.md#quickstart) are enough. Come here when you want to understand each step, troubleshoot a failure, or configure things differently.

## Prerequisites

**Docker** is required. k3d runs Kubernetes nodes as Docker containers.

- Linux: [Docker Engine](https://docs.docker.com/engine/install/) (the daemon, not Desktop). Your user should be in the `docker` group so you can run `docker` without `sudo`.
- macOS: [Docker Desktop](https://docs.docker.com/desktop/install/mac-install/). Make sure it's running before you start.
- Windows: Use [WSL 2](https://learn.microsoft.com/en-us/windows/wsl/install) with Docker Desktop's WSL integration enabled. Run everything inside the WSL terminal.

**Resources:** The cluster runs ArgoCD + cert-manager + 3 workload pods. Expect:
- ~4 GB free RAM minimum (ArgoCD itself uses ~500 MB; the workloads together use another 1–2 GB under light load)
- ~10 GB free disk (container images + PVC storage)
- Any modern x86-64 CPU (Apple Silicon via Rosetta or native arm64 Docker also works)

**Supported OSes:** Linux (Ubuntu/Debian tested), macOS 12+. Windows via WSL 2.

## Step-by-step walkthrough

### Step 1: Fork, clone, and point ArgoCD at your fork

ArgoCD deploys whatever repo its Application manifests name in `repoURL`. Out of the box that's **this** template's repo — which you can't push to. So the very first thing, *before* `make k8s-up`, is to fork the repo and rewrite every `repoURL` to your fork. Skip this and ArgoCD keeps watching the upstream template; every Application fails with a `ComparisonError` / "repository not found" (the single most common first-run failure).

```mermaid
flowchart LR
    A["Fork on GitHub"] --> B["Clone your fork"]
    B --> C["Rewrite repoURL<br/>in deploy/argocd/**"]
    C --> D["git commit + push"]
    D --> E["make k8s-up"]
    E --> F["ArgoCD watches<br/>YOUR fork → Synced"]
    C -. "forgotten" .-> X["ArgoCD still watches<br/>the template repo →<br/>ComparisonError / 404"]
```

1. **Fork** `service-platform-template` on GitHub, so ArgoCD has a repo it can read and you have one you can push to.
2. **Clone your fork:**

   ```bash
   git clone https://github.com/<your-fork>/service-platform-template
   cd service-platform-template
   ```

3. **Rewrite every `repoURL`** under `deploy/argocd/` (root, infra, and apps manifests all reference `hjr15/service-platform-template`), then commit and push:

   ```bash
   find deploy/argocd -name '*.yaml' \
     -exec sed -i 's|hjr15/service-platform-template|<your-user>/<your-fork>|g' {} +
   grep -rn "repoURL" deploy/argocd/   # confirm they all point at your fork
   git commit -am "Point ArgoCD at my fork"
   git push
   ```

`make k8s-up` also prints a warning if it detects the manifests still pointing at the upstream template from a non-upstream clone.

#### If your fork is private

The default setup assumes your fork is **public**, since ArgoCD pulls manifests from the repo without credentials. If you'd rather keep your fork private, ArgoCD needs read access via either an SSH deploy key or an HTTPS Personal Access Token. Skip this section if your fork is public.

The simplest option is an SSH deploy key, scoped read-only to this one repo:

```bash
# 1. Generate a dedicated key (don't reuse a personal SSH key)
ssh-keygen -t ed25519 -C "argocd-service-platform-template" \
  -f ~/.ssh/argocd_template -N ""

# 2. Add the public key as a Deploy Key on your fork
#    Settings → Deploy keys → Add deploy key
#    (Read-only is fine — ArgoCD doesn't write back)
gh repo deploy-key add ~/.ssh/argocd_template.pub \
  --repo <your-fork>/service-platform-template \
  --title "argocd"

# 3. Switch the Application manifests from https:// to git@ URLs
sed -i 's|https://github.com/<your-fork>/service-platform-template.git|git@github.com:<your-fork>/service-platform-template.git|g' \
  deploy/argocd/*.yaml deploy/argocd/apps/*.yaml deploy/argocd/infra/*.yaml
```

Then add a `Repository` Secret to your cluster so ArgoCD can use the private key. The simplest place is `scripts/k8s-up.sh` Phase 3 (alongside the workload Secrets):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-service-platform-template
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: git@github.com:<your-fork>/service-platform-template.git
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
```

You can either inline the key (read it via `cat ~/.ssh/argocd_template`) or load it from `.env`. The `.env.example` doesn't ship a slot for this since the default path is public — add one yourself if you go private.

If ArgoCD's `service-platform-root` app shows `Failed to load target state … authentication required: Repository not found`, this is the cause: ArgoCD can see the URL but doesn't have credentials.

### Step 2: Install CLI tools

> **Recommended on Ubuntu 24.04:** the companion [lab-soe](https://github.com/hjr15/lab-soe) repo provisions all of this host tooling — and more (k9s, Tilt, Terraform, AWS CLI) — idempotently via a single `./bootstrap.sh`. It's the host-setup path the template's author uses, and a good base if you run several labs on one machine. The standalone `make install-deps` below remains the cross-platform path if you'd rather not adopt lab-soe.

```bash
make install-deps
```

This runs `scripts/install-deps.sh`, which installs:

| Tool | Version pinned | Purpose |
|------|---------------|---------|
| k3d | v5.7.5 | Creates/manages the k3d (k3s-in-Docker) cluster |
| helm | v3.20.2 | Renders Helm charts; used for ArgoCD install |
| kubectl | v1.32.0 | Talks to the Kubernetes API |
| argocd | v3.3.8 | ArgoCD CLI (useful for debugging, not required for normal ops) |
| sops | v3.9.4 | Installed for future use; not active in the default path |
| age | v1.2.1 | Key generation for sops; not active in the default path |
| yq | v4.45.1 | YAML processor; used in some scripts |
| kubeconform | v0.6.7 | Validates Kubernetes manifests in CI |

On Linux, binaries are installed to `~/.local/bin`. If that directory isn't on your `PATH`, the script will warn you. Add `export PATH=$HOME/.local/bin:$PATH` to your `~/.bashrc` or `~/.zshrc` and re-source it.

On macOS, tools are installed via Homebrew. If `brew` isn't installed, the script exits early with a link.

### Step 3: Generate secrets

```bash
make init-env
```

This runs `scripts/init-env.sh`, which:

1. Copies `.env.example` to `.env` if `.env` doesn't exist yet
2. For each variable in `.env.example` marked with `# auto-generate: <command>`, runs that command and writes the result into `.env` (only if the variable is still at its placeholder value)

After this step, `.env` will have real values for:
- `DOMAIN=svc.localhost` (unchanged from example — edit if you want a different domain)
- `N8N_ENCRYPTION_KEY=<64 hex chars>` (auto-generated via `openssl rand -hex 32`)
- `VAULTWARDEN_ADMIN_TOKEN=<96 hex chars>` (auto-generated via `openssl rand -hex 48`)

The optional vars (`ACME_EMAIL`, `AWS_*`, `GHCR_PAT`) remain commented out. They're only needed if you're switching to Let's Encrypt or using a private chart mirror.

**Keep `.env` safe.** It's git-ignored, so you won't accidentally push it. But if you lose it, you'll need to reset your n8n credentials and Vaultwarden admin token manually after a cluster rebuild.

### Step 4: Start the cluster

```bash
make k8s-up
```

This is the main bootstrap step. It runs `scripts/k8s-up.sh` in four phases:

**Phase 0 — prerequisites check:** Verifies all required tools are on `PATH` and `.env` is present with non-empty required vars.

**Phase 1 — create k3d cluster:** Creates a cluster named `service-platform` using k3s image `rancher/k3s:v1.31.4-k3s1`, with ports `127.0.0.1:80` and `127.0.0.1:443` bound to the cluster's load balancer. If the cluster already exists, this phase is skipped. Switches `kubectl` context to `k3d-service-platform`.

**Phase 2 — install ArgoCD:** Runs `helm upgrade --install argo-cd argo/argo-cd --version 9.5.10` with the values from `argocd/values-dev.yaml`. Waits for the ArgoCD server Deployment to be ready (timeout: 5 minutes). If ArgoCD is already installed and up to date, Helm is a no-op.

**Phase 3 — bootstrap workload Secrets:** Creates the `n8n` and `vaultwarden` namespaces if they don't exist, then applies the workload Secrets directly via `kubectl apply`. These Secrets are created before ArgoCD syncs so the charts can reference them via `existingSecret` on first deploy.

**Phase 4 — apply root Application:** Applies `deploy/argocd/service-platform-root-app.yaml` to the cluster. This is the only ArgoCD resource that's applied manually; everything else cascades from it.

**Expected output (abbreviated):**
```
[k8s-up] Phase 0: checking prerequisites
[k8s-up] Phase 1: creating k3d cluster 'service-platform' (idempotent)
[k8s-up] Phase 2: installing ArgoCD chart 9.5.10 (upstream — argo-helm)
[k8s-up]   helm upgrade: ok
[k8s-up] Phase 3: applying workload secrets from .env
[k8s-up]   n8n-secrets: ok
[k8s-up]   vaultwarden-secrets: ok
[k8s-up] Phase 4: applying service-platform-root Application
[k8s-up]   applied: service-platform-root
[k8s-up] ✅ ArgoCD ready. ArgoCD will reconcile cert-manager + the 3 workloads (~5 min).
```

### Step 5: Add /etc/hosts entries

```bash
make print-hosts
```

This prints the exact `/etc/hosts` line you need. By default it's:

```
127.0.0.1 argocd.svc.localhost jupyter.svc.localhost n8n.svc.localhost vaultwarden.svc.localhost
```

Add it with:

```bash
sudo sh -c 'cat >> /etc/hosts <<HOSTS
127.0.0.1 argocd.svc.localhost jupyter.svc.localhost n8n.svc.localhost vaultwarden.svc.localhost
HOSTS'
```

**Alternative — wildcard resolver:** If you'd rather not edit `/etc/hosts` for every new service, configure a local resolver to map `*.svc.localhost` to `127.0.0.1` — dnsmasq on macOS (`address=/svc.localhost/127.0.0.1`), or dnsmasq / `systemd-resolved` on Linux. Any new `<app>.svc.localhost` then resolves without another hosts edit.

### Step 6: Wait for reconciliation

ArgoCD needs a few minutes to sync everything after the root Application is applied:

```bash
# Watch all Applications until they're Synced + Healthy
kubectl get app -n argocd -w

# Or use the argocd CLI
argocd app list
```

Expected final state (may take 5–10 minutes on first run due to image pulls):

```
NAME                          SYNC STATUS  HEALTH STATUS
apps-app-of-apps              Synced       Healthy
cert-manager                  Synced       Healthy
cert-manager-clusterissuers   Synced       Healthy
infra-app-of-apps             Synced       Healthy
jupyter                       Synced       Healthy
n8n                           Synced       Healthy
service-platform-root         Synced       Healthy
vaultwarden                   Synced       Healthy
```

## Environment variable reference

| Variable | Required | Default | What it does |
|----------|----------|---------|-------------|
| `DOMAIN` | Yes | `svc.localhost` | Domain suffix for all hostnames (e.g., `jupyter.${DOMAIN}`) |
| `N8N_ENCRYPTION_KEY` | Yes | *(auto-generated)* | n8n encrypts its stored credentials with this key — changing it invalidates saved credentials |
| `VAULTWARDEN_ADMIN_TOKEN` | Yes | *(auto-generated)* | Admin panel access token for `/admin`. Not the vault master password |
| `ACME_EMAIL` | No | — | Email for Let's Encrypt registration (opt-in, see docs/cert-manager.md) |
| `AWS_ACCESS_KEY_ID` | No | — | AWS credentials for Route 53 DNS-01 challenge (opt-in) |
| `AWS_SECRET_ACCESS_KEY` | No | — | AWS credentials for Route 53 DNS-01 challenge (opt-in) |
| `AWS_HOSTED_ZONE_ID` | No | — | Route 53 hosted zone ID for your domain (opt-in) |
| `GITHUB_USER` | No | — | Your GitHub username, used if you set up a GHCR chart mirror |
| `GHCR_PAT` | No | — | GitHub Personal Access Token with `read:packages` scope (opt-in, see docs/ghcr-mirror.md) |

## First-time login per app

### ArgoCD

Get the auto-generated admin password:

```bash
make argocd-pw
```

Open http://argocd.svc.localhost (HTTP, not HTTPS — see architecture.md for why). Log in with username `admin` and the password printed above. You'll see all Applications and their sync status in the UI.

### Jupyter

Jupyter auto-generates a token each time the pod starts. Find it in the pod logs:

```bash
kubectl logs -n jupyter deploy/jupyter | grep token=
```

You'll see a line like:
```
    http://jupyter.svc.localhost/?token=abc123...
```

Copy the token value and paste it at https://jupyter.svc.localhost. Accept the browser's TLS warning (self-signed cert), then paste the token in the login field.

### n8n

Open https://n8n.svc.localhost and accept the TLS warning. n8n will walk you through a first-run setup wizard asking for your name, email, and a password. This creates the owner account. There's no default credential — you choose your own.

### Vaultwarden

Open https://vaultwarden.svc.localhost and accept the TLS warning. Click "Create Account" to register the first user. This account becomes the vault owner.

**The admin panel** is at https://vaultwarden.svc.localhost/admin — authenticate with the `VAULTWARDEN_ADMIN_TOKEN` from your `.env` file (not your vault master password). From there you can manage users, send invite emails, and configure SMTP.

**Do not forget your master password.** There's no password reset mechanism in a local deployment without SMTP configured.

## Smoke tests

Once everything is `Synced / Healthy`, verify TLS and routing with curl:

```bash
# ArgoCD (HTTP, no TLS)
curl -I http://argocd.svc.localhost
# Expect: HTTP/1.1 200 OK or 302 Found

# Jupyter (self-signed TLS — use -k to skip cert validation)
curl -kI https://jupyter.svc.localhost
# Expect: HTTP/2 200 or 302

# n8n
curl -kI https://n8n.svc.localhost
# Expect: HTTP/2 200

# Vaultwarden
curl -kI https://vaultwarden.svc.localhost
# Expect: HTTP/2 200
```

If any of these return `Connection refused` or `Could not resolve host`, check:
1. `/etc/hosts` has the right entries (`cat /etc/hosts | grep svc.localhost`)
2. The pod is running (`kubectl get pods -A`)
3. The ArgoCD Application is `Synced` (`kubectl get app -n argocd`)

See [docs/troubleshooting.md](troubleshooting.md) for specific failure patterns.

## Tearing down

```bash
# Delete the cluster and everything in it (PVCs gone — workload data lost)
make k8s-down

# Delete + immediately recreate (full reset — data still gone)
make k8s-reset
```

**PVC deletion means data loss.** n8n workflows, Jupyter notebooks, and the Vaultwarden database live in PersistentVolumes managed by k3d's local-path provisioner. When the cluster is deleted, they're gone. Export what matters before running `make k8s-down`.

If you only want to stop the cluster temporarily without destroying data:

```bash
k3d cluster stop service-platform   # stops, preserves PVCs
k3d cluster start service-platform  # resumes, ArgoCD resyncs
```

## Where to go next

- [docs/adding-an-app.md](adding-an-app.md) — add your own Helm chart as a new workload
- [docs/cert-manager.md](cert-manager.md) — switch from self-signed to Let's Encrypt
- [docs/troubleshooting.md](troubleshooting.md) — fix common issues
