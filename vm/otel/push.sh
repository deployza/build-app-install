#!/bin/bash
# push.sh — PUSHER-SIDE. Runs on a laptop, in CI, or later as a Rundeck /
# Semaphore job. Never on the target.
#
#   ./push.sh --instance <name> --zone <zone> --project <p> \
#             [--vm <name> | --exporter none] \
#             [--env-file <path>] [--dry-run]
#
# It assembles a complete collector config for the target, ships this directory
# over the IAP tunnel, and runs apply.sh there.
#
# WHERE THE PIECES LIVE. This folder holds only the tooling. It sits inside the
# vm/ tree because Otel on a VM is a VM concern — there is no docker/ equivalent
# (containers log to stdout and the runtime collects it). Its siblings hold the
# content, split by WHAT KIND OF STATEMENT IT IS rather than by file:
#
#   ../instances/<vm>/pipeline.yaml    the SERVICE GRAPH: one pipeline per
#                                      service, hand-written per host.
#   ../instances/<vm>/exporter.yaml    PROCESSORS AND EXPORTERS — how its
#                                      records are stamped and where they go.
#   ../systems/_base.yaml              journald. Every host, always.
#   ../systems/<server>.yaml           what a given server writes — one fragment
#                                      per server (tomcat, nginx, mysql, mcp).
#   ../apps/<app>/receiver.yaml        what one app writes, when it writes
#                                      somewhere no system fragment reaches.
#   ../apps/<app>/<app>.sh             the app deploys, not used by this script.
#
# THE SPLIT IS RECEIVERS VS EVERYTHING ELSE. systems/ and apps/ answer "what
# does this software write, and where" — a question about the software, true on
# every host that runs it. instances/ answers "what does this host do with it" —
# processors, destination, wiring — which is a question about the host, because
# a VM runs ONE collector with ONE config.yaml and therefore one set of resource
# attributes and exactly one destination.
#
# RENDERING IS SPLICING, NOT A TEMPLATE LANGUAGE. Two block tokens, each on a
# line of its own, plus one inline substitution:
#   @RECEIVERS@  <- every receiver fragment's body, concatenated
#   @EXPORTER@   <- the VM's exporter.yaml, whole: PROCESSORS AND EXPORTERS.
#                   It sits at column 0 because that file declares two
#                   top-level keys, not one.
#   @PROJECT@    <- this script's own --project, for host.project and for the
#                   fully qualified Pub/Sub topic names
# Same convention as @INSTANCE_DIR@ in build-vm-images' tomcat.service.
#
# THE PIPELINES ARE HAND-WRITTEN, not generated. Each instance's pipeline.yaml
# spells out its own service graph — one pipeline per service, each stamped with
# its own service.name by a matching resource/<name> processor in that VM's
# exporter.yaml. Nothing here builds that list, so nothing here can keep it
# honest either; what this script does instead is CHECK it, below, against the
# receivers it actually assembled.
#
# WHY THE PUSHER ASSEMBLES. The pusher already knows which VM it picked; making
# the target work this out again would be a second source of truth that can
# drift from the first. See ../../../build-docs/ops-execution.md, "No host
# probing". The one thing it does ask the target is its image flavor, because
# /etc/image-manifest.txt is the record that cannot drift.
#
# COMBINED FLAVORS COMPOSE. A tomcat-nginx-mysql target splices _base.yaml plus
# tomcat.yaml plus nginx.yaml plus mysql.yaml into one receivers map and one
# receivers list. This is done here, by concatenation, and NOT by the
# Collector's own multi ---config merge, which cannot do it: maps merge but
# LISTS ARE REPLACED, so service.pipelines.logs.receivers would take the last
# fragment only and a component's logs would vanish silently.
#
# --exporter survives with exactly one accepted value, none, which ships
# inert.yaml — collect nothing, send nowhere, no assembly at all. Any other
# value is an error pointing at --vm. --vm and --exporter are mutually
# exclusive.
#
# A TARGET WITH NO ../instances/<name>/ FOLDER can only be pushed inert. The
# mcp VM in dz-builds is the one such host today: ../systems/mcp.yaml says what
# to collect (nothing beyond the journal), but nothing says where to send it or
# how to stamp it. Give it ../instances/mcp/ when it needs to ship logs.
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
# than silently shipping an inert config someone did not ask for.
if [[ -z "$VM" && "$EXPORTER_SET" == false ]]; then
  die "one of --vm <name> or --exporter none is required"
fi

# Resolve the VM's folder NOW, before the flavor round trip below, so a typo'd
# VM name fails instantly instead of after an SSH to the target.
EXPORTER_SRC=""; PIPELINE_SRC=""
if [[ -n "$VM" ]]; then
  VM_DIR="${SCRIPT_DIR}/../instances/${VM}"
  [[ -d "$VM_DIR" ]] || die "unknown vm '${VM}' (expected ${VM_DIR}/)"
  EXPORTER_SRC="${VM_DIR}/exporter.yaml"
  PIPELINE_SRC="${VM_DIR}/pipeline.yaml"
  [[ -f "$EXPORTER_SRC" ]] || die "${VM} has no exporter.yaml (expected ${EXPORTER_SRC})"
  [[ -f "$PIPELINE_SRC" ]] || die "${VM} has no pipeline.yaml (expected ${PIPELINE_SRC})"
fi

SSH=(gcloud compute ssh "$INSTANCE" --zone "$ZONE" --project "$PROJECT" --tunnel-through-iap)

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
RENDERED="${RENDER_DIR}/config.yaml"


# -----------------------------------------------------------------------------
# 1. Resolve the flavor FROM THE TARGET, not from an inventory
# -----------------------------------------------------------------------------
# /etc/image-manifest.txt is baked by write-manifest.sh and is the one record
# that cannot drift. Reading it costs one round trip and prevents the whole
# class of bug where a VM was rebuilt from a different family and we push a
# config for log paths it does not have. It is read even for an inert push, so
# the closing log line names what was actually there.
log "resolving image flavor on ${INSTANCE}"
FLAVOR="$("${SSH[@]}" --command 'sed -n "s/^image-flavor:[[:space:]]*//p" /etc/image-manifest.txt' 2>/dev/null | tr -d '\r' | head -n1)"
[[ -n "$FLAVOR" ]] || die "could not read image-flavor from /etc/image-manifest.txt on ${INSTANCE}"
log "flavor: ${FLAVOR}"


# -----------------------------------------------------------------------------
# 2. Assemble
# -----------------------------------------------------------------------------
# A fragment's body is everything from its first non-comment, non-blank line
# onward — i.e. the whole leading header is dropped, not just the name line. The
# header documents the file for a reader of the repo; splicing it into the
# rendered config would put repo-internal prose on every VM, and (because these
# headers mention the placeholder tokens by name) would defeat the
# leftover-placeholder check below. Comments INSIDE a block are kept
# deliberately: they explain the settings to whoever is reading config.yaml on
# the box at 3am.
fragment_body() { awk 'started || (!/^#/ && NF) { started = 1; print }' "$1"; }

if [[ -z "$PIPELINE_SRC" ]]; then
  # Explicitly inert: collect nothing, send nowhere. A complete file with no
  # tokens, so there is nothing to assemble — and it is a real config, applied
  # through the same path with the same health check, not a special case.
  log "exporter: none — shipping the inert config"
  cp "${SCRIPT_DIR}/inert.yaml" "$RENDERED"
  CONFIG_LABEL="none"
else
  # ---- receivers: _base, then one fragment per flavor token, then any app ----
  #
  # The flavor is split on '-' because that is how combined flavors are named:
  # tomcat-nginx-mysql is three servers on one box and wants all three
  # fragments. A single-server flavor is just the one-token case of the same
  # rule, so there is no separate path for it.
  BASE_FRAG="${SCRIPT_DIR}/../systems/_base.yaml"
  [[ -f "$BASE_FRAG" ]] || die "missing ${BASE_FRAG} (journald is spliced into every config)"
  FRAGMENTS=("$BASE_FRAG")

  for TOKEN in $(echo "$FLAVOR" | tr '-' ' '); do
    FRAG="${SCRIPT_DIR}/../systems/${TOKEN}.yaml"
    # A missing fragment is "you pushed to a server nobody has described yet",
    # which is a real gap and must stop the push. It is NOT the same as a
    # fragment that exists and declares no receivers — see systems/mcp.yaml.
    [[ -f "$FRAG" ]] || die "no system fragment for '${TOKEN}' in flavor '${FLAVOR}' (expected ${FRAG})"
    FRAGMENTS+=("$FRAG")
  done

  # Apps that write somewhere no system fragment reaches, named in the
  # pipeline's '# apps:' header. Empty on every host today, because everything
  # logs through Tomcat, nginx or the journal.
  grep -q '^#[[:space:]]*apps:' "$PIPELINE_SRC" \
    || die "${PIPELINE_SRC} has no '# apps:' header line (write it empty if there are none)"
  APPS="$(sed -n 's/^#[[:space:]]*apps:[[:space:]]*//p' "$PIPELINE_SRC" | head -n1 | tr ',' ' ')"
  for APP in $APPS; do
    FRAG="${SCRIPT_DIR}/../apps/${APP}/receiver.yaml"
    [[ -f "$FRAG" ]] || die "pipeline lists app '${APP}' but ${FRAG} does not exist"
    FRAGMENTS+=("$FRAG")
  done

  RECEIVER_BLOCK=""
  RECEIVER_NAMES=""
  for FRAG in "${FRAGMENTS[@]}"; do
    # Presence and value are checked separately: an ABSENT header is an
    # unfinished file, while a PRESENT but empty one is a deliberate "this
    # contributes nothing" (systems/mcp.yaml). Conflating them would either
    # reject mcp or silently accept a fragment whose receivers never arrive.
    grep -q '^#[[:space:]]*receivers:' "$FRAG" \
      || die "${FRAG} has no '# receivers:' header line"
    NAMES="$(sed -n 's/^#[[:space:]]*receivers:[[:space:]]*//p' "$FRAG" | head -n1 | tr ',' ' ')"
    BODY="$(fragment_body "$FRAG")"

    # The header and the block are two statements of the same fact, which is why
    # the header is load-bearing rather than documentation. If they disagree the
    # config is either missing a receiver or naming one that does not exist, and
    # both fail at collector start with a message that does not point here.
    if { [[ -z "$NAMES" ]] && [[ -n "$BODY" ]]; } || { [[ -n "$NAMES" ]] && [[ -z "$BODY" ]]; }; then
      die "${FRAG}: '# receivers:' header and the block below disagree (one is empty)"
    fi

    for NAME in $NAMES; do
      # Fragments are concatenated into ONE receivers map, so a key declared
      # twice is a duplicate YAML key, not a merge. This is the failure mode a
      # combined flavor invites — it is why journald lives in _base.yaml alone —
      # and catching it here beats catching it in otelcol's parser.
      case " ${RECEIVER_NAMES} " in
        *" ${NAME} "*) die "receiver '${NAME}' declared twice (second time in ${FRAG})" ;;
      esac
      RECEIVER_NAMES="${RECEIVER_NAMES}${RECEIVER_NAMES:+ }${NAME}"
    done

    if [[ -n "$BODY" ]]; then
      RECEIVER_BLOCK="${RECEIVER_BLOCK}${RECEIVER_BLOCK:+$'\n'}${BODY}"
    fi
  done

  [[ -n "$RECEIVER_NAMES" ]] \
    || die "flavor '${FLAVOR}' produced no receivers at all — the config would collect nothing"

  log "receivers: ${RECEIVER_NAMES// /, }"

  # ---- processors and exporters ----
  # exporter.yaml is spliced WHOLE and UNINDENTED: unlike a receiver fragment it
  # declares two top-level keys of its own, `processors:` and `exporters:`. It
  # needs no name header — the pipelines below reference its components by name
  # directly, because they are hand-written.
  EXPORTER_BLOCK="$(fragment_body "$EXPORTER_SRC")"
  CONFIG_LABEL="vm:${VM}"
  log "processors + exporters: ${CONFIG_LABEL}"

  # ---- splice ----
  # awk, not sed: the blocks are multi-line, and sed's handling of newlines in a
  # replacement is a portability trap not worth stepping in.
  #
  # MATCHING IS ANCHORED, and that is load-bearing. Every pipeline.yaml opens
  # with a header that names all of these tokens in prose. An unanchored
  # /@EXPORTER@/ matched that comment too and printed the whole exporter block
  # into the header — a bare mapping above the first real key, so the rendered
  # config was invalid YAML. The leftover check below could not see it either,
  # because both occurrences had been consumed. So: blocks are spliced only on a
  # line that is nothing but the placeholder, and comment lines pass through
  # untouched.
  # @PROJECT@ is substituted into the SPLICED BLOCKS TOO, in BEGIN, not only
  # into pipeline.yaml's own lines. The exporter block is where the token
  # actually earns its keep — both Pub/Sub topics and host.project are in it —
  # and a block that is printed whole never reaches the per-line rule below.
  awk -v recv="$RECEIVER_BLOCK" -v expo="$EXPORTER_BLOCK" -v proj="$PROJECT" '
    BEGIN { gsub(/@PROJECT@/, proj, recv); gsub(/@PROJECT@/, proj, expo) }
    /^[[:space:]]*@RECEIVERS@[[:space:]]*$/ { print recv; next }
    /^[[:space:]]*@EXPORTER@[[:space:]]*$/  { print expo; next }
    /^[[:space:]]*#/                        { print; next }
    { gsub(/@PROJECT@/, proj); print }
  ' "$PIPELINE_SRC" > "$RENDERED"

  # ---- check the hand-written pipelines against what was actually assembled --
  #
  # THIS IS THE CHECK THAT REPLACED @RECEIVER_NAMES@. While the pipeline list
  # was generated it could not disagree with the receivers map; now that it is
  # written by hand it can, in both directions, and both are silent:
  #
  #   named but not assembled -> otelcol refuses to start, and apply.sh can no
  #                              longer tell that apart from any other failure
  #                              now that the health endpoint is gone
  #   assembled but not named -> the collector starts, reports nothing wrong,
  #                              and that receiver's logs are simply never sent
  #
  # Pipeline lists are the only `receivers:` in the file with a bracket after
  # them; the top-level map key has none. That is what separates them here.
  # tr at the end is load-bearing, not tidying: the membership tests below are
  # `case " $list " in *" $name "*`, which needs a SPACE either side of every
  # entry. Leave this newline-separated and every name but the last fails to
  # match, so every receiver is reported unused.
  PIPELINE_RECEIVERS="$(grep -o '^[[:space:]]*receivers:[[:space:]]*\[[^]]*\]' "$RENDERED" \
    | sed 's/.*\[//; s/\]//; s/,/ /g' | tr '\n' ' ')"

  for NAME in $PIPELINE_RECEIVERS; do
    case " ${RECEIVER_NAMES} " in
      *" ${NAME} "*) ;;
      *) die "a pipeline names receiver '${NAME}', which flavor '${FLAVOR}' does not provide (check ${PIPELINE_SRC} against ../systems/)" ;;
    esac
  done

  # Unused is a warning, not an error: it is how a host legitimately looks
  # mid-change, and refusing the push would block the very edit that fixes it.
  for NAME in $RECEIVER_NAMES; do
    case " ${PIPELINE_RECEIVERS} " in
      *" ${NAME} "*) ;;
      *) log "WARNING: receiver '${NAME}' is assembled but no pipeline uses it — it will collect nothing" ;;
    esac
  done
fi

# Comments are excluded: the headers legitimately name the tokens and must not
# trip this. Only a placeholder left in actual YAML is a failure.
if grep -v '^[[:space:]]*#' "$RENDERED" | grep -q '@[A-Z_]*@'; then
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

log "done: ${INSTANCE} (${FLAVOR}) -> ${CONFIG_LABEL}"
