# ArgoCD

ArgoCD is a GitOps controller that runs inside your Kubernetes cluster. You point it at a git repository, and it continuously reconciles the cluster's live state with whatever is declared in that repo. Push a commit that changes an image tag or a resource limit, and ArgoCD detects the diff and applies the change — without you running `kubectl apply` manually. If someone edits a resource directly in the cluster (bypassing git), ArgoCD reverts it on the next reconciliation cycle. The git repo is always the source of truth.

In practice this means the cluster self-heals: pods that drift from the declared state get corrected, resources deleted from git get pruned from the cluster, and new manifests added to git get deployed automatically. You get a full audit log in git history, easy rollback via `git revert`, and no "what command did I run to get to this state" mystery.

## What it's doing in this template

ArgoCD manages everything in the cluster through a three-level Application hierarchy. The only resource applied manually (by `make k8s-up`) is the root Application. Everything else cascades from it:

```
service-platform-root          (the root — manually bootstrapped)
├── infra-app-of-apps          (sync wave -1 — infra first)
│   ├── cert-manager           → deploys jetstack/cert-manager chart v1.20.2
│   └── cert-manager-clusterissuers  → applies the selfsigned ClusterIssuer
└── apps-app-of-apps           (sync wave 0 — workloads after infra)
    ├── jupyter                → deploys in-repo Jupyter chart
    ├── n8n                    → deploys 8gears n8n OCI chart + values
    └── vaultwarden            → deploys guerzon vaultwarden chart + values
```

**service-platform-root** watches `deploy/argocd/infra-app-of-apps.yaml` and `deploy/argocd/apps-app-of-apps.yaml` in your git repo. It creates those two Applications in the cluster.

**infra-app-of-apps** (sync wave `-1`) watches `deploy/argocd/infra/`. It creates the `cert-manager` and `cert-manager-clusterissuers` Applications. The negative sync wave ensures cert-manager's CRDs are registered before any workload tries to create a `Certificate` object.

**apps-app-of-apps** (sync wave `0`) watches `deploy/argocd/apps/`. It creates the three workload Applications. Because it runs after the infra wave, cert-manager is already up when workloads try to get their TLS certificates.

Each of the leaf Applications (`cert-manager`, `jupyter`, `n8n`, `vaultwarden`) targets a specific Helm chart and a `values-dev.yaml` from this repo. Auto-sync, prune, and selfHeal are all enabled on every Application.

## Login + UI tour

Get the auto-generated admin password:

```bash
make argocd-pw
```

Then open **http://argocd.svc.localhost** (HTTP, not HTTPS — ArgoCD runs in insecure mode behind Traefik in this template).

- **Username:** `admin`
- **Password:** paste the output of `make argocd-pw`

The **Applications panel** shows every Application as a card. Each card displays the application name, namespace, the git repo and path it watches, and two status badges: Sync Status and Health Status. Cards are green when Synced + Healthy, yellow when progressing, red when degraded.

Click any card to open the **resource tree** — a visual graph of every Kubernetes object that Application manages: Deployments, Services, Ingresses, Certificates, PersistentVolumeClaims, and so on. Each node in the tree shows its own health state. This is useful for spotting exactly which sub-resource is failing when a top-level Application shows Degraded.

The **Sync** button in each Application view lets you trigger an immediate reconciliation. The **App Diff** button shows you exactly what would change in the cluster if you synced right now.

## Force a sync

ArgoCD polls the repo every 60 seconds (configured via `timeout.reconciliation: 60s` in `argocd/values-dev.yaml`). If you've just merged a change and don't want to wait even a minute, trigger a sync manually:

**Via the UI:** Open the Application card → click **Sync** → click **Synchronize** in the confirmation dialog.

**Via CLI:**

```bash
argocd app sync <name>
# Examples:
argocd app sync n8n
argocd app sync service-platform-root   # cascades to all children
```

If you want to sync everything at once:

```bash
argocd app sync -l 'argocd.argoproj.io/app-namespace=argocd'
```

You need to be logged in first:

```bash
argocd login argocd.svc.localhost --username admin --password "$(make argocd-pw)" --insecure
```

## See app state

Check the status of all Applications at a glance:

```bash
kubectl get app -n argocd
```

Expected output after a clean bootstrap:

```
NAME                          SYNC STATUS   HEALTH STATUS
apps-app-of-apps              Synced        Healthy
cert-manager                  Synced        Healthy
cert-manager-clusterissuers   Synced        Healthy
infra-app-of-apps             Synced        Healthy
jupyter                       Synced        Healthy
n8n                           Synced        Healthy
service-platform-root         Synced        Healthy
vaultwarden                   Synced        Healthy
```

**SYNC STATUS** describes whether the live cluster state matches what's in git:

- `Synced` — cluster matches git. Nothing to apply.
- `OutOfSync` — git has changed since the last sync. ArgoCD will apply the diff automatically within ~1–2 minutes (poll is every 60 seconds; apply adds a few seconds).
- `Unknown` — ArgoCD couldn't fetch the repo or render the templates. Usually a git auth issue or a broken Helm values reference.

**HEALTH STATUS** describes whether the resources ArgoCD applied are actually working:

- `Healthy` — all managed pods are running and passing readiness probes. Ingresses are routing.
- `Progressing` — resources were applied but pods haven't become ready yet (image pull, container startup, etc.). Normal to see this for a few minutes after a sync.
- `Degraded` — something is wrong. Pods are crash-looping, failing readiness probes, or the Deployment can't schedule at all. Check pod logs.
- `Missing` — resources that should exist don't. Usually means the Application was never synced, or prune deleted something it shouldn't have.

Add `-w` to watch for changes:

```bash
kubectl get app -n argocd -w
```

## Find logs

**Pod logs** — the most useful first stop when something isn't working:

```bash
# List pods in a namespace
kubectl get pods -n n8n
kubectl get pods -n jupyter
kubectl get pods -n vaultwarden
kubectl get pods -n cert-manager

# Tail logs from a specific pod
kubectl logs -n n8n <pod-name>

# Or use the Deployment shortcut (no need to look up the pod name)
kubectl logs -n n8n deploy/n8n
kubectl logs -n jupyter deploy/jupyter
kubectl logs -n vaultwarden deploy/vaultwarden
```

**ArgoCD application controller logs** — useful when ArgoCD itself can't render templates or sync:

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50
```

**ArgoCD repo server logs** — useful when git fetch or Helm render is failing:

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50
```

**Kubernetes events** — often the most informative for understanding why a pod won't schedule or a PVC won't bind:

```bash
kubectl describe app n8n -n argocd | tail -30
kubectl describe pod -n n8n <pod-name>
kubectl get events -n n8n --sort-by='.lastTimestamp'
```

## Common transitions you'll see

**After pushing a commit to git:**

1. `Synced` → `OutOfSync` (within ~60 seconds, when ArgoCD next polls the repo)
2. `OutOfSync` → `Synced` (a few seconds later, as ArgoCD applies the change)
3. `Healthy` → `Progressing` (as the rolling update starts)
4. `Progressing` → `Healthy` (when the new pod passes its readiness probe)

This whole sequence typically takes 2–5 minutes end to end. If you want it faster, force a sync with `argocd app sync <name>` right after pushing.

**After the initial cluster bootstrap:**

cert-manager has to install its CRDs before workloads can request certificates. The sync waves handle this automatically, but you may see workload Applications stuck in `Progressing` for a few extra minutes on first boot while cert-manager initialises. This resolves itself.

**Degraded:**

Usually means pods are crash-looping. The most common causes are: image pull failures (image tag doesn't exist, rate limit), readiness probe failing (app started but isn't healthy yet, or misconfigured probe), or a missing Secret (the workload Secret wasn't applied before ArgoCD synced). Check `kubectl logs` and `kubectl describe pod`.

**Unknown:**

ArgoCD can't connect to the git repo or can't render the Helm templates. Common causes: you forgot to update the `repoURL` in the Application manifests to point at your fork, a Helm chart version doesn't exist, or a `$values` reference in a multi-source Application is broken. Check the ArgoCD repo server logs.

## Common issues

See [docs/troubleshooting.md](troubleshooting.md) for step-by-step resolutions for specific failure patterns including:

- Application stuck in `OutOfSync` indefinitely
- Cert-manager ClusterIssuer not found at workload sync time
- ArgoCD shows Degraded but pod logs look fine (usually a readiness probe issue)
- `make argocd-pw` returns empty output (ArgoCD secret not yet created)
- Workload Secret missing (n8n or Vaultwarden failing to start)

## Going deeper

- **ArgoCD docs:** https://argo-cd.readthedocs.io — comprehensive reference for sync policies, RBAC, SSO, and notifications.
- **ApplicationSet:** When you have many similar Applications (e.g., one per tenant, one per environment), [ApplicationSet](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/) generates them from a generator (git directory, list, cluster generator). The plain Application approach in this template is easier to reason about at small scale; ApplicationSet is the natural upgrade path when you have 10+ apps.
- **Sync waves and hooks:** The [sync waves docs](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) explain the ordering mechanism used here (the `-1` on infra). Sync hooks let you run Jobs at specific phases (PreSync, PostSync) — useful for database migrations.
- **Health checks:** ArgoCD ships built-in health checks for common resource types. You can write [custom health checks](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/) in Lua for CRDs that ArgoCD doesn't know about natively.
