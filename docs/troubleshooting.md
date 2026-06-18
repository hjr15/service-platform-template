# Troubleshooting

Real issues encountered during migration to this template. Each entry is a
"Problem → Cause → Fix" triple. Jump to a section using the TOC your Markdown
viewer generates from the `##` headers.

---

## Problem: `make k8s-up` fails with "namespaces argocd not found"

**Symptom:**
`Error from server (NotFound): namespaces "argocd" not found` early in the
script, even though the cluster is running.

**Cause:**
The kubectl context drifted to a different cluster mid-run. `k8s-up.sh` calls
`kubectl config use-context k3d-service-platform` at startup, but a parallel
terminal command may have flipped the context.

**Fix:**
```bash
kubectl config use-context k3d-service-platform
kubectl config current-context   # confirm
```
Then re-run `make k8s-up`. Use separate shell sessions when working across
multiple clusters.

---

## Problem: Jupyter pod crashloops with `JUPYTER_PORT` int parse error

**Symptom:**
```
ValueError: invalid literal for int() with base 10: 'tcp://10.43.x.x:8888'
```
Pod restarts in a tight loop immediately after startup.

**Cause:**
Kubernetes injects env vars for every Service in the namespace into every Pod
(legacy Docker-link compat). A Service named `jupyter` causes
`JUPYTER_PORT=tcp://10.43.x.x:8888` to be injected. Jupyter's startup code
parses `JUPYTER_PORT` as an integer and crashes.

**Fix:**
Set `enableServiceLinks: false` on the Pod spec. Already done in this template
at `deploy/apps/jupyter/chart/templates/deployment.yaml`. If you're adapting
the chart, add it yourself:
```yaml
spec:
  template:
    spec:
      enableServiceLinks: false
```

---

## Problem: Vaultwarden StatefulSet fails to create PVC `-vaultwarden-0`

**Symptom:**
```
PersistentVolumeClaim "-vaultwarden-0" is invalid: metadata.name: Invalid
value: "-vaultwarden-0": must start with an alphanumeric character
```

**Cause:**
The guerzon chart constructs the PVC name as `<storage.data.name>-vaultwarden-0`.
When `storage.data.name` is empty, the name starts with a dash — invalid RFC
1123.

**Fix:**
Ensure `storage.data.name` is set in `deploy/apps/vaultwarden/values-dev.yaml`:
```yaml
storage:
  data:
    name: vaultwarden-data
```
Already present in the template's values file.

---

## Problem: n8n PVC stuck in `Pending`

**Symptom:**
```
$ kubectl get pvc -n n8n
NAME      STATUS    VOLUME   CAPACITY   STORAGECLASS   AGE
n8n-work  Pending                                      10m
```
No binding progress, no storage class events.

**Cause:**
The 8gears chart requires both `main.persistence.enabled: true` AND
`main.persistence.type: dynamic`. Without `type: dynamic`, the chart silently
falls back to `emptyDir` — no error emitted.

**Fix:**
Both are set in this template's `deploy/apps/n8n/values-dev.yaml`:
```yaml
main:
  persistence:
    enabled: true
    type: dynamic
    size: 5Gi
```
If the PVC is still Pending, check `kubectl get storageclass` — k3d ships
`local-path` as the default.

---

## Problem: ArgoCD sync stuck with "permission denied" or "repository not found"

**Symptom:**
ArgoCD UI shows `ComparisonError: failed to load target state` or a repository
not found error on one or more Applications.

**Cause 1 — wrong repoURL.**
After forking, the `repoURL` fields in `deploy/argocd/` still point at
`hjr15/service-platform-template`. ArgoCD watches the upstream template (a
public repo it can read, but your pushes never reach it) so your changes
never deploy.

**Fix:** rewrite every `repoURL` to your fork. This is now part of
[setup.md Step 1](setup.md#step-1-fork-clone-and-point-argocd-at-your-fork) —
run the `sed` one-liner there, then commit and push. ArgoCD reconciles on the
next sync cycle.

**Cause 2 — fork is private and no Repository credentials are configured.**
The default setup expects a public fork. If yours is private, ArgoCD authenticates
to nothing and gets a 404 from GitHub. See the "If your fork is private" section
in [docs/setup.md](setup.md) for the deploy-key path.

---

## Problem: Self-signed cert warning won't go away in browser

**Symptom:**
Every session shows "Your connection is not private" for the workload URLs.

**Cause:**
Expected. The default `selfsigned` ClusterIssuer produces a cert with no chain
to a trusted root CA. Browsers don't trust it.

**Fix:**
- **Accept it each session** — fine for local dev.
- **Add cert to OS trust store** — extract the CA cert from the cluster and
  add it via Keychain Access (macOS) or `update-ca-certificates` (Ubuntu).
- **Switch to real certs** — see
  `docs/examples/cert-manager-letsencrypt-route53/README.md` for the Route53
  DNS-01 path.

---

## Problem: `make k8s-up` succeeds but no pods appear for many minutes

**Symptom:**
Workload namespaces (jupyter, n8n, vaultwarden) are empty or pods sit in
`ContainerCreating` / `Init:0/1` with no obvious errors.

**Cause:**
Slow image pulls. Jupyter datascience-notebook is ~2 GB; n8n is ~600 MB.
First-time pulls on a home connection take 5-15 minutes.

**Fix:**
Watch progress:
```bash
kubectl get pods -A -w
kubectl get events -n jupyter --sort-by=.lastTimestamp
```
You'll see `Pulling image "quay.io/jupyter/..."` events. Just wait. If events
show `ErrImagePull` after 20+ minutes, check the image tag still exists
upstream.

---

## Problem: ArgoCD loads fine but workload URLs return 404

**Symptom:**
`https://argocd.svc.localhost` works. `https://jupyter.svc.localhost` (or n8n,
vaultwarden) returns a 404 or Traefik "no route found".

**Cause:**
Two common causes: (1) `/etc/hosts` not updated — Traefik routes by Host header
and drops requests it doesn't recognise; (2) TLS cert not yet issued — cert-manager
can take ~5 minutes on first install.

**Fix:**
Check `/etc/hosts` includes entries like:
```
127.0.0.1  argocd.svc.localhost jupyter.svc.localhost n8n.svc.localhost vaultwarden.svc.localhost
```
Check certificate status:
```bash
kubectl get certificate -A
kubectl describe certificate jupyter-tls -n jupyter  # if READY=False
```
The `Events` section on the certificate shows why issuance failed.

---

## Problem: CI `validate.yml` fails on `helm template` for cert-manager

**Symptom:**
GitHub Actions fails with:
```
Error: chart "cert-manager" matching v1.20.2 not found in jetstack index.
```
or a Helm version compatibility error.

**Cause:**
The validate workflow pins cert-manager to `v1.20.2`. If the upstream repo
restructured or the version was yanked, `helm repo update` + `helm template`
fails.

**Fix:**
Verify the version still exists on `https://charts.jetstack.io`. If it was
removed, bump both the `--version` flag in `.github/workflows/validate.yml`
and `targetRevision` in `deploy/argocd/infra/cert-manager-app.yaml` to the
same known-good version — they must stay in sync.

---

## Problem: `init-env.sh` doesn't replace placeholder values

**Symptom:**
After running `scripts/init-env.sh`, `.env` still contains `replace_me` for
variables that should have been auto-generated.

**Cause:**
`init-env.sh` detects auto-generate targets by looking for an
`# auto-generate:` comment on the line **immediately** before the variable
declaration. A blank line or extra comment between them breaks detection
silently.

**Fix:**
In `.env.example` and your `.env`, the magic comment must be directly above
the variable:
```bash
# auto-generate: openssl rand -hex 32
N8N_ENCRYPTION_KEY=replace_me
```
The template's `.env.example` already has this correct. If you hand-edited
`.env` and introduced blank lines between the comment and the variable, remove
them.

---

## Where to ask for help

Open an issue at the template repo:
**<https://github.com/hjr15/service-platform-template/issues>**

Include: what you ran, the full error output as a code block, `kubectl version`
and `k3d version`, and which step of `docs/setup.md` you're on.

For issues that are clearly in an upstream component rather than this
template's config, contact the upstream project directly:

- cert-manager: <https://github.com/cert-manager/cert-manager/issues>
- n8n (8gears chart): <https://github.com/8gears/n8n-helm-chart/issues>
- vaultwarden (guerzon chart): <https://github.com/guerzon/vaultwarden/issues>
- vaultwarden (server): <https://github.com/dani-garcia/vaultwarden/issues>
- ArgoCD: <https://github.com/argoproj/argo-cd/issues>
