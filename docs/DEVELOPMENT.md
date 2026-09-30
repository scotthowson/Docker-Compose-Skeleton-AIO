<sub>[← Troubleshooting](TROUBLESHOOTING.md) · [Docs index](README.md) · Next: [Proxmox and the fleet →](PROXMOX.md)</sub>

# Development

How the code is laid out, how to test it, and how to run the API while you work on it.

## Two repositories

| Repository | What it holds |
|---|---|
| [dcs-orchestrator](https://github.com/scotthowson/dcs-orchestrator) (this one) | The Bash framework, the API, the stacks, the templates, the plugins, the VM images and these docs |
| [dcs-orchestrator-ui](https://github.com/scotthowson/dcs-orchestrator-ui) | The dashboard: a React app built with Vite, published as the `ghcr.io/scotthowson/docker-compose-skeleton-ui` image and as Android, Linux and Windows apps |

Everything here is Bash 4+, Docker Compose v2 and `jq`. There is no build step.

## Repository layout

| Path | Role |
|---|---|
| `setup.sh`, `start.sh`, `stop.sh`, `restart.sh`, `status.sh`, `compose.sh` | The entry points |
| `.config/settings.cfg` | The default of every setting |
| `.lib/` | Libraries the scripts source: logging, Docker helpers, secrets, metrics, the scheduler, health scores, plugins, rollback, setup checks |
| `.scripts/api-server.sh` | The REST API: the router `handle_request` and the `handle_*` handlers |
| `.scripts/api-docs.sh` | Generates `docs/API.md` and the `GET /` catalogue from the router |
| `.scripts/fleet-bootstrap.sh` | What the hub runs inside a new VM: Docker, the hub's code, the member setup, the join |
| `.scripts/*.sh` (others) | Tools with `--help`: install-service, stack-manager, health-check, maintenance… |
| `Stacks/<category>/` | The ten stacks, each a `docker-compose.yml` and a `.env` |
| `.templates/<name>/` | The templates: `docker-compose.yml`, `template.json`, optional `config/` |
| `.plugins/`, `.plugins-catalog/` | The bundled plugins and the catalogue ([plugin guide](../.plugins/README.md)) |
| `vm-images/` | The purpose-built VM images *(new in 4.0)* |
| `tests/` | `lint.sh`, `smoke.sh`, an opt-in CrowdSec replay test, and stand-ins for Proxmox and Cloudflare |
| `docs/` | These pages; `docs/API.md` is generated, `docs/tools/` holds the generators |

The API writes its state to `.api-auth/`, `.data/`, `.secrets/` and `logs/`; git ignores them.

## How the API works

- **One process per request.** `socat` (or `ncat`) listens and starts `api-server.sh --handle-request`
  for every connection; the handler reads the request on stdin and writes the answer to stdout. The
  listener is supervised, so SIGTERM stops it cleanly.
- **Roles in one place.** `_api_route_allowed METHOD PATH` decides who may call what. New routes that
  change something or expose a secret are admin-only there; handlers check again.
- **`.env` is data.** It is parsed as `KEY=value` lines and never sourced by the API. Writes go through
  the validators.
- **JSON with jq.** Build JSON and filters with `--arg` and `--argjson`, never by pasting user data into
  a filter. Update JSON files atomically with `_api_jq_update_file`.
- **Background work is detached** (`( … ) </dev/null >/dev/null 2>&1 &`), so it can never hold the
  client's connection open.

`CLAUDE.md` in the repository root has the full list of conventions.

## Tests

```bash
tests/lint.sh                  # bash -n, shellcheck, compose validation, API reference freshness
tests/smoke.sh                 # the API's request handler in a temporary install
tests/crowdsec-media-apps.sh   # opt-in: CROWDSEC_MEDIA_APPS replayed through the real CrowdSec (needs Docker, the image, the network)
.scripts/api-docs.sh --check   # docs/API.md and the GET / catalogue are current
docs/tools/gen-templates.sh --check   # docs/TEMPLATES.md is current
./setup.sh --dry-run           # setup, without changing anything
```

- **`tests/lint.sh`** runs `bash -n` and ShellCheck (`-S warning`) on every script, validates the
  compose file of every stack and template with its own defaults, checks the JSON files and the API
  reference. ShellCheck 0.10 or newer is best: the linter then skips the extended analysis that needs a
  lot of memory on the API script. Compose validation is skipped without Docker.
- **`tests/smoke.sh`** drives the request handler over stdin, the way `socat` does, in an isolated copy
  in a temporary folder: no listener, no network. It runs over 1,100 checks, including a whole VM build
  against the Proxmox stand-in (`tests/mock-proxmox.py`) and DNS against the Cloudflare one
  (`tests/mock-cloudflare.py`). The checks that need Docker are skipped without it.

CI (`.github/workflows/ci.yml`) runs the linter, the smoke suite and the setup dry run on every push to
`main` and `release/**` and on every pull request. Keep both suites green.

## Run the API while you work

**One request, no listener.** The quickest way to try a handler:

```bash
cp .env.example .env
printf 'GET /ping HTTP/1.1\r\nHost: dev\r\n\r\n' | .scripts/api-server.sh --handle-request
```

**A listener on loopback.** Use a clone of your own (never the install that runs your stacks) and
start it with its full path, which `--stop` uses to recognise its own server:

```bash
"$PWD/.scripts/api-server.sh" --bind 127.0.0.1 --port 9877
```

```bash
curl -s http://127.0.0.1:9877/ping      # {"ok": true, "version": …}
curl -s http://127.0.0.1:9877/status    # 401: create the first admin with POST /auth/setup
.scripts/api-server.sh --stop
```

On a loopback address you may set `API_AUTH_ENABLED=false` in the clone's `.env` to skip accounts
while testing; on any other address the API refuses to run without them.

**A stand-in Proxmox.** `tests/mock-proxmox.py` answers like a Proxmox node with a few guests:

```bash
python3 tests/mock-proxmox.py 18006 'dcs@pve!dev' 00000000-0000-0000-0000-000000000000
```

Then link it with `PROXMOX_URL=http://127.0.0.1:18006`, `PROXMOX_TOKEN_ID=dcs@pve!dev` and that secret.

**The dashboard from source.** In a clone of the UI repository:

```bash
npm ci
npx vite --port 3014 --strictPort
```

Open `http://localhost:3014`. The dev server forwards `/api` to `http://127.0.0.1:9876`, the default API
port; for an API elsewhere, type its address into the server field of the sign-in or setup screen.

## Adding an API route

1. Write the handler with a comment on the line above it: `# METHOD /path — what it does`.
2. Add the route to the router and validate every path parameter with the `_api_validate_*` helpers.
3. Decide who may call it in `_api_route_allowed`.
4. Run `.scripts/api-docs.sh` to regenerate `docs/API.md` and the `GET /` catalogue.
5. Add smoke checks and run both suites.

## Adding a template

1. Make `.templates/<name>/` with a `docker-compose.yml` and a `template.json`
   ([field reference](TEMPLATES.md#templatejson-reference)), and a `config/` folder if the app needs files
   before its first start.
2. Use `${APP_DATA_DIR:-./App-Data}/<Name>/…` for bind mounts, `${PUID}`, `${PGID}` and `${TZ}`, and a
   `healthcheck` where the image can run one.
3. Deploy it for real and watch it become healthy. Write in the description what to do after the first start.
4. Run `tests/lint.sh` and `docs/tools/gen-templates.sh`.

## VM images

*New in 4.0.* `vm-images/` builds the node and hub images without root: the root file system is built
in Docker, then assembled into a disk that boots with BIOS and UEFI.

```bash
vm-images/build.sh debian-13 node          # out/dcs-node-debian-13.qcow2
vm-images/build.sh debian-13 hub --test    # build, then boot it in QEMU and check it
```

Options: `--ref GIT_REF` (the DCS code a hub image carries, default `HEAD`), `--size MB` (disk size,
default 4096), `--firmware bios|uefi|both`. `--test` needs `qemu-system-x86_64`, `qemu-img`, `ssh` and
`genisoimage`, and OVMF for UEFI. `vm-images/tests/measure.sh USER@HOST` prints the same figures for a VM
on a real Proxmox node. The images are described in [VM images](VM-IMAGES.md).

To look around in a hub without Proxmox, boot the image in QEMU and keep it running; the script prints
the local ports of the dashboard, the API and ssh:

```bash
vm-images/tests/boot-test.sh vm-images/out/dcs-hub-debian-13.qcow2 --role hub --hold
```

## Releases

- `VERSION` holds the release version; `.config/settings.cfg` and the API read it.
- The API's protocol version is `API_VERSION` in `.scripts/api-server.sh`.
- `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); new work goes under
  *Unreleased*.
- The Updates page's `stable` channel follows the `vX.Y.Z` tags.
