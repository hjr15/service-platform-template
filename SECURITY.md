# Security policy

## Reporting security issues

**Do not open a public GitHub Issue for security vulnerabilities.** Public
disclosure before a fix is ready gives attackers a head start.

Instead, report it privately through the repository's
**Security → Advisories → "Report a vulnerability"** tab on GitHub.

> **Forking this template?** GitHub private vulnerability reporting works
> out of the box on your fork — or replace this section with a direct
> contact address of your own.

Include:
- A description of the issue and what an attacker could do with it
- Steps to reproduce (the more specific, the faster a fix can land)
- Whether you have a suggested fix

You'll receive an acknowledgement within about a week.

---

## Scope — what's covered

Security issues in **this template's own code and documentation**:

- Default config that leaks credentials or exposes internal endpoints publicly
- Privilege escalation in `scripts/k8s-up.sh` or `scripts/init-env.sh`
- Template patterns that accidentally publish user data (e.g., writing secrets
  to git)
- Documentation that instructs users to do something insecure by default

---

## Scope — what's NOT covered

Issues in **upstream components** are not in scope for this template's security
process. For those, contact the upstream project directly:

- **cert-manager** — <https://github.com/cert-manager/cert-manager/security>
- **n8n / 8gears chart** — <https://github.com/8gears/n8n-helm-chart/issues>
  and <https://github.com/n8n-io/n8n/security>
- **vaultwarden (guerzon chart)** — <https://github.com/guerzon/vaultwarden/issues>
- **vaultwarden (server)** — <https://github.com/dani-garcia/vaultwarden/security>
- **Kubernetes / k3d / Docker / ArgoCD** — contact those projects' security
  teams directly

---

## Response timeline

This is a personal project, not a commercial product. Response timelines are
best-effort:

- **Acknowledgement** — within ~1 week of receiving the report
- **Fix + disclosure** — coordinated within 30-90 days depending on complexity

If you haven't heard back within 2 weeks, follow up on the advisory thread.

---

## Disclosure policy

Coordinated disclosure: you report privately, we agree on a fix timeline, the
fix lands before any public announcement, and we coordinate the disclosure date
with you. We won't share your name or contact details without your permission.
