#!/bin/bash
# push.sh — PUSHER-SIDE. Runs on a laptop, in CI, or later as a Rundeck /
# Semaphore job. Never on the target.
#
#   ./push.sh --instance <name> --zone <zone> --project <p> \
#             [--exporter elasticsearch|clickhouse|none] \
#             [--env-file <path>] [--dry-run]
#
# It renders a complete collector config for the target's image flavor, ships
# this directory over the IAP tunnel, and runs apply.sh there.
#
# WHERE THE PIECES LIVE. This folder holds only the tooling. The content is in
# the vm/ tree, which is organised by LAYER:
#   vm/systems/<server>.yaml         what to collect — one per server (tomcat,
#                                    nginx, nginx-python, mysql, mcp)
#   vm/vms/<vm>/exporter.yaml        where to send it — one per VM
#   vm/apps/<app>/<app>.sh           the app deploys, not used by this script
#
# WHY THE PUSHER RENDERS. The pusher already knows which VM it picked, so it
# knows the flavor; making the target work that out again would be a second
# source of truth that can drift from the first. See
# ../../build-docs/ops-execution.md, "No host probing".
#
# RENDERING IS TWO TOKEN SUBSTITUTIONS, not a template language: @EXPORTER@ and
# @EXPORTER_NAME@ in configs/<flavor>.yaml are replaced from an exporter file.
# Same convention as @INSTANCE_DIR@ in build-vm-images' tomcat.service.
#
# THE EXPORTER COMES FROM THE VM. `--vm <name>` splices
# ../vm/vms/<name>/exporter.yaml — that host's exporter, with its own endpoint,
# credentials and index. ONE PER VM is not a convention but a constraint: a VM
# runs one collector with one config.yaml, so it has exactly one destination and
# every app on it ships through that.
#
# `--exporter` survives with exactly one accepted value, `none`, which renders
# the inert config that takes a VM out of monitoring. Any other value is an
# error pointing at --vm. --vm and --exporter are mutually exclusive.
#
# A TARGET WITH NO vm/vms/<name>/ FOLDER can only be pushed inert. The `mcp` VM
# in dz-builds is the one such host today: vm/systems/mcp.yaml says what to
# collect, but nothing says where to send it. Give it vm/vms/mcp/exporter.yaml
# when it needs to ship logs.
#
# ONE COLLECTOR PER VM, so ONE exporter per VM. That is why exporters are keyed
# by host: ziniapps-vm runs the three assess apps and the two ziniapps sites,
# and all five ship through vm/vms/ziniapps-vm/exporter.yaml. Telling their
# lines apart is a query concern — every record carries service.name,
# deployment.environment, image.flavor and log.type.
#
# THIS SCRIPT IS THE ONLY PLACE A CONFIG IS CHECKED BEFORE IT REACHES A VM.
# There is no CI job for otel/ — one existed, was never wired to a trigger,
# and was deleted rather than left looking like a safety net. So run --dry-run
# on a config you have just edited, and keep otelcol-contrib on the machine you
# push from: the validate step below is skipped when it is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[otel-push] $*"; }
die()  { echo "[otel-push] ERROR: $*" >&2; exit 1; }

INSTANCE=""; ZONE=""; PROJECT=""; EXPORTER="none"; ENV_FILE=""; DRY_RUN=false
VM=""
# Distinguishes "--exporter was passed" from the "none" default, so that
# `--vm X` alone is not mistaken for a conflict with an explicit exporter.
EXPORTER_SET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --zone)     ZONE="$2";     shift 2 ;;
    --project)  PROJECT="$2";  shift 2 ;;
    --vm)       VM="$2";       shift 2 ;;
    --exporter) EXPORTER="$2"; EXPORTER_SET=true; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true;  shift   ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE" ]] || die "--instance is required"
[[ -n "$ZONE"     ]] || die "--zone is required"
[[ -n "$PROJECT"  ]] || die "--project is required"

# Mutually exclusive rather than one silently overriding the other: a push that
# quietly ignored --vm would send a host's logs somewhere else.
if [[ -n "$VM" && "$EXPORTER_SET" == true ]]; then
  die "--vm and --exporter are mutually exclusive (--vm IS the exporter choice; use --exporter none alone to turn monitoring off)"
fi

# 'none' is the only backend name left: the exporters/ library was deleted and
# every real exporter now lives in a VM folder. Failing loudly here beats
# failing later on a missing file with a confusing path.
if [[ "$EXPORTER_SET" == true && "$EXPORTER" != "none" ]]; then
  die "--exporter takes only 'none' (the off switch); use --vm <name> to pick a real exporter"
fi

# Neither flag means neither destination nor an explicit opt-out. Refuse rather
# than silently rendering an inert config someone did not ask for.
if [[ -z "$VM" && "$EXPORTER_SET" == false ]]; then
  die "one of --vm <name> or --exporter none is required"
fi

# Resolve the VM's exporter NOW, before the flavor round trip below, so a typo'd
# VM name fails instantly instead of after an SSH to the target.
EXPORTER_SRC=""
if [[ -n "$VM" ]]; then
  EXPORTER_SRC="${SCRIPT_DIR}/../vm/vms/${VM}/exporter.yaml"
  [[ -f "$EXPORTER_SRC" ]] || die "unknown vm '${VM}' (expected ${EXPORTER_SRC})"
fi

SSH=(gcloud compute ssh "$INSTANCE" --zone "$ZONE" --project "$PROJECT" --tunnel-through-iap)


# -----------------------------------------------------------------------------
# 1. Resolve the flavor FROM THE TARGET, not from an inventory
# -----------------------------------------------------------------------------
# /etc/image-manifest.txt is baked by write-manifest.sh and is the one record
# that cannot drift. Reading it costs one round trip and prevents the whole
# class of bug where a VM was rebuilt from a different family and we push a
# config for log paths it does not have.
log "resolving image flavor on ${INSTANCE}"
FLAVOR="$("${SSH[@]}" --command 'sed -n "s/^image-flavor:[[:space:]]*//p" /etc/image-manifest.txt' 2>/dev/null | tr -d '\r' | head -n1)"
[[ -n "$FLAVOR" ]] || die "could not read image-flavor from /etc/image-manifest.txt on ${INSTANCE}"
log "flavor: ${FLAVOR}"

CONFIG_SRC="${SCRIPT_DIR}/../vm/systems/${FLAVOR}.yaml"
[[ -f "$CONFIG_SRC" ]] || die "no system config for flavor '${FLAVOR}' (expected ${CONFIG_SRC})"


# -----------------------------------------------------------------------------
# 2. Render
# -----------------------------------------------------------------------------
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
RENDERED="${RENDER_DIR}/config.yaml"

# EXPORTER_SRC was resolved and existence-checked during argument validation
# above; empty means --exporter none, whose block is set inline here.
if [[ -n "$EXPORTER_SRC" ]]; then
  # The VM's exporter, which lives with that VM's install script rather than
  # here: the folder that describes the host is the folder that says where its
  # logs go.
  EXPORTER_LABEL="vm:${VM}"
else
  # Explicitly inert: collect nothing, send nowhere. This is how you take a VM
  # OUT of monitoring without rebuilding its image — and it is a real config,
  # exercised by the same apply path, not a special case.
  log "exporter: none — rendering an inert config"
  EXPORTER_BLOCK="  nop:"
  EXPORTER_NAME="nop"
  EXPORTER_LABEL="none"
fi

if [[ -n "$EXPORTER_SRC" ]]; then
  # The exporter file's first line is a comment naming the pipeline key, e.g.
  # "# name: elasticsearch". Keeping the name IN the file means the two can
  # never disagree.
  EXPORTER_NAME="$(sed -n 's/^#[[:space:]]*name:[[:space:]]*//p' "$EXPORTER_SRC" | head -n1)"
  [[ -n "$EXPORTER_NAME" ]] || die "${EXPORTER_SRC} has no '# name:' header line"
  # Take everything from the first non-comment, non-blank line onward — i.e.
  # drop the whole leading header, not just the "# name:" line. The header
  # documents the file for a reader of the repo; splicing it into the rendered
  # config would put repo-internal prose on every VM, and (because it mentions
  # the placeholder tokens by name) would defeat the leftover-placeholder check
  # below. Comments INSIDE the YAML block are kept deliberately: they explain
  # the settings to whoever is reading config.yaml on the box at 3am.
  EXPORTER_BLOCK="$(awk 'started || (!/^#/ && NF) { started = 1; print }' "$EXPORTER_SRC")"
  log "exporter: ${EXPORTER_LABEL} (pipeline key '${EXPORTER_NAME}', from ${EXPORTER_SRC#${SCRIPT_DIR}/})"
fi

# awk, not sed: the exporter block is multi-line, and sed's handling of
# newlines in a replacement is a portability trap not worth stepping in.
#
# MATCHING IS ANCHORED, and that is load-bearing. Every vm/systems/<server>.yaml
# opens with a header that names both tokens in prose:
#
#   # A COMPLETE collector config, except for two tokens (@EXPORTER@ and
#   # @EXPORTER_NAME@) that push.sh fills from an exporter file.
#
# An unanchored /@EXPORTER@/ matched that comment too and printed the whole
# exporter block into the header — a bare mapping above the first real key, so
# the rendered config was invalid YAML. The leftover check below could not see
# it either, because both occurrences had been consumed. So: the block is
# spliced only on a line that is nothing but the placeholder, and comment lines
# are passed through untouched.
awk -v block="$EXPORTER_BLOCK" -v name="$EXPORTER_NAME" '
  /^[[:space:]]*@EXPORTER@[[:space:]]*$/ { print block; next }
  /^[[:space:]]*#/                       { print; next }
  /@EXPORTER_NAME@/ { gsub(/@EXPORTER_NAME@/, name); print; next }
                    { print }
' "$CONFIG_SRC" > "$RENDERED"

# Comments are excluded: the header legitimately names the tokens and must not
# trip this. Only a placeholder left in actual YAML is a failure.
if grep -v '^[[:space:]]*#' "$RENDERED" | grep -q '@EXPORTER'; then
  die "unsubstituted placeholder left in rendered config"
fi

# Validate locally if the collector happens to be on this machine. This is the
# ONLY schema check in the whole path — apply.sh deliberately does not repeat it
# on the target — so a machine without otelcol-contrib pushes unvalidated YAML.
# Install it (same version as versions.env in build-vm-images) before editing
# configs. Not a hard requirement, because failing a push over a missing local
# tool would be worse than the risk it covers: a bad config is caught on the
# target by apply.sh's health check and rolled back.
if command -v otelcol-contrib >/dev/null 2>&1; then
  otelcol-contrib validate --config "$RENDERED" || die "rendered config failed local validate"
  log "local validate passed"
fi

if [[ "$DRY_RUN" == true ]]; then
  log "--dry-run: rendered config follows, nothing pushed"
  echo "-----------------------------------------------------------------"
  cat "$RENDERED"
  exit 0
fi


# -----------------------------------------------------------------------------
# 3. Push and apply
# -----------------------------------------------------------------------------
# Everything goes in one tar over the tunnel: the rendered config, the env file
# if there is one, and apply.sh itself. Nothing is cloned on the target, so the
# bytes that run are the bytes that were here.
STAGE="${RENDER_DIR}/otel"
mkdir -p "$STAGE"
cp "$RENDERED" "${STAGE}/config.yaml"
cp "${SCRIPT_DIR}/apply.sh" "${STAGE}/apply.sh"

APPLY_ARGS="/tmp/otel/config.yaml"
if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
  # Fetch this from Secret Manager rather than keeping it on disk — see the
  # README. It is 640 in the tar and lands 640 root:otelcol on the target.
  install -m 600 "$ENV_FILE" "${STAGE}/env"
  APPLY_ARGS="${APPLY_ARGS} /tmp/otel/env"
fi

log "pushing to ${INSTANCE} and applying"
tar cz -C "$RENDER_DIR" otel \
  | "${SSH[@]}" --command "set -e
      rm -rf /tmp/otel
      tar xz -C /tmp
      chmod +x /tmp/otel/apply.sh
      sudo /tmp/otel/apply.sh ${APPLY_ARGS}
      rm -rf /tmp/otel"

log "done: ${INSTANCE} (${FLAVOR}) -> ${EXPORTER_LABEL}"
