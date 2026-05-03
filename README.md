# Supabase Preview Stacks on Hetzner

Opinionated dev infrastructure for running cheap, disposable Supabase preview
environments on one Hetzner VPS.

This is a self-hosted, hackable approximation of Supabase branching for preview
apps, workstreams, and agent-driven development. It is intentionally not a
general-purpose hosting platform.

## Status

This is an early, opinionated dev-infra starter. It is useful as a working
baseline, but it is not heavily battle-tested across teams, providers, regions,
or long-running servers. Expect to read the scripts, adapt them, and own the
operational risks.

## What You Get

- One isolated Supabase stack per project, branch, or workstream.
- Separate API and Studio subdomains for each stack, such as `feature-login.dev.example.com` and `studio-feature-login.dev.example.com`.
- Automated Hetzner server provisioning.
- Automated DNS records with DNSimple, or printed manual records for Route53.
- Wildcard TLS with Let's Encrypt.
- nginx routing for API, auth, storage, and Studio.
- Generated Postgres password, JWT secret, anon key, service role key, and Studio login per stack.
- Optional helpers for Vercel env merging and `.env.local` switching.

## Development Only

This repo is designed for development and preview environments, not production.

The default stack favors speed, low cost, and easy teardown over production-grade
hardening. Before exposing this to teammates or the public internet, read
[`SECURITY.md`](SECURITY.md).

## Architecture

```text
*.dev.example.com
        |
        v
   Hetzner VPS
        |
        v
      nginx
   feature-login.dev.example.com
      /auth/v1     -> Kong -> GoTrue
      /rest/v1     -> Kong -> PostgREST
      /storage/v1  -> Kong -> Storage API

   studio-feature-login.dev.example.com
      /            -> Supabase Studio, protected by basic auth
        |
        v
 project-a containers   project-b containers   project-c containers
 ports 54320-54339      ports 54340-54359      ports 54360-54379
```

Each stack runs Docker Compose services for Postgres, Kong, GoTrue, PostgREST,
Supabase Studio, postgres-meta, and Storage.

## Prerequisites

- [hcloud CLI](https://github.com/hetznercloud/cli): `brew install hcloud`
- A Hetzner Cloud API token: `hcloud context create dev-infra`
- A domain managed by DNSimple or Route53 for wildcard certificate DNS challenges
- An SSH key pair; the public key can be uploaded automatically
- `ssh`, `scp`, `curl`, `jq`, and `python3` locally

## Before You Start

You need to choose only a few real values before running the scripts:

- `DEV_DOMAIN`: a disposable dev subdomain, such as `sb-dev.example.com`.
- `DNS_PROVIDER`: `dnsimple` or `route53`.
- `DNSIMPLE_TOKEN`: required for DNSimple DNS records and certificate challenges.
- `LETSENCRYPT_EMAIL`: any real email address for certificate notices.
- `SSH_KEY_PATH`: your local private key path, such as `~/.ssh/id_hetzner`.
- `HETZNER_SSH_KEY_NAME`: an existing Hetzner SSH key name, or a new name to create from `SSH_KEY_PATH.pub`.

You do not need to know the VPS IP ahead of time. `provision.sh` creates or
reuses the VPS, discovers its IP, writes `.server-ip`, and uses that IP for DNS.

You also do not need to manually create `DEV_DOMAIN` when using DNSimple. The
script creates the base and wildcard A records for you.

## DNS Support

| Provider | DNS records | Let's Encrypt wildcard cert |
| --- | --- | --- |
| DNSimple | Automated by `provision.sh` | Automated by `bootstrap.sh` |
| Route53 | Printed for manual creation | Automated by `bootstrap.sh` |

For DNSimple, `provision.sh` creates or updates:

```text
A  DEV_DOMAIN
A  *.DEV_DOMAIN
```

For Route53, create those records manually after `provision.sh` prints the VPS
IP, then run `bootstrap.sh`.

## VPS Size

Use at least `cpx31` for a realistic smoke test or day-to-day development. The
full Supabase stack runs multiple containers and tiny VPS sizes can be too tight.

For short tests, create a temporary server and delete it afterward to avoid
ongoing cost.

## Quick Start

### 1. Configure

```bash
cp .env.example .env
```

Edit `.env`:

| Variable | Description |
| --- | --- |
| `HETZNER_SERVER_NAME` | Name for the VPS |
| `HETZNER_SERVER_TYPE` | Server size, such as `cax31` |
| `HETZNER_LOCATION` | Hetzner datacenter, such as `hil` or `ash` |
| `HETZNER_SSH_KEY_NAME` | SSH key name in Hetzner, or `none` |
| `SSH_KEY_PATH` | Local private key path matching the Hetzner public key |
| `DEV_DOMAIN` | Base wildcard domain, such as `dev.example.com` |
| `DNS_PROVIDER` | DNS provider used for Let's Encrypt DNS challenges: `dnsimple` or `route53` |
| `DNSIMPLE_TOKEN` | DNSimple token, only for `dnsimple` |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt certificates |
| `SUPABASE_PORT_BASE` | First stack port block start, default `54320` |
| `SUPABASE_PORT_BLOCK` | Ports reserved per stack, default `20` |

For Route53, provide `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in your
environment or `.env`.

### 2. Provision the VPS

```bash
./scripts/provision.sh
```

This creates or reuses the Hetzner server, attaches a firewall for SSH/HTTP/HTTPS,
creates DNS records when using DNSimple, and writes the server IP to `.server-ip`.
For Route53, it prints the A records to create manually.

### 3. Bootstrap the VPS

```bash
./scripts/bootstrap.sh
```

This installs Docker, nginx, jq, certbot, DNS challenge plugins, uploads the stack
templates, and obtains a wildcard certificate.

### 4. Create a Supabase Stack

```bash
./scripts/stack.sh create feature-login
```

Stack names must be DNS-safe labels up to 56 characters: lowercase letters,
numbers, and dashes; no leading or trailing dash. The shorter limit leaves room
for the generated `studio-<name>` hostname.

The command prints connection details:

```bash
SUPABASE_URL=https://feature-login.dev.example.com
SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
Studio URL: https://studio-feature-login.dev.example.com
Studio username: studio
Studio password: ...
```

### 5. Print App Environment Variables

```bash
./scripts/stack.sh env feature-login
```

Example output:

```bash
SUPABASE_URL=https://feature-login.dev.example.com
SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
NEXT_PUBLIC_SUPABASE_URL=https://feature-login.dev.example.com
NEXT_PUBLIC_SUPABASE_ANON_KEY=...
DATABASE_URL=postgresql://...
```

`DATABASE_URL` points at a database port bound to the VPS localhost. Use it from
processes running on the VPS, or through an SSH tunnel. Do not expose database
ports publicly.

### 6. Print Studio Credentials

```bash
./scripts/stack.sh studio feature-login
```

Example output:

```bash
SUPABASE_STUDIO_URL=https://studio-feature-login.dev.example.com
SUPABASE_STUDIO_USERNAME=studio
SUPABASE_STUDIO_PASSWORD=...
SUPABASE_API_URL=https://feature-login.dev.example.com
```

## Commands

| Command | Description |
| --- | --- |
| `./scripts/provision.sh` | Create or reuse the Hetzner VPS and configure or print DNS records |
| `./scripts/bootstrap.sh` | Install server dependencies, SSL, nginx, and templates |
| `./scripts/stack.sh create <name>` | Create and start a new Supabase stack |
| `./scripts/stack.sh destroy <name> [--force]` | Tear down a stack and delete its data |
| `./scripts/stack.sh list` | List active stacks |
| `./scripts/stack.sh status <name>` | Show container status for a stack |
| `./scripts/stack.sh restart <name>` | Restart all containers in a stack |
| `./scripts/stack.sh env <name>` | Print env vars for a stack |
| `./scripts/stack.sh studio <name>` | Print Studio URL and basic auth credentials |

## Workstream Helpers

For projects that combine Supabase with Vercel or similar preview workflows, the
workstream scripts can create a stack, pull base env vars, merge the Supabase
overlay, and switch `.env.local`.

Workstream names follow the same DNS-safe naming rule as stack names.

| Command | Description |
| --- | --- |
| `./scripts/init-workstream.sh <name> [project-dir]` | Create stack, merge envs, activate `.env.local` |
| `./scripts/switch-workstream.sh <name> [project-dir]` | Point `.env.local` at an existing workstream |
| `./scripts/teardown-workstream.sh <name> [project-dir] [--force]` | Destroy stack and clean local workstream files |

## Updating Scripts or Templates

`bootstrap.sh` uploads the current local stack scripts and templates to the VPS.
If you change files under `scripts/` or `templates/`, run it again:

```bash
./scripts/bootstrap.sh
```

Existing generated stacks are not automatically rewritten. Recreate a stack if
you need it to pick up changed Docker Compose or nginx templates.

## Cleanup

Destroy a stack and its Docker volumes:

```bash
./scripts/stack.sh destroy <name> --force
```

Delete the VPS when you no longer need the dev host:

```bash
hcloud server delete "$HETZNER_SERVER_NAME"
hcloud firewall delete "${HETZNER_SERVER_NAME}-fw"
```

If you used DNSimple automation and want to remove the DNS records too, delete:

```text
A  DEV_DOMAIN
A  *.DEV_DOMAIN
```

`.server-ip` is local state and can be removed after deleting the VPS.

## Troubleshooting

- `hcloud is not authenticated`: run `hcloud context create dev-infra`.
- `SSH key ... not found`: check `HETZNER_SSH_KEY_NAME`, `SSH_KEY_PATH`, and that `SSH_KEY_PATH.pub` exists.
- `DNS CLOBBERING WARNING`: the dev domain already points at another IP. Do not pass `--force-dns` unless you are sure.
- Let’s Encrypt rejects the email: set `LETSENCRYPT_EMAIL` to a real email address.
- Certbot DNS challenge fails: verify the DNS token can edit the zone for `DEV_DOMAIN`.
- `No .server-ip file`: run `./scripts/provision.sh` before `bootstrap.sh` or `stack.sh`.
- Stack creation is slow the first time: Docker images are being pulled on the VPS.
- `DATABASE_URL` does not connect locally: the database port binds to VPS localhost; use an SSH tunnel or run the client on the VPS.

## Security Defaults

- `.env`, `.server-ip`, `.env.local`, and `.workstreams/` are gitignored.
- Each stack gets generated database, JWT, anon, service role, and Studio credentials.
- Supabase Studio runs on a separate hostname and is protected with per-stack basic auth.
- Studio credentials are retrieved with `./scripts/stack.sh studio <name>`, not included in app env output.
- Supabase API routes remain publicly reachable at the stack subdomain and rely on Supabase keys/policies.
- The service role key is printed for server-side tooling only; never expose it to browser code.
- The Hetzner firewall exposes only SSH, HTTP, and HTTPS.
- Stack secrets are stored on the server under `/opt/supabase/stacks/<name>/metadata.json`.

## Known Tradeoffs

- This uses root SSH for simple server automation.
- One VPS is one blast radius for all preview stacks.
- It does not manage backups, upgrades, observability, team access, or data branching.
- Supabase image versions are pinned in `templates/docker-compose.yml.tpl` and must be updated manually.
- DNS automation is intentionally small: DNSimple records are automated; DNSimple and Route53 are supported for certbot DNS challenges.
- Studio basic auth is applied when a stack is created; recreate existing stacks to pick up the generated Studio hostname and credentials.
- This is cheaper and more controllable than managed preview stacks, but you own the operations.

## File Structure

```text
.env.example                      # Template configuration
.env                              # Local configuration, gitignored
.server-ip                        # Current server IP, gitignored
scripts/
  provision.sh                    # Create Hetzner server and DNS records
  bootstrap.sh                    # Install server dependencies and SSL
  stack.sh                        # Local wrapper that SSHes to the server
  stack-remote.sh                 # Remote stack manager uploaded to the server
  init-workstream.sh              # Create stack and merge env files
  switch-workstream.sh            # Switch active workstream
  teardown-workstream.sh          # Destroy stack and clean up local files
templates/
  docker-compose.yml.tpl          # Supabase stack template
  nginx-site.conf.tpl             # Per-stack nginx config
  kong.yml.tpl                    # Kong API gateway config
SECURITY.md                       # Security model and hardening notes
```

## Non-Goals

- Production Supabase hosting.
- Full Supabase branching parity.
- Multi-cloud infrastructure management.
- Managed backups or disaster recovery.
- Team permissioning or audit logs.

## License

MIT. See [`LICENSE`](LICENSE).
