# otel/ — OpenTelemetry Collector configuration

**This folder is not like `vm/` or `docker/`.** Those hold per-app deploy
scripts invoked by name from a baked launcher. This holds *operational* config,
pushed to a running VM on demand. Nothing at boot ever touches it.

Full design and the reasoning behind every choice here:
[`../../build-docs/ops-execution.md`](../../build-docs/ops-execution.md).

## The one rule

> Everything that lands on a running VM is **pushed** to it over SSH.
> Nothing on the VM pulls, clones or polls.

The image bakes only the mechanism — the collector binary, `otelcol.service`,
and an inert `nop` config (`build-vm-images/scripts/ubuntu/install-otel.sh`).
A freshly created VM therefore has a collector that is running, healthy, and
**collecting nothing and sending nowhere** until something here is pushed to it.

## Layout

```
otel/
├── push.sh              PUSHER-side: render + ship + apply. Runs on your laptop.
├── apply.sh             TARGET-side: swap, restart, health check, roll back.
├── configs/<flavor>.yaml   one complete config per image flavor
├── exporters/<backend>.yaml  the exporter block + its pipeline key
└── cloudbuild.yaml      CI: validates every flavor x exporter combination
```

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
Tomcat.

## The env file

Exporter endpoints and credentials live in `/etc/otelcol/env` on the target
(640 `root:otelcol`), referenced from the configs as `${env:OTEL_*}` and read by
the unit's `EnvironmentFile`. **They are never in this repo.** Build the file
from Secret Manager at push time:

```bash
cat > /tmp/otel-env <<EOF
OTEL_DEPLOY_ENV=production
OTEL_SERVICE_NAME=ziniapps
OTEL_ES_ENDPOINT=$(gcloud secrets versions access latest --secret=otel-es-endpoint)
OTEL_ES_API_KEY=$(gcloud secrets versions access latest --secret=otel-es-api-key)
EOF
```

Keeping secrets out of `config.yaml` also means a config can be diffed, or
pasted into a ticket, without leaking a key.

## Editing a config

Configs are **complete files**, one per flavor, with two placeholder tokens
(`@EXPORTER@`, `@EXPORTER_NAME@`) that `push.sh` fills. There is no merging, no
renderer and no fragment library — that was tried and dropped; see the design
doc. The nine files duplicate a lot, deliberately: duplication you can read
beats indirection you have to trace.

Three rules when editing:

1. **Keep them thin.** Tail, stamp resource attributes, ship. No grok, no JSON
   parsing, no severity mapping. If you are reaching for a parser, that is the
   signal to stand up a gateway collector, not to thicken the edge.
2. **Always declare `health_check` on `127.0.0.1:13133`.** `apply.sh` polls it
   to decide whether a push worked. A config without it gets rolled back even
   when it is perfectly good. CI checks this.
3. **Always stamp the resource attributes.** Without `service.name`,
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
- **`OTELCOL_VERSION` in `cloudbuild.yaml` must match `versions.env` in
  `build-vm-images`.** Different repos, so the pairing is manual. Validating
  against a version the fleet does not run is worse than not validating.

## No `docker/` counterpart

Containers log to stdout and the runtime collects it. The asymmetry is correct
and should not be "fixed".
