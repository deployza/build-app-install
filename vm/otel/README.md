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
A freshly created VM therefore has a collector that is running, up, and
**collecting nothing and sending nowhere** until something here is pushed to it.

## Layout

**This folder holds only the tooling.** The content lives in the `vm/` tree,
which is organised by layer:

```
vm/otel/
├── push.sh              PUSHER-side: assemble + ship + apply. Runs on your laptop.
├── inert.yaml           the "collect nothing, send nowhere" config
└── apply.sh             TARGET-side: swap, restart, health check, roll back.

../systems/_base.yaml       journald + hostmetrics — EVERY host, always
../systems/<server>.yaml    WHAT A SERVER WRITES — receivers only, one per server
    tomcat.yaml  nginx.yaml  mysql.yaml  mcp.yaml (empty: journald covers it)

../apps/<app>/receiver.yaml WHAT ONE APP WRITES, when it writes somewhere no
                            system fragment reaches
    assess-server/receiver.yaml   the only one today

../instances/<vm>/exporter.yaml   PROCESSORS AND EXPORTERS — how this host stamps
                                  its records and where they go
../instances/<vm>/pipeline.yaml   THE SERVICE GRAPH — one pipeline per service,
                                  hand-written per host
    both VMs ->  googlecloudpubsub/logs     -> prod.vm.logs-topic
                 googlecloudpubsub/metrics  -> prod.vm.metrics-topic
```

**The split is receivers vs everything else.** `systems/` and `apps/` answer
*what does this software write, and where* — a fact about the software, true on
every host that runs it. `instances/` answers *what does this host do with it* —
processors, destination, wiring — which cannot be stated per-server, because a
VM runs **one** collector with **one** `config.yaml` and therefore one set of
resource attributes and exactly one destination. `push.sh` assembles the two.

## Services

**A "service" here is one pipeline, one `service.name`, one destination.** Each
one is declared twice, in two halves of the same statement: a `logs/<name>`
pipeline in the VM's `pipeline.yaml`, and a matching `resource/<name>` processor
in its `exporter.yaml` that stamps the name. Change one without the other and
you either drop a `service.name` or reference a processor that does not exist.

| VM | services |
|---|---|
| `ziniapps-vm` | `journal`, `tomcat`, `mysql`, `nginx`, `assess-server`, `systemetrics` |
| `www-vm` | `journal`, `nginx`, `systemetrics` |

`journal` and `systemetrics` are host-level and exist on every VM — the journald
receiver and the hostmetrics scrapers, both from `systems/_base.yaml`. The rest
come from the image flavor, except `assess-server`, which is an APP-level
service and the only one today.

**Exactly three resource attributes reach the destination**, by decision:
`service.name` (stamped per pipeline), `host.name` (detected) and `host.project`
(from `push.sh --project`). `deployment.environment` and `image.flavor` are
deliberately no longer sent. The `system` detector is pinned to `host.name` with
`os.type` explicitly disabled, because it emits both by default.

> **An app is only collected if someone gives it a receiver.**
> `systems/tomcat.yaml` no longer globs `logs/*/*.log`, so a Tomcat app's own
> log directory reaches Pub/Sub only when it has an `apps/<app>/receiver.yaml`,
> a name in its VM's `# apps:` header, a `resource/<app>` processor and a
> pipeline. That is the price of every line carrying exactly one `service.name`
> instead of being shipped twice.

**One exporter set per VM is a constraint, not a convention.** A VM runs one
collector with one `config.yaml`. `ziniapps-vm` runs the three assess apps and
both ziniapps sites; all of them ship through its two topics, and telling their
lines apart downstream is a subscriber concern keyed on `service.name`.

`push.sh --vm <name>` selects one of those, and a push must pass either that or
`--exporter none` — there is no default. `--exporter` takes **only** `none`, the
off switch that renders the inert config; any other value is an error pointing
at `--vm`, and passing both flags is an error rather than a silent precedence
rule.

> **A target with no `vm/instances/<name>/` folder can only be pushed inert.** The
> `mcp` VM in `dz-builds` is the one such host today: `vm/systems/mcp.yaml` says
> what to collect (nothing beyond the journal), but nothing says where to send it
> **or how to stamp and wire it** — that is the whole pipeline, not just the
> destination. Give it `vm/instances/mcp/` with a `pipeline.yaml` and an
> `exporter.yaml` when it needs to ship logs — and with IAM auth that is now
> cheap, since there is no credential to provision, only
> `roles/pubsub.publisher` for its attached service account.

**Authentication is IAM, and there are no credentials in this repo or on the
box.** The Pub/Sub exporter uses Application Default Credentials, which on a GCE
instance means the VM's **attached service account**. That account needs
`roles/pubsub.publisher` on both topics and nothing else. There is no API key,
no endpoint secret, and nothing to fetch from Secret Manager at push time.

> **The nginx stream is still not split by site.** No deploy script sets
> `access_log`, so every site on a host writes to the default
> `/var/log/nginx/*.log` and arrives as `service.name=nginx`. Give the sites
> their own `access_log` paths, then their own receivers and pipelines, before
> treating any of it as single-site.

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
          --vm ziniapps-vm --dry-run

# Turn monitoring ON for one VM
./push.sh --instance ziniapps-vm --zone asia-east1-b --project dz-ziniapps \
          --vm ziniapps-vm --env-file /tmp/otel-env

# Turn it OFF again - inert config, no image rebuild
./push.sh --instance ziniapps-vm --zone asia-east1-b --project dz-ziniapps \
          --exporter none
```

`push.sh` reads the target's flavor from `/etc/image-manifest.txt` rather than
trusting an inventory, so it cannot ship a Tomcat config to a box with no
Tomcat. It then **splits that flavor on `-`** and splices one `vm/systems/`
fragment per token: `tomcat-nginx-mysql` — which is what `ziniapps-vm` is —
renders `journald`, `filelog/tomcat`, `filelog/nginx` and `filelog/mysql` into
one receivers map and one receivers list. A token with no fragment fails the
push by name.

## The env file

**Nothing renders a `${env:}` reference any more, so `--env-file` is currently
unused.** It went away in three steps: Pub/Sub authenticates with the attached
service account (no endpoint, no key), `service.name` is stamped per pipeline
rather than read from `OTEL_SERVICE_NAME`, and `deployment.environment` is no
longer sent at all.

The flag, `/etc/otelcol/env` and apply.sh's handling of it all survive for the
day a config needs one again. Until then a push takes no secrets, and every file
in this tree can be diffed or pasted into a ticket as it stands.

## Editing a config

**Decide which layer your change belongs to first — that is the whole design.**

| You are changing… | Edit |
|---|---|
| where a server writes its logs | `vm/systems/<server>.yaml` |
| what an app writes, outside Tomcat/nginx/journal | `vm/apps/<app>/receiver.yaml`, and add it to the pipeline's `# apps:` header |
| a processor, or the attributes stamped on every record | `vm/instances/<vm>/exporter.yaml` |
| a destination or a topic | `vm/instances/<vm>/exporter.yaml` |
| which pipelines exist, i.e. adding or removing a service | `vm/instances/<vm>/pipeline.yaml` **and** its `resource/<name>` processor |

`vm/instances/<vm>/pipeline.yaml` is the skeleton, with two block tokens that
`push.sh` fills — `@RECEIVERS@` and `@EXPORTER@` — plus `@PROJECT@` substituted
inline, including **inside** the spliced blocks. `@EXPORTER@` sits at column 0
because `exporter.yaml` declares two top-level keys, `processors:` and
`exporters:`, not one. **Block tokens are spliced only on a line that is nothing
but the token**: the header names them in prose, and an unanchored match used to
splice the whole exporter block into that comment and render invalid YAML.

Every fragment in `vm/systems/` and `vm/apps/` opens with a `# receivers:`
header, and every `pipeline.yaml` with a `# apps:` header. **Both are
load-bearing, not documentation** — `push.sh` builds
`service.pipelines.logs.receivers` from the first and resolves app fragments
from the second. A fragment whose header disagrees with its block fails the
push, as does a receiver name declared in two fragments (they concatenate into
one map, where a repeated key is a YAML error and not a merge — which is why
`journald` sits in `_base.yaml` alone).

**The pipelines are hand-written, not generated**, so nothing keeps them in step
with the rest automatically. `push.sh` checks them instead, after rendering: a
pipeline naming a receiver the flavor does not provide **fails the push**, and a
receiver that is assembled but used by no pipeline **warns** (it would silently
collect nothing). Both failures are invisible on the box now that there is no
health endpoint, which is why they are caught here.

> **The combined-flavor configs were deleted on 2026-09-24** (`tomcat-mysql`,
> `tomcat-nginx-mysql`), along with `git` and `java`, and the per-server files
> were reduced to receiver fragments the same day. **Composition now works** —
> `push.sh` splits the flavor and splices one fragment per token. It does this
> by concatenation and **not** with the Collector's native multi-`--config`
> merge, which cannot do it: maps merge but lists are replaced, so
> `service.pipelines.logs.receivers` would take the last fragment only and a
> component's logs would vanish silently.

Four rules when editing:

1. **Keep them thin.** Tail, stamp resource attributes, ship. No grok, no JSON
   parsing, no severity mapping. If you are reaching for a parser, that is the
   signal to stand up a gateway collector, not to thicken the edge.
2. **There are no extensions, and `apply.sh` is weaker for it.** It used to poll
   `health_check` on `127.0.0.1:13133`; now it only watches the systemd unit
   stay active for 15s after the restart. That still catches a collector that
   starts and dies, but a config that comes up and fails to bring up a pipeline
   is **accepted** rather than rolled back. Re-adding `health_check` to each
   `exporter.yaml` and an `extensions:` key to each `pipeline.yaml` is all it
   would take to restore the old guarantee.
3. **Validate before you push.** `./push.sh ... --dry-run` renders the config
   and, if `otelcol-contrib` is on your machine, validates it. Nothing else
   will: `apply.sh` does not re-validate on the target, and there is no CI.
4. **Every pipeline must stamp a `service.name`.** It is the only thing telling
   one service's records from another's inside a shared topic. A pipeline that
   omits its `resource/<name>` processor produces records nothing downstream can
   attribute, and fixing that later means reprocessing whatever was written.

## Gotchas

- **Up does not mean shipping.** A collector with the inert config, and one
  that cannot read a single log file, both stay happily active. The difference
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
- **Your `otelcol-contrib` must include `googlecloudpubsub` and `hostmetrics`.**
  `--dry-run`'s validate step is skipped when the binary is missing, and fails
  loudly if the binary lacks a component — which is the good case. The bad case
  is pushing a config the fleet's collector cannot load.
- **Validate against the version the fleet runs.** The collector version is
  pinned in `versions.env` in `build-vm-images`; the `otelcol-contrib` on your
  machine should match it. Validating against a different version is worse than
  not validating — it reports green on a config the VMs will reject.

## No `docker/` counterpart

Containers log to stdout and the runtime collects it. The asymmetry is correct
and should not be "fixed" — and it is why this folder sits under `vm/` rather
than beside it.
