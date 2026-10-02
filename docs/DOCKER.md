# Running kirocc with Docker Compose

kirocc reads credentials from the Kiro CLI SQLite database on your host. The container needs that file bind-mounted read-write (kirocc refreshes tokens and writes them back), so most of the setup here is about pointing the mount at the right host path and running as a user that can write to it.

## Prerequisites

- Docker with Compose v2 (`docker compose`, not `docker-compose`)
- [Kiro CLI](https://kiro.dev) installed and **logged in on the host** — the container cannot run the login flow

## Quick start

```bash
docker compose up -d --build
curl http://127.0.0.1:3456/health
# {"status":"ok"}
```

Then point Claude Code at it:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
export ANTHROPIC_AUTH_TOKEN=dummy
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
claude
```

## The `.env` file

Compose reads `.env` from the same directory as `docker-compose.yml`. This is where you override the two host-specific values.

```bash
# .env

# Host directory holding kiro-cli's data.sqlite3.

KIROCC_DATA_DIR=${HOME}/.local/share/kiro-cli # Linux
KIROCC_DATA_DIR=${HOME}/Library/Application Support/kiro-cli # macOS
KIROCC_DATA_DIR=/mnt/c/Users/you/AppData/Local/Kiro-Cli # WSL2

# Your host user, so the mounted DB stays writable.
UID=1000
GID=1000

# Optional: require an API key on the proxy.
KIROCC_API_KEY=
```

### Host DB path per OS

| OS    | Path                                             |
| ----- | ------------------------------------------------ |
| macOS | `~/Library/Application Support/kiro-cli`         |
| Linux | `~/.local/share/kiro-cli`                        |

`docker-compose.yml` defaults to the macOS path:

```yaml
- "${KIROCC_DATA_DIR:-${HOME}/Library/Application Support/kiro-cli}:/data"
```

Compose has no way to branch on the host OS, so Linux users set `KIROCC_DATA_DIR` in `.env` and the default is ignored. Verify what Compose actually resolved before starting:

```bash
docker compose config | grep source:
```

### UID / GID

`UID` and `GID` are shell variables, not exported environment variables — `printenv UID` returns nothing, so Compose falls back to `1000:1000`. On macOS this is harmless (Docker Desktop and OrbStack translate ownership on bind mounts). On Linux, a mismatch means kirocc cannot write refreshed tokens back to the DB, and you get auth failures once the current access token expires.

Get your real values and put them in `.env`:

```bash
echo "UID=$(id -u)" >> .env
echo "GID=$(id -g)" >> .env
```

## Passing kirocc flags

The image's `ENTRYPOINT` is the `kirocc` binary, so anything in `command:` becomes its arguments. `-host 0.0.0.0` is required — kirocc binds `127.0.0.1` by default, which inside a container means "unreachable from the host".

```yaml
command: ["-host", "0.0.0.0"]
```

Add flags as separate array elements. Flag and value are two elements:

```yaml
command: ["-host", "0.0.0.0", "-debug", "-otel-body-limit", "65536"]
```

Boolean flags are one element on their own (`-debug`), or use the explicit form (`-debug=true`). Do **not** write `["-host 0.0.0.0"]` — that is a single argument containing a space and the flag parser will reject it.

Common combinations:

```yaml
# Verbose logging while debugging
command: ["-host", "0.0.0.0", "-debug"]

# Log to a rotated file under the mounted volume
command: ["-host", "0.0.0.0", "-log-file", "/data/kirocc.log", "-log-max-size", "20", "-log-compress"]

# Non-default port (remember to change the ports mapping too)
command: ["-host", "0.0.0.0", "-port", "8080"]
```

Every flag from the [README options table](../README.md#command-line-options) works here. Do not pass `-db` — the compose file sets `KIROCC_DB_PATH=/data/data.sqlite3`, which is the in-container path of the mount.

### Flags vs environment variables

Environment variables are applied *after* flag parsing, so `KIROCC_*` wins over the matching flag. Both are available; pick one style per setting rather than setting the same thing twice.

```yaml
# Equivalent to command: ["-host", "0.0.0.0", "-debug"]
environment:
  KIROCC_DB_PATH: /data/data.sqlite3
  KIROCC_HOST: 0.0.0.0
  KIROCC_DEBUG: "true"
```

Environment variables suit values you want to vary per deployment through `.env`; `command:` flags suit settings that belong to this compose file. The variable/flag mapping is in the [README](../README.md#environment-variables).

`KIROCC_MODEL_MAPPINGS` is environment-only — there is no equivalent flag:

```yaml
environment:
  KIROCC_MODEL_MAPPINGS: '[{"anthropic":"my-model","kiro":"claude-sonnet-4.5","context_window_size":200000}]'
```

## Exposing the port

`ports: - "3456:3456"` publishes on all host interfaces. Combined with `-host 0.0.0.0`, anyone who can reach your machine can use your Kiro credits. kirocc logs a warning when it binds a non-loopback address without an API key.

Bind to loopback only:

```yaml
ports:
  - "127.0.0.1:3456:3456"
```

Or, if the port must be reachable from other machines, set an API key:

```yaml
environment:
  KIROCC_API_KEY: ${KIROCC_API_KEY:?set KIROCC_API_KEY in .env}
```

Clients then send it as `Authorization: Bearer <key>`. For Claude Code, set `ANTHROPIC_AUTH_TOKEN` to the same value instead of `dummy`. `/health` stays unauthenticated so health checks keep working.

## Everyday commands

```bash
docker compose up -d --build     # start (rebuild if Dockerfile/source changed)
docker compose logs -f           # follow logs
docker compose ps                # status
docker compose restart           # restart after editing .env values
docker compose down              # stop and remove the container
docker compose config            # show the fully resolved config — check paths and user here
```

Editing `command:` or `environment:` in `docker-compose.yml` requires `docker compose up -d` again (not just `restart`) for Compose to recreate the container with the new settings.

## Build cache

The Dockerfile uses BuildKit cache mounts for Go modules and the build cache:

```dockerfile
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
```

These live in BuildKit's own storage, not in the image and not in any host directory you mount. They persist across builds but are tied to the builder — switching builders starts from empty. Inspect and reclaim:

```bash
docker buildx du          # how much the cache is holding
docker buildx prune       # drop it
```

## Troubleshooting

**`connection refused` from the host** — kirocc is bound to `127.0.0.1` inside the container. Check that `command:` includes `-host 0.0.0.0`.

**Auth errors after working for a while** — the token expired and kirocc could not write the refreshed one back. This is a permissions problem on the mounted DB: confirm `UID`/`GID` in `.env` match `id -u` / `id -g`, then `docker compose up -d` to recreate.

**`no such file or directory` for the DB** — the host path is wrong. Run `docker compose config | grep source:` and compare against the OS table above. Also confirm you have logged in with Kiro CLI on the host; the DB does not exist until then.

**Changes to `.env` seem ignored** — Compose reads `.env` from the directory you run the command in, not from where the compose file lives. Run from the project root, or pass `--env-file`.
