# cert-manager

cert-manager is a Kubernetes operator that automates the lifecycle of TLS certificates. You declare what certificate you want (via a `Certificate` resource or an annotation on an Ingress), point it at an issuer, and cert-manager handles the rest: requesting the cert, storing it in a Kubernetes Secret, and renewing it before it expires. When a cert renews, Traefik picks up the new Secret automatically — no manual restarts required.

cert-manager supports multiple issuer types: self-signed (no external dependency), Let's Encrypt (free public CA via ACME protocol), and various enterprise CAs. Workloads reference a `ClusterIssuer` by name in their Ingress annotations; swapping issuers is a one-line change per Ingress. In this template, cert-manager is deployed and managed by ArgoCD as part of the infra tier — you don't interact with it directly for day-to-day operations.

## The default: self-signed

Out of the box, this template uses a `selfSigned` ClusterIssuer. The manifest is at `cert-manager/clusterissuer-selfsigned.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

When cert-manager sees an Ingress annotated with `cert-manager.io/cluster-issuer: selfsigned`, it mints a certificate signed by its own private key — no external CA involved, no DNS validation, no rate limits, no network calls outside the cluster.

**The browser warning** (NET::ERR_CERT_AUTHORITY_INVALID or similar) is expected. It means the cert exists and TLS is working, but the browser doesn't trust the CA that signed it because it's not in your OS trust store. For local development, click through or add the cert to your trust store. `curl` users: add `-k` to skip verification.

Self-signed is enough when:
- You're developing locally and the only client is your own browser
- You're behind another authentication boundary (VPN, bastion, internal network)
- You're testing TLS configuration before switching to real certs

Self-signed is not enough when:
- Mobile clients need to connect (iOS/Android are stricter about untrusted certs and don't let users click through as easily)
- You're sharing URLs with people who don't control their trust stores
- You want automated cert rotation without re-distributing certs

## Why you'd upgrade to real certs

The main reasons to switch to Let's Encrypt:

- **No browser warning** — certs chain to a public CA that browsers trust by default
- **Mobile client support** — iOS and Android apps can connect without manual trust store changes
- **Shareable URLs** — you can send a link to a colleague without walking them through clicking past a security warning
- **Automated renewal** — Let's Encrypt certs last 90 days; cert-manager renews them ~30 days before expiry without any manual action

The trade-off is that you need a real public domain and API access to your DNS provider. The cluster itself does not need to be publicly reachable.

## Upgrade path: Let's Encrypt DNS-01

cert-manager supports two ACME challenge types. **HTTP-01** requires the cluster to be reachable from the internet (Let's Encrypt's servers make an HTTP request to verify domain ownership). **DNS-01** does not — it proves ownership by creating a TXT record in your DNS zone using an API key. For a local cluster, DNS-01 is the right choice.

What you need before starting:

- A real public domain you control (e.g., `example.com`) — you can use a subdomain like `svc.example.com`
- A supported DNS provider with API access: Route53, Cloudflare, DigitalOcean, GCP Cloud DNS, Azure DNS, and [many others](https://cert-manager.io/docs/configuration/acme/dns01/)
- Edit `.env`: set `DOMAIN=svc.example.com` and `ACME_EMAIL=you@example.com`
- API credentials for your DNS provider (see the worked examples below)

## Worked example: Cloudflare

### 1. Create a Cloudflare API token

Go to https://dash.cloudflare.com/profile/api-tokens → **Create Token** → **Custom token**.

Required permissions for the token:
- **Zone → DNS → Edit** (for the zone your domain is in)
- **Zone → Zone → Read** (for the same zone)

Scope it to the specific zone (not all zones) for least privilege.

### 2. Create a Kubernetes Secret with the token

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: <your-cloudflare-api-token>
```

Apply it:

```bash
kubectl apply -f cloudflare-api-token-secret.yaml
```

Do not commit this file — it contains a credential. Add it to `.gitignore` or delete it after applying.

### 3. Create a ClusterIssuer for Cloudflare DNS-01

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com   # must match ACME_EMAIL in .env
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

Save this as `cert-manager/clusterissuer-letsencrypt-prod.yaml`.

### 4. Apply the ClusterIssuer

```bash
kubectl apply -f cert-manager/clusterissuer-letsencrypt-prod.yaml
```

Or add it to the `cert-manager/` directory and push — the `cert-manager-clusterissuers` Application watches that directory and will pick it up automatically.

### 5. Update workload Ingress annotations

Each workload Ingress is annotated with the issuer name. Change it from `selfsigned` to `letsencrypt-prod` in each workload's `values-dev.yaml`:

```yaml
# deploy/apps/n8n/values-dev.yaml (find the ingress annotations section)
ingress:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod   # was: selfsigned
```

Do the same for `deploy/apps/jupyter/values-dev.yaml` and `deploy/apps/vaultwarden/values-dev.yaml`. Push to git and ArgoCD will apply the updated Ingresses, triggering cert-manager to request new certs from Let's Encrypt.

**First-time note:** cert-manager will delete the existing self-signed Secret and replace it with the Let's Encrypt cert. During the ~1–2 minutes that issuance takes, the Ingress may briefly return a TLS error. This is normal.

## Worked example: AWS Route53

The repo ships ready-to-use example manifests at `docs/examples/cert-manager-letsencrypt-route53/`:

```
docs/examples/cert-manager-letsencrypt-route53/
├── clusterissuer-letsencrypt-prod.yaml     # ClusterIssuer pointing at Route53
├── clusterissuer-letsencrypt-staging.yaml  # Same, but uses LE staging CA
└── route53-credentials-secret.yaml.example # Secret template (do not commit)
```

**IAM requirements.** The AWS user or role cert-manager uses needs these permissions, scoped to your hosted zone:

```json
{
  "Effect": "Allow",
  "Action": [
    "route53:GetChange",
    "route53:ChangeResourceRecordSets",
    "route53:ListHostedZonesByName"
  ],
  "Resource": [
    "arn:aws:route53:::hostedzone/<YOUR_ZONE_ID>",
    "arn:aws:route53:::change/*"
  ]
}
```

**Steps:**

1. Add your AWS credentials and hosted zone to `.env`:
   ```
   ACME_EMAIL=you@example.com
   AWS_ACCESS_KEY_ID=AKIA...
   AWS_SECRET_ACCESS_KEY=...
   AWS_HOSTED_ZONE_ID=Z...
   ```

2. `make k8s-up` (or re-run `scripts/k8s-up.sh`) — Phase 3 reads the AWS variables from `.env` and applies the `route53-credentials` Secret to the `cert-manager` namespace.

3. Edit `docs/examples/cert-manager-letsencrypt-route53/clusterissuer-letsencrypt-prod.yaml` — replace `<your-acme-email>`, `<your-domain>`, `<your-route53-hosted-zone-id>`, and the region with your values.

4. Copy the edited manifest to `cert-manager/clusterissuer-letsencrypt-prod.yaml` and push. ArgoCD applies it.

5. Update Ingress annotations in workload values to `letsencrypt-prod` (same as step 5 in the Cloudflare example).

**Use staging first.** The `clusterissuer-letsencrypt-staging.yaml` uses `https://acme-staging-v02.api.letsencrypt.org/directory`, which has much higher rate limits and is free to hammer. Staging certs aren't trusted by browsers, but they let you verify the DNS challenge works before burning production quota. Switch to `letsencrypt-prod` only once staging issuance succeeds.

## Other DNS providers

cert-manager's DNS-01 solver supports a long list of providers beyond Cloudflare and Route53:

- DigitalOcean
- Google Cloud DNS
- Azure DNS
- Oracle Cloud DNS
- AliDNS
- RFC 2136 (any DNS server that supports dynamic updates)
- Webhook solvers for providers not natively supported

Full list and configuration examples: https://cert-manager.io/docs/configuration/acme/dns01/

## Verifying issuance

Check certificate status across all namespaces:

```bash
kubectl get certificate -A
```

Expected output when everything is working:

```
NAMESPACE     NAME            READY   SECRET          AGE
n8n           n8n-tls         True    n8n-tls         5m
jupyter       jupyter-tls     True    jupyter-tls     5m
vaultwarden   vaultwarden-tls True    vaultwarden-tls 5m
```

`READY: True` means the cert was issued and stored in the Secret. If it's `False`, get more detail:

```bash
kubectl describe certificate n8n-tls -n n8n
```

Look at the `Events` and `Status.Conditions` sections. cert-manager logs the challenge lifecycle there.

**Common failure modes:**

- `Failed to perform DNS01 challenge` — your API credentials don't have the right permissions, the zone ID is wrong, or the credential Secret is in the wrong namespace. Double-check the IAM policy / API token scopes and the Secret name referenced in the ClusterIssuer.

- `Certificate stuck in Pending` — DNS propagation is taking longer than expected. TXT record creation can take 1–5 minutes before Let's Encrypt's validators see it. This usually resolves on its own. If it's been more than 10 minutes, run `kubectl describe certificaterequest -n <ns>` to see the challenge status.

- `acme: urn:ietf:params:acme:error:rateLimited` — Let's Encrypt production has a limit of 5 issuances per registered domain per week per unique cert name. Switch to the staging issuer while iterating. Rate limits reset weekly; you can check current usage at https://crt.sh.

- `x509: certificate signed by unknown authority` in pod logs — a workload is trying to verify a self-signed cert without `-k` / InsecureSkipVerify. Not a cert-manager issue; configure the workload to skip TLS verification or add the CA to its trust bundle.

## Troubleshooting

For more detailed diagnostics — including inspecting `CertificateRequest` and `Order` objects, cert-manager controller logs, and checking whether a challenge TXT record was actually created in DNS — see [docs/troubleshooting.md](troubleshooting.md).
