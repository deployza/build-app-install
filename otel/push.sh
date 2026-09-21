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
# WHY THE PUSHER RENDERS. The pusher already knows which VM it picked, so it
# knows the flavor; making the target work that out again would be a second
# source of truth that can drift from the first. See
# ../../build-docs/ops-execution.md, "No host probing".
#
# RENDERING IS TWO TOKEN SUBSTITUTIONS, not a template language: @EXPORTER@ and
# @EXPORTER_NAME@ in configs/<flavor>.yaml are replaced from
# exporters/<backend>.yaml. Same convention as @INSTANCE_DIR@ in
# build-vm-images' tomcat.service. CI renders and validates every flavor x
# exporter combination, so a broken pairing fails there, not here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[otel-push] $*"; }
die()  { echo "[otel-push] ERROR: $*" >&2; exit 1; }

INSTANCE=""; ZONE=""; PROJECT=""; EXPORTER="none"; ENV_FILE=""; DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --zone)     ZONE="$2";     shift 2 ;;
    --project)  PROJECT="$2";  shift 2 ;;
    --exporter) EXPORTER="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true;  shift   ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE" ]] || die "--instance is required"
[[ -n "$ZONE"     ]] || die "--zone is required"
[[ -n "$PROJECT"  ]] || die "--project is required"

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

CONFIG_SRC="${SCRIPT_DIR}/configs/${FLAVOR}.yaml"
[[ -f "$CONFIG_SRC" ]] || die "no config for flavor '${FLAVOR}' (expected ${CONFIG_SRC})"


# -----------------------------------------------------------------------------
# 2. Render
# -----------------------------------------------------------------------------
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
RENDERED="${RENDER_DIR}/config.yaml"

if [[ "$EXPORTER" == "none" ]]; then
  # Explicitly inert: collect nothing, send nowhere. This is how you take a VM
  # OUT of monitoring without rebuilding its image — and it is a real config,
  # exercised by the same apply path, not a special case.
  log "exporter: none — rendering an inert config"
  EXPORTER_BLOCK="  nop:"
  EXPORTER_NAME="nop"
else
  EXPORTER_SRC="${SCRIPT_DIR}/exporters/${EXPORTER}.yaml"
  [[ -f "$EXPORTER_SRC" ]] || die "unknown exporter '${EXPORTER}' (expected ${EXPORTER_SRC})"
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
  log "exporter: ${EXPORTER} (pipeline key '${EXPORTER_NAME}')"
fi

# awk, not sed: the exporter block is multi-line, and sed's handling of
# newlines in a replacement is a portability trap not worth stepping in.
awk -v block="$EXPORTER_BLOCK" -v name="$EXPORTER_NAME" '
  /@EXPORTER@/      { print block; next }
  /@EXPORTER_NAME@/ { gsub(/@EXPORTER_NAME@/, name); print; next }
                    { print }
' "$CONFIG_SRC" > "$RENDERED"

grep -q '@EXPORTER' "$RENDERED" && die "unsubstituted placeholder left in rendered config"

# Validate locally if the collector happens to be on this machine. Optional by
# design — CI is the authority and has already checked every combination — but
# free when available and it shortens the loop while editing a config.
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

log "done: ${INSTANCE} (${FLAVOR}) -> ${EXPORTER}"
