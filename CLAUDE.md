# CLAUDE.md

Guidance for Claude Code when working in this repository.

> ## 📖 Read the architecture docs first
> The overall Cloud Build / deploy / Terraform architecture lives in the
> **`build-docs`** repo, cloned as a sibling of this one:
> [`../build-docs/README.md`](../build-docs/README.md) — see especially
> [`../build-docs/ops-deployment.md`](../build-docs/ops-deployment.md) §2–§4 (how
> an app reaches a host) and
> [`../build-docs/ops-execution.md`](../build-docs/ops-execution.md) Part C (why
> VMs are push-only).
>
> **If that path does not exist, you have not cloned `build-docs` yet — stop and
> clone it first** (it sits next to this repo under `Build/`):
> ```bash
> git clone https://github.com/deployza/build-ops.git
> ```
> Without it you are missing the cross-repo context (how this repo fits the
> image / GCS-artifact / push flow).

## What this repo is

**How an application reaches a host: the scripts, and the thing that runs
them.** `vm/` and `docker/` are the scripts a host runs to install a Deployza
application onto itself; `ansible/` is the pusher that puts them there. **How they arrive differs by platform, and
that asymmetry is permanent** (see the `vm/` vs `docker/` box below):

- **VM** — the `vm/` folder is **PUSHED** to a running instance over SSH through
  the IAP tunnel, then run there. There is no launcher on a VM: `vm-startup.sh`
  was deleted on 2026-09-24.
- **Container** — `docker-startup.sh`, baked into the image, clones this repo at
  start and runs `docker/<APP_NAME>.sh`. It stays.

One script per app **per platform**:

```
build-ops/
├── vm/                    # organised by HOST — one folder per VM
│   ├── mcp/               # collects nothing: install-otel.sh + inert.yaml only
│   └── <vm>/              # ziniapps-vm/, deployza-vm/ — SELF-CONTAINED, nothing shared
│       ├── install.sh     #   UNITS, in order; run all or any: install.sh <env> [unit...]
│       ├── <app>.sh       #   one unit per app this host runs
│       ├── otel.yaml      #   this host's COMPLETE collector config
│       ├── install-otel.sh #  the `otel` unit: validate, swap, restart, verify, roll back
│       ├── inert.yaml     #   collect nothing — --inert
│       ├── units.sh       #   the runner install.sh sources
│       └── common.sh      #   constants, sourced as common.sh by every <app>.sh
├── docker/
│   ├── common.sh          # constants SOURCED by every docker/ script
│   └── <APP_NAME>.sh      # deploy into the PID-1 Tomcat of a container
└── ansible/               # THE PUSHER — runs on a CONTROLLER, never on a host
    ├── inventory/hosts.yml        key = GCE instance name = vm/<vm>/ folder
    ├── playbooks/<vm>.yml         one per VM, one role line (and tag) per unit
    └── roles/{vm_push,vm_unit}/
```

Either way the scripts land at `/tmp/deployza/repo`. A container runs
`docker/<APP_NAME>.sh <APP_ENV>`; a VM runs `vm/<vm>/install.sh <APP_ENV>
[unit ...]`, or a unit directly (`vm/<vm>/<app>.sh <APP_ENV>`,
`vm/<vm>/install-otel.sh`). `APP_ENV` (`development` / `production`) is the sole
argument wherever an app is being deployed.

## A VM is a folder of units

**Restructured 2026-09-25** from a layered tree (`vm/apps/`, `vm/systems/`,
`vm/instances/`, `vm/steps/`, `render.sh`). Everything a host runs now lives in
its own folder, and each piece of work is a **unit**:

| unit | script | what it does |
|---|---|---|
| `<app>` | `vm/<vm>/<app>.sh <APP_ENV>` | install one app |
| `otel` | `vm/<vm>/install-otel.sh [--inert] [--check]` | install `vm/<vm>/otel.yaml` |

`vm/<vm>/install.sh` holds the host's ordered `UNITS` (apps, then `otel`) and
runs all of them, `apps` (every unit but otel), or the units you name:

```bash
sudo bash vm/ziniapps-vm/install.sh production                 # every unit
sudo bash vm/ziniapps-vm/install.sh production assess-exam     # one
sudo bash vm/ziniapps-vm/install.sh production apps            # all apps
sudo bash vm/ziniapps-vm/install-otel.sh                       # otel only
bash vm/ziniapps-vm/install-otel.sh --check                    # validate, touch nothing
```

A unit named explicitly need not be in `UNITS`: that is how `hundi-ui` — present
on `ziniapps-vm`, never deployed — stays reachable on purpose.

**The order is load-bearing** and is written down in each `install.sh`: on
`ziniapps-vm` the per-PATH apps precede the per-HOST sites (whose server blocks
include `app.d/*.conf`), and `otel` goes last. **The playbook lists the same
units in the same order — change both together.**

> **Every unit runs two ways and is ONE implementation.** Ansible ships the
> folder and runs the script (`--tags assess-exam`); a person clones the repo on
> the box and runs the same script. No unit may exist only on the controller —
> the IAP tunnel is exactly the kind of thing that is down when you need it.

An app that ran on two hosts would have a copy of its script in each folder.
None does today.

## `otel.yaml` is the whole config — no assembly

Each `vm/<vm>/otel.yaml` holds **receivers, processors, exporters and service**
and is installed verbatim at `/etc/otelcol/config.yaml`. There are no fragments,
no placeholders and no render step.

- **A "service" is one pipeline, one `service.name`, one destination**: a
  `logs/<name>` pipeline under `service:` and a matching `resource/<name>`
  processor. Records carry exactly three resource attributes — `service.name`,
  `host.name`, `host.project`.
- **An app is collected only if it has its own receiver** (`filelog/<app>`),
  processor and pipeline. `filelog/tomcat` deliberately does not glob the per-app
  log dirs, so each line ships once.
- **The destination is Google Pub/Sub, authenticated by IAM** — the VM's
  attached service account is the publisher. No credentials in this repo.
- **`install-otel.sh` does the part that must be right on the box**: validate
  against the pinned `/opt/otelcol/bin/otelcol-contrib`; check `host.project`
  against the metadata server; add `otelcol` to `systemd-journal`/`adm`/`tomcat`
  where they exist (**before** the restart — groups are read at process start,
  and a missing one is the number one silent failure); back up, swap, **restart
  never reload**, wait `SETTLE_SECONDS` and confirm the unit stayed up; restore
  the backup if not.
- **The folder is the host.** `vm/<vm>/install-otel.sh` installs the
  `otel.yaml` beside it and refuses a real install where `hostname -s` is not
  the folder's host (`--check` works anywhere). The host is the folder name,
  unless an `instance` file in the folder names it (`vm/mcp-vm/` is host `mcp`;
  its inventory entry sets `vm_dir: mcp-vm` to match). `--inert` installs the
  folder's `inert.yaml` instead (the off switch).
- **Every host has a folder**, even one that collects nothing: `vm/mcp-vm/` holds
  only `install-otel.sh`, `inert.yaml` and `instance`, and installs `inert.yaml`
  because there is no `otel.yaml`. `vm_push` refuses a host with no folder.
- **There is no `docker/` counterpart, deliberately.** Containers log to stdout
  and the runtime collects it.

The image bakes only the collector binary, its unit and an inert `nop` config,
so a VM with nothing pushed to it collects nothing and sends nowhere.

> ## ⚠ `vm-startup.sh` IS GONE — `ansible/` replaces it
>
> **Done 2026-09-24** (ops-execution.md Part C): the boot-time launcher is
> deleted and VMs are push-only. `docker-startup.sh` stays, so the `vm/` ↔
> `docker/` symmetry is **permanently broken by design** — do not restore the
> VM launcher for consistency.
>
> **It has never been run against a real VM.** Nothing here is exercised or
> CI'd, `deployza-vm` and `devops-vm` do not exist in Terraform yet, and the
> `roles/iap.tunnelResourceAccessor` gap in `config-iam/` blocks the tunnel to
> `dz-ziniapps` until it is fixed.
>
> **Deploying by hand, meanwhile:** clone this repo on the instance and run
> `sudo bash vm/<vm>/install.sh <APP_ENV> [unit ...]`. Copying a loose script
> breaks at the `source` line — `common.sh` must sit beside it — so
> bring the folder, not the file.

## `ansible/` is not a third platform

It sits beside `vm/` and `docker/` but is **controller-side**: nothing in it is
ever copied to a host. See [`ansible/README.md`](ansible/README.md).

- **It drives `vm/` only.** There is no `ansible/docker/` and there must not be.
- **It carries and starts; the scripts decide.** `vm_push` (tagged `always`)
  ships `vm/<vm>/` plus the four shared `vm/` files; `vm_unit` runs one unit.
- **Every unit is a tag**: no tags runs them all in order, `--tags assess-exam`
  one, `--tags apps` every app, `--tags otel` the collector. Units that ship but
  must be asked for by name are tagged `never` (`hundi-ui`).
- **The "no secrets — ever" rule extends here.** No vault files. Secrets come
  from Secret Manager at run time; Pub/Sub needs none at all.

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
**`www-website`** (per-host). `ziniapps-vm` runs the three assess apps and both
ziniapps sites (plus `hundi-ui`, present but never deployed); `deployza-vm` runs
`www-website` + `www-apidocs`, the two halves of the www.deployza.com host.

## The deploy contract

- **`install.properties` (in the GCS `conf/` folder) is the single source of
  truth.** The script derives **nothing** on its own — every value (WAR filename,
  `CATALINA_HOME`, context path, app-properties/logback filenames, DB
  name/user/password, MySQL root creds) is read from it. Key list is documented in
  the header comment of each script and in `build-docs/ops-deployment.md` §1.
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

| | `vm/<vm>/<app>.sh` | `docker/<app>.sh` |
| --- | --- | --- |
| Tomcat identity | `tomcat` **systemd** service, runs as the `tomcat` user | **PID 1** (root); no `tomcat` user exists |
| File ownership | `install -o tomcat -g tomcat`, `chown tomcat:tomcat` | **no** `chown` (would fail "invalid user: tomcat" and, under `set -e`, abort the deploy / kill the container) |
| Deploy style | **hot-deploy** into a live Tomcat: undeploy old context, wait for the exploded dir to vanish, drop new WAR under a temp name then `mv` (watcher never sees a partial WAR) | **plain drop**: Tomcat isn't running yet — remove old, copy new, return; the entrypoint then `exec`s `catalina.sh run` |
| Log target | app logs to files under `/home/tomcat/instance/logs/<app>/` (per its logback) | app logs to **stdout** — `<ctx>.xml` must not point logback at a file dir |

## `common.sh` — one per platform folder

Every `vm/<vm>/` folder and `docker/` has **its own** `common.sh`, sitting
beside the scripts that source it from their own directory:

```bash
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
```

It holds the values identical for **every app on that platform** and owned by
the infrastructure, so changing one is a single edit per folder rather than one
per app:

| | `vm/<vm>/common.sh` | `docker/common.sh` |
| --- | --- | --- |
| Artifact bucket | `GCS_BASE_URL` | `GCS_BASE_URL` |
| Staging parent | `STAGE_ROOT` | `STAGE_ROOT` |
| nginx seams | `NGINX_APP_D`, `NGINX_SITE_D`, `NGINX_CONF_MAIN`, `INCLUDE_MARKER`, `NGINX_SERVICE`, `NGINX_USER`, `NGINX_GROUP` | **none** — Tomcat is PID 1 and serves directly; there is no nginx in an app container |

**One copy per folder is the deliberate choice**, keeping each VM folder and
`docker/` self-contained for the same reason `vm/<vm>/<app>.sh` and
`docker/<app>.sh` are separate copies (next section). **The price:
`GCS_BASE_URL` and `STAGE_ROOT` appear in every copy — change the bucket in
EVERY `vm/<vm>/common.sh` AND `docker/common.sh`, or hosts pull from different
places.** Do not "fix" this by having one folder source another's copy. The
same goes for `units.sh` and `install-otel.sh`: identical per-folder copies, so
a fix to one is a fix to all.

**What must NOT move into either file:** anything per-app — `APP_NAME`, the
context path, `DEFAULT_WEB_ROOT` (`/var/www/app` for per-PATH apps,
`/var/www/site` for per-HOST sites). Nor may `docker/common.sh` ever name the
`tomcat` user or group: it does not exist in those images.

Both files are sourced, never executed — no shebang, no `set -e`, never a unit.
Their values are `readonly`, which is safe because each unit is its own `bash`
process (`vm/<vm>/units.sh` runs each via `bash <script>`), so each is sourced exactly
once per process. `install.sh` sources neither.

**This depends on `common.sh` reaching the host with the VM folder.** A push
that copied a single script would break at the `source` line — `vm_push` ships
the whole folder, not the file.

## Conventions

- `#!/bin/bash` + `set -euo pipefail` at the top of every script.
- **The script returns when the deploy is done** — it is a deploy step, not a
  long-running process. On a VM it returns to whoever pushed it; the real server
  (Tomcat) is a separate systemd unit. In a container it returns and the
  entrypoint execs Tomcat.
- **Idempotent**: clear the staging dir, re-download, undeploy the old context,
  deploy the new one — safe to re-run (a redeploy is "push to GCS, re-run the
  script"). Never append/duplicate.
- **Staging dir** is `${STAGE_ROOT}/<APP_NAME>/` (`/tmp/deployza/<APP_NAME>/`) — this app's sibling of the
  scripts themselves (`/tmp/deployza/repo`), owned by this script. Same path
  whether pushed or run standalone over SSH.
- Read `install.properties` via the `read_prop` / `require_prop` helpers (last
  matching line wins; surrounding quotes stripped). Use `require_prop` for keys
  that must be non-empty; only `install.mysql.root.password` may be empty.
- **No secrets in this repo — ever.** Every sensitive value comes from the GCS
  `conf/install.properties` at deploy time. This repo is safe to keep public.

## When adding a new app

1. Add `vm/<vm>/<app>.sh` (in every VM folder that should run it) **and**
   `docker/<app>.sh`, then add the app to `UNITS` in that `vm/<vm>/install.sh`
   **and** a `vm_unit` line (tags `[apps, <app>]`) in the same position in
   `ansible/playbooks/<vm>.yml`. Pick the template by model (see
   "Two kinds of app" above): `assess-server` for a per-PATH app backed by
   Tomcat, `assess-ui` for a per-PATH static bundle, `ziniapps-www` for a
   per-HOST static site. Keep the vm/docker differences above.
2. Fix `APP_NAME` in each to the new name (it is hardcoded — the script *is* that
   app's installer; the unit is resolved by filename). Keep the `source` line
   (`common.sh`, beside the script, on both platforms) — do not re-declare `GCS_BASE_URL`,
   `STAGE_ROOT` or the `NGINX_*` constants locally.
3. Ensure the app's `conf/` (incl. `install.properties`) + WAR are published to
   `gs://dz-builds/<env>/<app>/`.
4. If it should be collected as its own service, add its `filelog/<app>`
   receiver, `resource/<app>` processor and `logs/<app>` pipeline to
   `vm/<vm>/otel.yaml`.
5. Deploy it: on a VM, `ansible-playbook playbooks/<vm>.yml --tags <app>`, or on
   the box `sudo bash vm/<vm>/install.sh <env> <app>`; for a container, start it
   with env `APP_NAME=<app>` `APP_ENV=<env>`.

## Gotchas

- `APP_NAME` is **fixed** inside each script, not taken from the caller — the
  script is resolved *by* its filename, so the name is already implied. Only
  `APP_ENV` is a runtime argument, and it is **required** (no default — a missing
  value aborts rather than deploying to the wrong environment).
- Requires `gsutil` and (for the MySQL step) a reachable `mysql` on the host —
  both are present on the baked `tomcat` / `tomcat-mysql` images, so these scripts
  assume the matching image flavor. There is no local test harness in this repo.
- These files are line-ending sensitive (they run under `bash` on Linux) — keep
  them LF, not CRLF.
