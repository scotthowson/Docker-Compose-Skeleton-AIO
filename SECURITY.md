# Security

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](https://github.com/scotthowson/Docker-Compose-Skeleton-AIO/security/advisories/new)
rather than in a public issue. Include the version (`cat VERSION`), how to reproduce, and what an
attacker gains. You will get an acknowledgement within a few days.

## What the API protects, and what it does not

DCS manages a Docker host. An **admin** account is, by design, equivalent to shell access on that
host: admins can deploy compose files, run commands in containers, edit `.env`, install plugins and
open the web terminal. The security model therefore concentrates on three things:

1. **Nobody gets in without an account.** Authentication is mandatory whenever the API listens on
   anything other than loopback. `API_AUTH_ENABLED=false` is ignored on a non-loopback bind unless
   `API_INSECURE_NO_AUTH=true` is also set, and the server prints a warning when it is.
2. **A fresh install cannot be hijacked.** Until the first admin account exists, only the setup
   endpoints (`/setup/status`, `/setup/defaults`, `POST /auth/setup`) and `GET /version` answer;
   every other route returns `401`. The same lockdown applies after a factory reset.
3. **A viewer is a viewer.** The `user` role can read operational data and manage its own session
   and profile. Every route that changes the system, executes code or exposes secrets requires
   `admin`. The router enforces this centrally (`_api_route_allowed`); handlers keep their own
   checks as defence in depth. The complete map is in [docs/API.md](docs/API.md).

### Accounts and sessions

- Passwords are hashed with PBKDF2-SHA256 (100,000 iterations, per-user salt) and compared in
  constant time; secrets are passed to the hashing helper through the environment, never argv.
- Session tokens are 256-bit random values with a configurable expiry; a new login revokes older
  sessions when `API_SINGLE_SESSION=true`. Optional TOTP (RFC 6238) two-factor login.
- Registration is invite-only; invites expire and are single-use.
- Login attempts are rate-limited per client address (`API_MAX_LOGIN_ATTEMPTS`,
  `API_LOCKOUT_DURATION`) and every request is rate-limited (`API_RATE_LIMIT` per
  `API_RATE_WINDOW`). Behind the DCS-UI container (or any proxy listed in `API_TRUSTED_PROXIES`)
  the real client address is taken from `X-Forwarded-For`, walked from the right so that a client
  cannot spoof its own address.

### Input handling

- Every path parameter is validated in the router before a handler runs (stack names, container
  names, template names, snapshot ids, image references, subdomains, version ids).
- `.env` files are read as **data**, never sourced: only `KEY=value` lines are accepted, values are
  literal, and a fixed list of shell/loader variables (`PATH`, `LD_PRELOAD`, `BASH_ENV`, ...) can
  never be set through the API. Writes reject command substitution and control characters.
- Compose content is scanned before it is written or deployed: `privileged`, host namespaces,
  dangerous mounts (`/`, `/etc`, `/proc`, `/dev`, `docker.sock`, ...), dangerous capabilities,
  disabled security profiles and `${VAR:-value}` bypasses are refused. Built-in templates deploy
  under a relaxed policy; user-edited files use the strict one.
- URLs fetched by the server (templates, webhooks, plugins) are checked against private and
  link-local ranges and redirects are not followed.
- Archives (backups, snapshots) are listed before extraction; absolute paths, `..` entries and
  symbolic links are refused.
- Background jobs started by a request are detached from the client socket, so a slow job can
  never hold a connection open or write into an HTTP response.

### Plugins and hooks

Plugin hooks are user-supplied scripts. They run with a minimal environment (never the server's
`.env`), a 30-second timeout and bounded output, only when the plugin's manifest says
`"enabled": true`, and never through symbolic links. Installing, writing and testing hooks requires
`admin`.

### Web terminal

The terminal runs commands as the API service account, so it can only be unlocked with that
account's (or root's) Linux password, in addition to an admin API session. Commands run with a
60-second limit, are written to an audit log and pass through a denylist for obviously destructive
patterns. The denylist is a guard rail, not a boundary: an admin with terminal access is trusted.

## Operator checklist

- Run the API as an unprivileged user in the `docker` group (`.scripts/install-service.sh` sets
  this up with a hardened systemd unit).
- Keep `API_BIND=0.0.0.0` only on a trusted network; put Traefik (`API_BEHIND_TLS_PROXY=true`) or
  the API's own TLS (`API_TLS_ENABLED=true`) in front of it for anything reachable from elsewhere.
- Restrict `API_IP_WHITELIST` to your LAN or VPN ranges.
- Give day-to-day users the `user` role; create admins sparingly.
- Back up `.secrets/.master-key` separately from the encrypted secrets.
- `.env`, `.api-auth/` and `.secrets/` are ignored by git and created with mode `600`/`700`; keep
  them that way.
