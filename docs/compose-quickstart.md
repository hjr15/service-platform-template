# Compose quickstart

Want to try Jupyter, n8n, or Vaultwarden without setting up a Kubernetes cluster? Each app ships a `docker-compose.yml` you can run standalone — no k3d, no ArgoCD, no cert-manager required. Just Docker.

## The annotated config catalogue

The compose files serve two purposes, and the second one is just as important as the first.

Each `docker-compose.yml` is an **annotated catalogue of every meaningful environment variable** for that app. Every env var is listed with a comment explaining what it does and — where applicable — which Helm values key it corresponds to. If you want to know what `N8N_ENCRYPTION_KEY` does, or what Helm key controls the Vaultwarden domain, reading the compose file is the fastest way to find it, because it's the place where the env var reference and the Helm mapping sit side by side.

This is the intent: even if you're running on Kubernetes and never touch `docker compose`, these files are the most thorough per-app config reference in the repo.

## Per-app quickstart

### n8n

n8n requires an encryption key at startup. Generate one and keep it — if you lose it, the credentials stored in n8n's database become permanently unreadable.

```bash
cd deploy/apps/n8n
export N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
echo "SAVE THIS: $N8N_ENCRYPTION_KEY"
docker compose up
```

Browse to **http://localhost:5678**.

On first launch, n8n shows an **owner setup wizard** asking for your name, email address, and a password. This creates the owner account — there's no default credential. Complete the wizard before doing anything else.

**Important:** The `N8N_ENCRYPTION_KEY` is used to encrypt every credential you save inside n8n (API keys, OAuth tokens, etc.). If you restart the container with a different key, those credentials will be unreadable and you'll need to re-enter them. Store the key somewhere safe (a password manager, not a sticky note).

Data persists in a named Docker volume (`n8n-data`). It survives `docker compose down` and `docker compose up` cycles, but is removed by `docker volume rm n8n_n8n-data`.

### Vaultwarden

Vaultwarden needs an admin token to protect its `/admin` endpoint. Generate one before starting:

```bash
cd deploy/apps/vaultwarden
export VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -hex 48)
echo "SAVE THIS: $VAULTWARDEN_ADMIN_TOKEN"
docker compose up
```

Browse to **http://localhost:8080**.

The main page is the web vault login. Click **Create Account** to register the first user — this becomes the vault owner. Note that this is running HTTP only (no TLS) in compose mode, so avoid using it over an untrusted network.

The **admin panel** is at http://localhost:8080/admin — authenticate with the `VAULTWARDEN_ADMIN_TOKEN` you generated. From there you can invite users, configure SMTP, and inspect the server state.

**The admin token is not your vault master password.** The master password protects your vault data; the admin token protects the admin panel configuration UI. They're separate.

Data persists in the `vaultwarden-data` volume. Vaultwarden's default database is SQLite at `/data/db.sqlite3` inside the volume.

### Jupyter

Jupyter doesn't need any pre-generated secrets — it generates a random access token on startup.

```bash
cd deploy/apps/jupyter
docker compose up
```

Browse to **http://localhost:8888**.

The token is printed in the container logs on first start. Find it:

```bash
docker logs jupyter | grep token=
```

You'll see a line like:

```
    http://127.0.0.1:8888/lab?token=abc123def456...
```

Copy the token value (everything after `token=`) and paste it in the Jupyter login field. Alternatively, copy the whole URL — the browser will use the token from the query parameter automatically.

Notebooks and data persist in the `jupyter-work` volume at `/home/jovyan/work` inside the container.

## Limitations

Running via Docker Compose is convenient for a quick trial, but it's intentionally limited compared to the full Kubernetes setup:

- **No TLS** — all three apps run on plain HTTP over localhost. Don't expose these ports on a public interface without adding a TLS proxy in front.
- **No ingress / hostname routing** — access is via `localhost:<port>` direct port mapping, not via hostname. You can't use `n8n.svc.localhost` in compose mode.
- **No GitOps** — there's no declarative state in git and no automatic reconciliation. If you edit a container's config or a volume's contents, that change only exists locally.
- **No inter-app integration** — running all three simultaneously requires manual port juggling (the default ports don't conflict, but wiring n8n to Vaultwarden via URL requires knowing the other container's address).
- **Volume removal deletes data** — `docker compose down` preserves the named volumes; `docker compose down -v` or `docker volume rm` deletes them permanently. Export anything important before removing volumes.

## When to graduate to k8s

Move to the full Kubernetes setup when:

- You want **all three apps running together** with proper hostname routing (`n8n.svc.localhost`, `vaultwarden.svc.localhost`, etc.)
- You want **TLS** without managing a reverse proxy manually — cert-manager + Traefik handle it automatically
- You want **declarative state in git** — change an image tag in `values-dev.yaml`, push, ArgoCD applies it
- You want **automatic reconciliation** — if a pod crashes or drifts, ArgoCD restarts and corrects it
- You want to **add more apps** without wiring up ports and compose networks by hand

See [docs/setup.md](setup.md) for the full cluster bootstrap walkthrough and [docs/architecture.md](architecture.md) for how the pieces fit together.
