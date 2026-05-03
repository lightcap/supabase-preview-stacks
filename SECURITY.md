# Security

This project is for development and preview environments only.

It creates internet-reachable Supabase stacks on a VPS. Treat each stack as a
temporary dev environment and assume you are responsible for the server, DNS,
secrets, upgrades, and teardown.

This is not battle-tested infrastructure. Review the scripts before running them
against accounts, domains, or data you care about.

## What Is Exposed

- Port 22 for SSH.
- Port 80 for HTTP redirects and ACME flows.
- Port 443 for Supabase API routes and Studio.
- `https://<stack>.<dev-domain>/auth/v1/`, `/rest/v1/`, and `/storage/v1/` are public Supabase API routes.
- `https://studio-<stack>.<dev-domain>/` serves Supabase Studio and is protected with generated basic auth.

## Where Secrets Live

- Local `.env` contains provider tokens and is gitignored.
- Local `.server-ip` is gitignored.
- Workstream files under `.workstreams/` are gitignored.
- Remote stack metadata lives at `/opt/supabase/stacks/<name>/metadata.json`.
- Remote Studio basic auth files live at `/opt/supabase/stacks/<name>/studio.htpasswd`.
- Studio credentials can be retrieved with `./scripts/stack.sh studio <name>`.
- DNS challenge credentials may live under `/opt/supabase/certs/` on the server.

## Default Hardening

- Hetzner firewall allows only SSH, HTTP, and HTTPS inbound.
- Docker service ports bind to `127.0.0.1` and are reached through nginx.
- Each stack gets generated database, JWT, anon, service role, and Studio credentials.
- Supabase Studio uses a separate hostname and requires per-stack basic auth.
- Unknown hostnames are rejected by nginx.

## Important Caveats

- Root SSH is used for simplicity.
- One compromised VPS can expose every stack on that VPS.
- Supabase API routes are intentionally public and depend on keys, auth settings, and Row Level Security policies.
- `SUPABASE_SERVICE_ROLE_KEY` bypasses Row Level Security and must never be exposed to browser code.
- Direct database access requires running on the VPS or using an SSH tunnel; database ports are not publicly exposed.
- `GOTRUE_URI_ALLOW_LIST` is permissive for dev workflows.
- Email auth is auto-confirmed by default in the stack template.
- This project does not configure backups, centralized logs, monitoring, intrusion detection, or secret rotation.

## Before Sharing With Others

- Use a dedicated dev domain, not your production application domain.
- Use a dedicated Hetzner project and DNS API token with the smallest practical scope.
- Prefer a dedicated SSH key for this VPS.
- Review the generated `.env` and never commit it.
- Destroy stacks when they are no longer needed.
- Rotate provider tokens if `.env`, `.workstreams/`, `.server-ip`, or remote metadata are accidentally published.

## If You Need Stronger Isolation

- Use one VPS per app or customer.
- Restrict SSH to trusted IPs in the Hetzner firewall.
- Put Studio behind an IP allowlist or VPN in addition to basic auth.
- Disable signup or auto-confirmation in `templates/docker-compose.yml.tpl`.
- Add backups before keeping any data you care about.
