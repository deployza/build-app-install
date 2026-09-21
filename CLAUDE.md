# CLAUDE.md

Guidance for Claude Code when working in this repository.

> ## 📖 Read the architecture docs first
> The overall Cloud Build / deploy / Terraform architecture lives in the
> **`build-docs`** repo, cloned as a sibling of this one:
> [`../build-docs/README.md`](../build-docs/README.md) — see especially
> [`../build-docs/build-design.md`](../build-docs/build-design.md) §5–§7 (the
> boot-time app-install flow).
>
> **If that path does not exist, you have not cloned `build-docs` yet — stop and
> clone it first** (it sits next to this repo under `Build/`):
> ```bash
> git clone https://github.com/deployza/build-app-install.git
> ```
> Without it you are missing the cross-repo context (how this repo fits the
> image / GCS-artifact / boot-launcher flow).

## What this repo is

**Per-app boot-time deploy scripts.** These are the scripts a host runs to
install a Deployza application onto itself — cloned at boot/start by the launcher
**baked into the images** (`vm-startup.sh` on a VM, `docker-startup.sh` in a
container; both live in the image repos, not here).

One script per app **per platform**:

```
build-app-install/
├── vm/
│   ├── common.sh          # constants SOURCED by every vm/ script
│   └── <APP_NAME>.sh      # deploy into a native systemd Tomcat on a VM
├── otel/                  # NOT an app — operational config, PUSHED on demand
└── docker/
    ├── common.sh          # constants SOURCED by every docker/ script
    └── <APP_NAME>.sh      # deploy into the PID-1 Tomcat of a container
```

The launcher clones this repo to `/tmp/deployza/repo`, then runs
`<clone>/<platform>/<APP_NAME>.sh <APP_ENV>`. `APP_NAME` selects the script (its
basename); `APP_ENV` (`development` / `production`) is the sole argument.

Each script: downloads the app's `conf/` folder + WAR from **GCS**
(`gs://dz-builds/<APP_ENV>/<APP_NAME>/`), reads `install.properties`,
provisions the MySQL DB/user, installs the per-webapp Tomcat context
(`<ctx>.xml` + properties + logback) into `$CATALINA_HOME/conf/Catalina/localhost`,
and deploys the WAR under the stable name `<ctx>.war` (serving at `/<ctx>`).

## `otel/` is not an app — read this before treating it like one

[`otel/`](otel/) breaks the "one script per app per platform" shape above, on
purpose. It holds OpenTelemetry Collector configuration, and it differs from
`vm/` and `docker/` in three ways that matter:

- **It is pushed, not pulled.** No launcher runs it. `otel/push.sh` runs on your
  laptop, renders a config for the target's image flavor, ships it over the IAP
  tunnel and runs `otel/apply.sh` there. Nothing at boot touches it.
- **It is not selected by `APP_NAME`.** The pusher names the target instance
  directly; the flavor comes from the VM's own `/etc/image-manifest.txt`.
- **There is no `docker/` counterpart, deliberately.** Containers log to stdout
  and the runtime collects it. Do not add one for symmetry.

The image bakes only the collector binary, its unit and an inert `nop` config,
so a VM with nothing pushed to it collects nothing and sends nowhere. See
[`otel/README.md`](otel/README.md) and
[`../build-docs/ops-execution.md`](../build-docs/ops-execution.md).

> **Heads-up on direction.** `otel/` is the first piece of a wider move to
> push-only: `vm-startup.sh`, the boot-time launcher that clones this repo and
> runs `vm/<APP_NAME>.sh`, is slated for retirement in favour of pushing app
> deploys the same way (ops-execution.md Part C). It has **not** happened yet —
> the boot flow described below is still live and still correct. When it does,
> `docker-startup.sh` stays, so the `vm/` ↔ `docker/` symmetry below breaks
> permanently.

## Two kinds of app: per-PATH and per-HOST

Not every script follows the shape above. There are two deploy models, and which
one an app uses determines **which nginx seam it writes into**. Getting this
wrong is a syntax error at `nginx -t`, not a subtle bug.

| | **per-PATH app** | **per-HOST site** |
| --- | --- | --- |
| Serves | `/<ctx>/` on every hostname | `/` on ONE hostname |
| Examples | `assess-server`, `assess-ui`, `assess-exam` | `ziniapps-go`, `ziniapps-www` |
| Writes | `/etc/nginx/app.d/<ctx>.conf` | `/etc/nginx/site.d/<site>.conf` |
| File holds | bare `location` blocks **only** | a complete `server { … }` block |
| Included from | inside the image's `_` default server | the `http{}` block of `nginx.conf` |
| Dir created by | the image (`install-nginx.sh`) | the deploy script itself |
| Extra key | — | `install.server.name` (the hostname) |

**Why two models.** A domain root cannot be a path drop-in: two sites would each
need `location /` in the one shared server block, which conflicts. Serving a root
per hostname requires a real `server` block, and a `server` block may only appear
at the `http{}` level — so the per-HOST scripts create `/etc/nginx/site.d/` and
add an include for it to `nginx.conf` (idempotently, guarded by a
`# DEPLOYZA-SITE-D` marker). `conf.d/` is deliberately not reused for this: it is
the image's namespace.

**Consequence to remember.** Once a hostname has a `server_name` block, it no
longer falls through to the `_` default server — so the `app.d` per-path apps stop
resolving on that host unless the block includes them. `ziniapps-go.sh` therefore
does `include /etc/nginx/app.d/*.conf;` (its landing page links to the product
with relative URLs); `www-website.sh` likewise, so that `www-apidocs`' drop-in
resolves at `www.deployza.com/api-docs/`; `ziniapps-www.sh` deliberately does
**not**, so that product keeps exactly one origin.

Apps today: **`assess-server`**, **`assess-ui`**, **`assess-exam`**,
**`www-apidocs`** (per-path), **`ziniapps-go`**, **`ziniapps-www`**,
**`www-website`** (per-host), plus two orchestrators — **`assess-install`**
(the five assess/ziniapps apps) and **`www-install`** (`www-website` +
`www-apidocs`, the two halves of the www.deployza.com host).

## The deploy contract

- **`install.properties` (in the GCS `conf/` folder) is the single source of
  truth.** The script derives **nothing** on its own — every value (WAR filename,
  `CATALINA_HOME`, context path, app-properties/logback filenames, DB
  name/user/password, MySQL root creds) is read from it. Key list is documented in
  the header comment of each script and in `build-docs/build-design.md` §2.
- Conf files are installed **verbatim** — absolute paths inside `<ctx>.xml` must
  already match `install.catalina.home`.
- The WAR is staged under its real versioned filename but **deployed as
  `<ctx>.war`**, so the context path is stable across versions.
- An empty `install.mysql.root.password` means "authenticate over the
  passwordless local socket" (the baked `mysql`/`tomcat-mysql` image installs
  MySQL with no root password) — the `-p` flag is then omitted.

## vm/ vs. docker/ — deliberately separate, not one script behind a flag

Keep the two as explicit copies. They share the same shape but differ where the
runtimes differ; do **not** merge them behind a platform flag.

| | `vm/<app>.sh` | `docker/<app>.sh` |
| --- | --- | --- |
| Tomcat identity | `tomcat` **systemd** service, runs as the `tomcat` user | **PID 1** (root); no `tomcat` user exists |
| File ownership | `install -o tomcat -g tomcat`, `chown tomcat:tomcat` | **no** `chown` (would fail "invalid user: tomcat" and, under `set -e`, abort the deploy / kill the container) |
| Deploy style | **hot-deploy** into a live Tomcat: undeploy old context, wait for the exploded dir to vanish, drop new WAR under a temp name then `mv` (watcher never sees a partial WAR) | **plain drop**: Tomcat isn't running yet — remove old, copy new, return; the entrypoint then `exec`s `catalina.sh run` |
| Log target | app logs to files under `/home/tomcat/instance/logs/<app>/` (per its logback) | app logs to **stdout** — `<ctx>.xml` must not point logback at a file dir |

## `common.sh` — one per platform folder

Each of `vm/` and `docker/` has **its own** `common.sh`, sourced by every deploy
script in that folder from its own directory:

```bash
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
```

It holds the values identical for **every app on that platform** and owned by
the infrastructure, so changing one is a single edit per folder rather than one
per app:

| | `vm/common.sh` | `docker/common.sh` |
| --- | --- | --- |
| Artifact bucket | `GCS_BASE_URL` | `GCS_BASE_URL` |
| Staging parent | `STAGE_ROOT` | `STAGE_ROOT` |
| nginx seams | `NGINX_APP_D`, `NGINX_SITE_D`, `NGINX_CONF_MAIN`, `INCLUDE_MARKER`, `NGINX_SERVICE`, `NGINX_USER`, `NGINX_GROUP` | **none** — Tomcat is PID 1 and serves directly; there is no nginx in an app container |

**Two copies is the deliberate choice**, keeping each platform folder
self-contained for the same reason `vm/<app>.sh` and `docker/<app>.sh` are
separate copies (next section). **The price: `GCS_BASE_URL` and `STAGE_ROOT`
appear in both files — change the bucket in BOTH, or the two platforms pull
from different places.** Do not "fix" this by having one folder source the
other's copy.

**What must NOT move into either file:** anything per-app — `APP_NAME`, the
context path, `DEFAULT_WEB_ROOT` (`/var/www/app` for per-PATH apps,
`/var/www/site` for per-HOST sites). Nor may `docker/common.sh` ever name the
`tomcat` user or group: it does not exist in those images.

Both files are sourced, never executed — no shebang, no `set -e`, not in
`CHILD_SCRIPTS`. Their values are `readonly`, which is safe because each deploy
script is its own `bash` process (the orchestrator runs children via
`bash <child>`), so each is sourced exactly once per process.
`assess-install.sh` sources neither — it deploys nothing, it only invokes the
children.

**This depends on the launcher cloning the whole repo** (it does — to
`/tmp/deployza/repo`). A launcher that copied a single script to a host would
break at the `source` line.

## Conventions

- `#!/bin/bash` + `set -euo pipefail` at the top of every script.
- **The script returns when the deploy is done** — it is a deploy step, not a
  long-running process. On a VM it runs under `vm-startup.service` (`Type=oneshot`,
  goes `active (exited)`); the real server (Tomcat) is a separate unit. In a
  container it returns and the entrypoint execs Tomcat.
- **Idempotent**: clear the staging dir, re-download, undeploy the old context,
  deploy the new one — safe to re-run (a redeploy is "push to GCS, re-run
  startup"). Never append/duplicate.
- **Staging dir** is `${STAGE_ROOT}/<APP_NAME>/` (`/tmp/deployza/<APP_NAME>/`) — this app's sibling of the
  clone (`/tmp/deployza/repo`), owned by this script. Same path whether launched
  at boot or run standalone over SSH.
- Read `install.properties` via the `read_prop` / `require_prop` helpers (last
  matching line wins; surrounding quotes stripped). Use `require_prop` for keys
  that must be non-empty; only `install.mysql.root.password` may be empty.
- **No secrets in this repo — ever.** Every sensitive value comes from the GCS
  `conf/install.properties` at deploy time. This repo is safe to keep public.

## When adding a new app

1. Add `vm/<app>.sh` **and** `docker/<app>.sh`. Pick the template by model (see
   "Two kinds of app" above): `assess-server` for a per-PATH app backed by
   Tomcat, `assess-ui` for a per-PATH static bundle, `ziniapps-www` for a
   per-HOST static site. Keep the vm/docker differences above.
2. Fix `APP_NAME` in each to the new name (it is hardcoded — the script *is* that
   app's installer; the launcher resolves it by filename). Keep the
   `source "${SCRIPT_DIR}/common.sh"` line — do not re-declare `GCS_BASE_URL`,
   `STAGE_ROOT` or the `NGINX_*` constants locally.
3. Ensure the app's `conf/` (incl. `install.properties`) + WAR are published to
   `gs://dz-builds/<env>/<app>/`.
4. Launch a host with metadata/env `APP_NAME=<app>` `APP_ENV=<env>`.

## Gotchas

- `APP_NAME` is **fixed** inside each script, not taken from the launcher — the
  script is resolved *by* its filename, so the name is already implied. Only
  `APP_ENV` is a runtime argument, and it is **required** (no default — a missing
  value aborts rather than deploying to the wrong environment).
- Requires `gsutil` and (for the MySQL step) a reachable `mysql` on the host —
  both are present on the baked `tomcat` / `tomcat-mysql` images, so these scripts
  assume the matching image flavor. There is no local test harness in this repo.
- These files are line-ending sensitive (they run under `bash` on Linux) — keep
  them LF, not CRLF.
