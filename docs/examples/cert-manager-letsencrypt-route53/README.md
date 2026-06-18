# Let's Encrypt via Route53 DNS-01 (opt-in)

## What this is

An upgrade from the default self-signed certificates to real Let's Encrypt certs
via DNS-01 challenge against AWS Route53. The default ClusterIssuer
(`cert-manager/clusterissuer-selfsigned.yaml`) produces self-signed certs that
browsers warn about. This path produces certs trusted by all browsers.

Manifests in this directory:

- `clusterissuer-letsencrypt-staging.yaml` — test issuer (use this first)
- `clusterissuer-letsencrypt-prod.yaml` — production issuer
- `route53-credentials-secret.yaml.example` — reference for the Secret that
  `scripts/k8s-up.sh` creates from your `.env`

## What you need

- AWS account with a Route53 hosted zone for your domain
- IAM permissions to create users, policies, and access keys
- AWS CLI configured locally

---

## Step-by-step setup

### 1. Find your hosted zone ID

```bash
aws route53 list-hosted-zones-by-name --dns-name svc.example.com \
  --query 'HostedZones[0].Id' --output text
# → /hostedzone/Z01234ABCDXYZ
```

### 2. Create IAM user and policy

```bash
aws iam create-user --user-name cert-manager-dns01

aws iam put-user-policy \
  --user-name cert-manager-dns01 \
  --policy-name cert-manager-route53 \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["route53:GetChange", "route53:ChangeResourceRecordSets",
                   "route53:ListResourceRecordSets"],
        "Resource": ["arn:aws:route53:::hostedzone/<your-route53-hosted-zone-id>",
                     "arn:aws:route53:::change/*"]
      },
      {
        "Effect": "Allow",
        "Action": ["route53:ListHostedZonesByName"],
        "Resource": "*"
      }
    ]
  }'
```

Create an access key and save the output to your password manager:

```bash
aws iam create-access-key --user-name cert-manager-dns01
```

### 3. Edit `.env`

```bash
ACME_EMAIL=you@example.com
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_HOSTED_ZONE_ID=Z01234ABCDXYZ
```

`k8s-up.sh` reads these to create the `route53-credentials` Secret in
`cert-manager` at boot time.

### 4. Substitute placeholders in the example manifests

```bash
sed -i 's|<your-domain>|svc.example.com|g' \
  docs/examples/cert-manager-letsencrypt-route53/*.yaml
sed -i 's|<your-acme-email>|you@example.com|g' \
  docs/examples/cert-manager-letsencrypt-route53/*.yaml
sed -i 's|<your-route53-hosted-zone-id>|Z01234ABCDXYZ|g' \
  docs/examples/cert-manager-letsencrypt-route53/*.yaml
```

Note: both ClusterIssuers default to `region: us-east-1`. Route 53 is a
global service, but the cert-manager solver still needs a region for its
STS calls — edit it to match your account's preferred region.

### 5. Apply ClusterIssuers

```bash
kubectl apply -f docs/examples/cert-manager-letsencrypt-route53/clusterissuer-letsencrypt-staging.yaml
kubectl apply -f docs/examples/cert-manager-letsencrypt-route53/clusterissuer-letsencrypt-prod.yaml
```

### 6. Switch workloads to staging first

In each values file, change the Ingress annotation:

```diff
 ingress:
   annotations:
-    cert-manager.io/cluster-issuer: selfsigned
+    cert-manager.io/cluster-issuer: letsencrypt-staging
```

Once staging issues successfully, switch to `letsencrypt-prod`.

---

## Verifying issuance

```bash
kubectl get certificate -A
kubectl describe certificate n8n-tls -n n8n
```

Look for `Certificate issued successfully` in the Events. If it stalls, check
the `CertificateRequest` object and cert-manager pod logs for detail.

---

## Common pitfalls

- **DNS propagation.** cert-manager waits for the TXT record to appear before
  completing the challenge. Usually 1-2 minutes; can be longer if your
  registrar caches aggressively.
- **LE rate limits.** 5 issuances per cert name per week on prod. Always use
  staging until confirmed working. If you hit the limit, wait a week.
- **IAM perms.** Verify: `aws sts get-caller-identity`. If it fails, the key
  was copied incorrectly. cert-manager logs show `AccessDenied` if the policy
  is wrong: `kubectl logs -n cert-manager deployment/cert-manager`.
