# vm/otel/ — OpenTelemetry Collector tooling

**This folder holds no per-app deploy scripts and no config content.** It is the
two scripts that render, ship and apply a collector config, and it lives inside
`vm/` because Otel on a VM is a VM concern: there is no `docker/` counterpart at
all. Nothing at boot ever touches it — a config arrives only when pushed.

Full design and the reasoning behind every choice here:
[`../../../build-docs/ops-execution.md`](../../../build-docs/ops-execution.md).

## The one rule

> Everything that lands on a running VM is **pushed** to it over SSH.
> Nothing on the VM pulls, clones or polls.

The image bakes only the mechanism — the collector binary, `otelcol.service`,
and an inert `nop` config (`build-vm-images/scripts/ubuntu/install-otel.sh`).
A freshly created VM therefore has a collector that is running, healthy, and
**collecting nothing and sending nowhere** until something here is pushed to it.

## Layout

**This folder holds only the tooling.** The content lives in the `vm/` tree,
which is organised by layer:

```
vm/otel/
├── push.sh              PUSHER-side: render + ship + apply. Runs on your laptop.
└── apply.sh             TARGET-side: swap, restart, health check, roll back.

../systems/<server>.yaml    WHAT to collect — one per server
    tomcat.yaml  nginx.yaml  nginx-python.yaml  mysql.yaml  mcp.yaml

../instances/<vm>/exporter.yaml   WHERE to send it — ONE PER VM
    ziniapps-vm/exporter.yaml   elasticsearch/ziniapps-vm -> logs-ziniapps-vm
    www-vm/exporter.yaml        elasticsearch/www-vm      -> logs-www-vm
```

**One exporter per VM is a constraint, not a convention.** A VM runs one
collector with one `config.yaml`, so it has exactly one destination. `ziniapps-vm`
runs the three assess apps and both ziniapps sites; all five ship through its
single exporter, and telling their lines apart is a query concern — every record
carries `service.name`, `deployment.environment`, `image.flavor` and `log.type`.

`push.sh --vm <name>` selects one of those, and a push must pass either that or
`--exporter none` — there is no default. `--exporter` takes **only** `none`, the
off switch that renders the inert config; any other value is an error pointing
at `--vm`, and passing both flags is an error rather than a silent precedence
rule.

> **A target with no `vm/instances/<name>/` folder can only be pushed inert.** The
> `mcp` VM in `dz-builds` is the one such host today: `vm/systems/mcp.yaml` says
> what to collect, but nothing says where to send it. Give it
> `vm/instances/mcp/exporter.yaml` when it needs to ship logs. Note also that deleting
> `exporters/` removed the only **clickhouse** block — every VM exporter is
> elasticsearch, so clickhouse is no longer reachable from this tree.

Each VM's credentials are host-scoped (`OTEL_ZINIAPPS_VM_ES_ENDPOINT`,
`OTEL_ZINIAPPS_VM_ES_API_KEY`, and so on), so pushing with the wrong env file
fails at collector start rather than shipping to the wrong place.

> **ONE COLLECTOR PER VM, therefore one exporter per VM.** `assess` and
> `ziniapps` both deploy onto `ziniapps-vm`, so only one of their exporters can
> be live there at a time, and whichever you push receives **both** products'
> lines. Nothing separates them yet: no deploy script sets `access_log`, so
> every site writes to the default `/var/log/nginx/*.log`. Give the sites their
> own `access_log` paths before treating either index as single-product.

**There is no CI for this folder.** A `cloudbuild.yaml` here rendered and
validated every flavor x exporter combination, but `build-app-install` is not a
connected Cloud Build repository — nothing ever triggered it — so it was deleted
rather than left reading like a safety net that was not there. The only check
before a config reaches a VM is `push.sh --dry-run` and the `otelcol-contrib
validate` it runs when that binary is on your machine. Keep it installed.

## Usage

```bash
# What would be pushed, without pushing it
./push.sh --instance ziniapps-vm --zone asia-east1-b --project dz-ziniapps \
          --exporter elasticsearch --dry-run

# Turn monitoring ON for one VM
./push.sh --instance ziniapps-vm --zone asia-east1-b --project dz-ziniapps \
          --exporter elasticsearch --env-file /tmp/otel-env

# Turn it OFF again - inert config, no image rebuild
./push.sh --instance ziniapps-vm --zone asia-east1-b --project dz-ziniapps \
          --exporter none
```

`push.sh` reads the target's flavor from `/etc/image-manifest.txt` rather than
trusting an inventory, so it cannot ship a Tomcat config to a box with no
Tomcat. It looks the flavor up in `vm/systems/`, and with the combined flavors
gone it finds no file at all for a combined-flavor box; that lookup is what the
composition step has to change.

## The env file

Exporter endpoints and credentials live in `/etc/otelcol/env` on the target
(640 `root:otelcol`), referenced from the configs as `${env:OTEL_*}` and read by
the unit's `EnvironmentFile`. **They are never in this repo.** Build the file
from Secret Manager at push time:

```bash
cat > /tmp/otel-env <<EOF
OTEL_DEPLOY_ENV=production
OTEL_SERVICE_NAME=ziniapps
OTEL_ZINIAPPS_VM_ES_ENDPOINT=$(gcloud secrets versions access latest --secret=otel-ziniapps-vm-es-endpoint)
OTEL_ZINIAPPS_VM_ES_API_KEY=$(gcloud secrets versions access latest --secret=otel-ziniapps-vm-es-api-key)
EOF
```

Keeping secrets out of `config.yaml` also means a config can be diffed, or
pasted into a ticket, without leaking a key.

## Editing a config

System configs (`vm/systems/*.yaml`) are **complete files**, one per server,
with two placeholder tokens
(`@EXPORTER@`, `@EXPORTER_NAME@`) that `push.sh` fills. `@EXPORTER@` is spliced
only on a line that is **nothing but the token** — the header names both tokens
in prose, and an unanchored match used to splice the whole exporter block into
that comment and render invalid YAML. Keep the placeholder on its own line. The five files duplicate
a lot, deliberately: duplication you can read beats indirection you have to
trace.

> **The combined-flavor configs were deleted on 2026-09-24**
> (`tomcat-mysql`, `tomcat-nginx-mysql`), along with `git` and `java`. The
> intent is to compose the per-server configs instead. **The composition step
> does not exist yet** — `push.sh` still resolves exactly one
> `configs/<flavor>.yaml` from the target's `/etc/image-manifest.txt`
> ([push.sh:67](push.sh)), so a push to a `tomcat-nginx-mysql` box (which is
> what `ziniapps-vm` is) now fails with *no config for flavor*. See the design
> doc before building the composer: **the Collector's native multi-`--config`
> merge will not do this** — maps merge but lists are replaced, so
> `service.pipelines.logs.receivers` takes the last fragment only and a
> component's logs vanish silently.

Four rules when editing:

1. **Keep them thin.** Tail, stamp resource attributes, ship. No grok, no JSON
   parsing, no severity mapping. If you are reaching for a parser, that is the
   signal to stand up a gateway collector, not to thicken the edge.
2. **Always declare `health_check` on `127.0.0.1:13133`.** `apply.sh` polls it
   to decide whether a push worked. A config without it gets rolled back even
   when it is perfectly good. CI checks this.
3. **Validate before you push.** `./push.sh ... --dry-run` renders the config
   and, if `otelcol-contrib` is on your machine, validates it. Nothing else
   will: `apply.sh` does not re-validate on the target, and there is no CI.
4. **Always stamp the resource attributes.** Without `service.name`,
   `deployment.environment`, `image.flavor` and `log.type`, the destination is
   an undifferentiated mush and fixing it later means reindexing.

## Gotchas

- **Healthy does not mean shipping.** A collector with the inert config, and
  one that cannot read a single log file, both report healthy. The difference
  shows up exactly once, at startup:
  `sudo journalctl -u otelcol -b | grep -i 'error\|permission\|denied'`.
- **Permissions are the number one silent failure.** `apply.sh` adds `otelcol`
  to `systemd-journal`, `adm` and `tomcat` where those exist. Supplementary
  groups only take effect at process start, which is why it restarts rather
  than reloads.
- **No reload, ever.** The collector does not reliably reload on SIGHUP, and
  `otelcol.service` declares no `ExecReload` on purpose.
- **Queues are in memory.** Logs buffered on a VM are lost if it restarts while
  the destination is down. Durable buffering is a gateway's job.
- **Validate against the version the fleet runs.** The collector version is
  pinned in `versions.env` in `build-vm-images`; the `otelcol-contrib` on your
  machine should match it. Validating against a different version is worse than
  not validating — it reports green on a config the VMs will reject.

## No `docker/` counterpart

Containers log to stdout and the runtime collects it. The asymmetry is correct
and should not be "fixed" — and it is why this folder sits under `vm/` rather
than beside it.
