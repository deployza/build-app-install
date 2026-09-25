#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# vm/mcp-vm/install-otel.sh — install this folder's collector config, otel.yaml.
#
#   sudo bash vm/mcp-vm/install-otel.sh [--inert]    install it
#   bash vm/mcp-vm/install-otel.sh --check            validate only, touch nothing
#
# EVERY VM FOLDER HAS ITS OWN COPY, so each folder is self-contained. The
# copies are identical today; a fix to one is a fix to all of them. THE FOLDER
# IS THE HOST: this script installs the otel.yaml beside it, and refuses to do
# so on a machine whose short hostname is not the folder's host: the folder
# name, or the name in an `instance` file beside this script when the two
# differ (vm/mcp-vm/ is host `mcp`).
#
# THE CONFIG IS NOT ASSEMBLED. Each vm/<vm>/otel.yaml is the complete file —
# receivers, processors, exporters, service — and is installed verbatim. This
# replaced render.sh (which concatenated per-server receiver fragments with a
# per-VM exporter.yaml and pipeline.yaml) on 2026-09-25.
#
# WHAT THIS HAS TO GET RIGHT, in order:
#
#   1. otelcol's supplementary groups, BEFORE the restart. THE NUMBER ONE
#      SILENT FAILURE: without the group a receiver gets EACCES on a log dir,
#      says so once at startup, then looks healthy forever while shipping
#      nothing. Groups are read at process start, which is why this happens
#      here, immediately before the restart that picks them up.
#   2. Validate before swapping, against /opt/otelcol/bin/otelcol-contrib — the
#      pinned binary the fleet actually runs. A config it rejects never reaches
#      /etc/otelcol.
#   3. host.project in otel.yaml must match the project this host is really in
#      (metadata server). A mismatch stamps every record with the wrong project:
#      bad data that looks fine downstream.
#   4. Back up, swap, RESTART (never reload — no ExecReload on purpose), then
#      wait SETTLE_SECONDS and check the unit is STILL up: `systemctl restart`
#      returns before otelcol parses its config, so a bad config dies a second
#      or two after "success". If it did not hold, restore the backup.
#
# --inert installs the inert.yaml beside this script instead — collect nothing,
# send nowhere — through the same path (the off switch). So does a folder with
# no otel.yaml.
#
# NO SECRETS PASS THROUGH HERE. Pub/Sub authenticates with the VM's attached
# service account, so the config is safe at 0640 root:otelcol.
# -----------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly OTEL_CONF="/etc/otelcol/config.yaml"
readonly OTEL_BACKUP_DIR="/etc/otelcol/backup"
readonly OTEL_BACKUP="${OTEL_BACKUP_DIR}/config.yaml"
readonly OTEL_SERVICE="otelcol"
readonly OTEL_USER="otelcol"
# Pinned at bake, installed from a tarball — deliberately on nobody's PATH.
readonly OTELCOL_BIN="/opt/otelcol/bin/otelcol-contrib"

# Every group otelcol may need to read a log source, added where it exists:
#   systemd-journal  the journald receiver (every host)
#   adm              /var/log/nginx, /var/log/mysql
#   tomcat           /home/tomcat/instance/logs
# A group absent from this image means the image does not run that server —
# not an error.
readonly OTEL_GROUPS=(systemd-journal adm tomcat)

# HOW LONG THE UNIT MUST STAY UP before the install is called a success. Not
# padding — see (4) above.
readonly SETTLE_SECONDS="${SETTLE_SECONDS:-15}"

log()  { echo "[otel] $*"; }
warn() { echo "[otel] WARNING: $*" >&2; }
die()  { echo "[otel] ERROR: $*" >&2; exit 1; }

VM=""; FORCE_INERT=false; CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)    VM="$2"; shift 2 ;;
    --inert) FORCE_INERT=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    *) die "unknown argument: $1 (usage: $0 [--vm NAME] [--inert] [--check])" ;;
  esac
done
# THE FOLDER IS THE HOST: its host name — the GCE instance name, the short
# hostname and the Ansible inventory key — is the folder name, or the contents
# of an `instance` file in the folder when they differ. --vm is Ansible saying
# which host it thinks it is talking to; it must agree with the folder this
# script sits in.
readonly FOLDER="$(basename "$SCRIPT_DIR")"
if [[ -f "${SCRIPT_DIR}/instance" ]]; then
  FOLDER_VM="$(tr -d '[:space:]' < "${SCRIPT_DIR}/instance")"
  [[ -n "$FOLDER_VM" ]] || die "vm/${FOLDER}/instance is empty"
else
  FOLDER_VM="$FOLDER"
fi
readonly FOLDER_VM
[[ -z "$VM" || "$VM" == "$FOLDER_VM" ]] \
  || die "vm/${FOLDER}/ is host ${FOLDER_VM}'s, not ${VM}'s — run ${VM}'s folder's install-otel.sh"
VM="$FOLDER_VM"

# ---------------------------------------------------------------------------

pick_config() {
  if [[ "$FORCE_INERT" == true ]]; then
    log "using INERT on request (--inert)" >&2
    echo "${SCRIPT_DIR}/inert.yaml"
  elif [[ -f "${SCRIPT_DIR}/otel.yaml" ]]; then
    echo "${SCRIPT_DIR}/otel.yaml"
  else
    log "no vm/${FOLDER}/otel.yaml — using INERT (collect nothing, send nowhere)" >&2
    echo "${SCRIPT_DIR}/inert.yaml"
  fi
}

# Best-effort: a workstation has no metadata server, and that is "unchecked",
# not a failure.
metadata_project() {
  curl -fsS -m 5 -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/project/project-id' 2>/dev/null || true
}

check_project() {
  local config="$1" declared actual
  # `|| true`: no match (inert.yaml) is an answer, not a pipefail exit.
  declared="$( { grep -A1 'key: host.project' "$config" || true; } \
    | sed -n 's/^[[:space:]]*value:[[:space:]]*//p' | head -n1 | tr -d '"')"
  [[ -n "$declared" ]] || return 0    # inert.yaml stamps nothing
  actual="$(metadata_project)"
  if [[ -z "$actual" ]]; then
    warn "no metadata server — host.project '${declared}' is unchecked"
  elif [[ "$declared" != "$actual" ]]; then
    die "project mismatch: ${config} declares host.project '${declared}' but this host is in '${actual}'"
  else
    log "host.project ${declared} matches this host"
  fi
}

validate() {
  local config="$1" bin="$OTELCOL_BIN"
  [[ -x "$bin" ]] || bin="$(command -v otelcol-contrib || true)"
  if [[ -z "$bin" ]]; then
    # Refused on a real install, tolerated for --check on a workstation.
    [[ "$CHECK_ONLY" == true ]] || die "no ${OTELCOL_BIN} — this image has no collector, or refusing an unvalidated config"
    warn "otelcol-contrib not found — config is UNVALIDATED"
    return 0
  fi
  "$bin" validate --config "$config" || die "${config} failed otelcol-contrib validate"
  log "validate passed ($("$bin" --version 2>/dev/null | head -n1))"
}

ensure_groups() {
  id -u "$OTEL_USER" >/dev/null 2>&1 || die "no ${OTEL_USER} user — was this image baked without install-otel.sh?"
  local g
  for g in "${OTEL_GROUPS[@]}"; do
    # usermod -aG is idempotent.
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$OTEL_USER"
  done
  log "${OTEL_USER} groups: $(id -nG "$OTEL_USER" | tr ' ' ',')"
}

restore_backup() {
  warn "restoring the previous config from ${OTEL_BACKUP}"
  install -o root -g otelcol -m 640 "$OTEL_BACKUP" "$OTEL_CONF"
  systemctl restart "$OTEL_SERVICE" || true
}

apply() {
  local config="$1"

  install -d -o root -g otelcol -m 750 "$OTEL_BACKUP_DIR"
  install -o root -g otelcol -m 640 "$OTEL_CONF" "$OTEL_BACKUP"
  log "backed up the live config to ${OTEL_BACKUP}"

  install -o root -g otelcol -m 640 "$config" "$OTEL_CONF"
  log "installed vm/${FOLDER}/${config##*/} as ${OTEL_CONF}"

  systemctl restart "$OTEL_SERVICE"
  log "restarted ${OTEL_SERVICE}; waiting ${SETTLE_SECONDS}s to see whether it holds"
  sleep "$SETTLE_SECONDS"

  if systemctl is-active --quiet "$OTEL_SERVICE"; then
    log "${OTEL_SERVICE} is active after ${SETTLE_SECONDS}s"
    return 0
  fi

  echo >&2
  warn "${OTEL_SERVICE} did not stay up. Last 40 journal lines:"
  journalctl -u "$OTEL_SERVICE" -n 40 --no-pager >&2 || true
  echo >&2
  restore_backup
  die "the new collector config did not hold; the previous one has been restored"
}

main() {
  local config
  config="$(pick_config)"

  echo
  echo "==============================================================="
  echo "  otel: ${VM} <- vm/${FOLDER}/${config##*/}$([[ "$CHECK_ONLY" == true ]] && echo ' (check only)')"
  echo "==============================================================="

  if [[ "$CHECK_ONLY" == true ]]; then
    check_project "$config"
    validate "$config"
    log "check passed; nothing installed."
    return 0
  fi

  [[ "$(id -u)" -eq 0 ]] || die "must run as root (use sudo)"
  # When the hostname chose the config, a wrong host could only ever get
  # inert.yaml. Now the folder decides, so a script run from the wrong folder
  # would install another host's pipelines here — refuse that. (--check, above,
  # stays usable from a workstation.)
  [[ "$(hostname -s)" == "$VM" ]] \
    || die "this host is '$(hostname -s)', but vm/${FOLDER}/ is host ${VM}'s — run this host's folder's install-otel.sh"
  [[ -f "$OTEL_CONF" ]] || die "no ${OTEL_CONF} — this image has no collector (install-otel.sh did not run at bake)"

  check_project "$config"
  validate "$config"
  ensure_groups
  apply "$config"
  log "done."
}

main "$@"
