#!/bin/bash
# apply.sh — TARGET-SIDE. Runs ON the VM, as root, after push.sh has unpacked
# this directory there. It never runs at boot and nothing on the VM invokes it.
#
#   sudo /opt/otel/apply.sh <rendered-config.yaml> [env-file]
#
# It swaps /etc/otelcol/config.yaml for the config it is handed, restarts the
# collector, and rolls back if the restarted collector does not STAY up. That is
# the whole job.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#
#   * No git clone, no download, no polling. The config arrives with the push.
#     See ../../../build-docs/ops-execution.md — nothing on a VM pulls.
#   * No probing of what is installed. The pusher already knows which flavor it
#     targeted; detection here would be a second, drifting source of truth.
#   * No `otelcol validate`. That is a schema check on a config the pusher
#     already rendered and (where the binary was available) already validated;
#     re-running it here would only re-answer a question asked upstream. It
#     cannot see a missing log dir, a bad credential or a busy port anyway —
#     the post-restart settle window below catches a collector that dies of any
#     of them, and those are the failures that actually happen on a target.
set -euo pipefail

log() { echo "[otel-apply] $*"; }
die() { echo "[otel-apply] ERROR: $*" >&2; exit 1; }

readonly OTELCOL_BIN=/opt/otelcol/bin/otelcol-contrib
readonly CONF=/etc/otelcol/config.yaml
readonly ENVFILE=/etc/otelcol/env
readonly BACKUP_DIR=/etc/otelcol/backup

# How long the collector must STAY up after a restart before we call the push
# good. See the verify step below for why this is a settle window rather than a
# poll: there is no health endpoint to poll any more.
readonly SETTLE_SECONDS=15

NEW_CONFIG="${1:-}"
NEW_ENVFILE="${2:-}"

[[ $EUID -eq 0 ]]          || die "must run as root (writes /etc/otelcol, restarts a unit)"
[[ -n "$NEW_CONFIG" ]]     || die "usage: apply.sh <config.yaml> [env-file]"
[[ -f "$NEW_CONFIG" ]]     || die "config not found: $NEW_CONFIG"
[[ -x "$OTELCOL_BIN" ]]    || die "collector not installed at $OTELCOL_BIN — is this an image with install-otel.sh?"


# -----------------------------------------------------------------------------
# Group membership
# -----------------------------------------------------------------------------
# THE SINGLE MOST COMMON SILENT FAILURE. Without these the receiver gets EACCES
# on its log source, says so exactly once at startup, and then looks perfectly
# healthy forever while shipping nothing. The settle window below will NOT catch
# it: the collector is genuinely fine, it just cannot read anything.
#
# Attempted unconditionally, guarded by `getent`, rather than driven by the
# flavor: adding otelcol to a group that exists is idempotent and harmless, and
# a list that has to be kept in step with the config is a list that will drift.
#
# `adm` is the conventional "may read /var/log" group and is exactly what a log
# collector is for; `systemd-journal` is required by the journald receiver on
# every flavor; `tomcat` is only present where Tomcat is.
#
# Supplementary groups are read at process start, so this must precede the
# restart below — which it does.
for grp in systemd-journal adm tomcat; do
  if getent group "$grp" >/dev/null 2>&1; then
    if ! id -nG otelcol 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
      log "adding otelcol to group ${grp}"
      usermod -aG "$grp" otelcol
    fi
  fi
done


# -----------------------------------------------------------------------------
# Back up, then swap
# -----------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
BACKUP="${BACKUP_DIR}/config.yaml.$(date -u +%Y%m%dT%H%M%SZ)"

if [[ -f "$CONF" ]]; then
  cp -p "$CONF" "$BACKUP"
  log "backed up current config to ${BACKUP}"
else
  # No live config at all. Nothing to roll back TO, so record that explicitly
  # rather than letting the rollback path silently restore nothing.
  BACKUP=""
  log "no existing ${CONF} — first apply on this host"
fi

# Keep the last 10 backups. This directory is on the root disk and a config is a
# few KB, but an unbounded dir written by every deploy is how /etc grows hair.
# shellcheck disable=SC2012
ls -1t "${BACKUP_DIR}"/config.yaml.* 2>/dev/null | tail -n +11 | xargs -r rm -f

install -o root -g otelcol -m 640 "$NEW_CONFIG" "$CONF"
log "installed new config"

# The env file used to carry the exporter endpoint and its credentials. NOTHING
# THE TREE RENDERS TODAY REFERENCES ${env:} AT ALL: Pub/Sub authenticates with
# the VM's attached service account, service.name is stamped per pipeline, and
# deployment.environment is no longer sent. The flag and this block survive for
# a config that needs one again; absent is the normal case.
if [[ -n "$NEW_ENVFILE" ]]; then
  [[ -f "$NEW_ENVFILE" ]] || die "env file not found: $NEW_ENVFILE"
  install -o root -g otelcol -m 640 "$NEW_ENVFILE" "$ENVFILE"
  log "installed exporter environment"
fi


# -----------------------------------------------------------------------------
# Restart and verify
# -----------------------------------------------------------------------------
# RESTART, NOT RELOAD. The collector does not reliably reload on SIGHUP, and
# otelcol.service deliberately declares no ExecReload — a reload here would be a
# way to silently apply nothing.
rollback() {
  log "rolling back"
  if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
    install -o root -g otelcol -m 640 "$BACKUP" "$CONF"
    systemctl restart otelcol.service || true
    log "restored previous config from ${BACKUP}"
  else
    log "NO BACKUP TO RESTORE — collector left stopped, config left in place for inspection"
    log "  the bad config is at ${CONF}"
  fi
}

log "restarting otelcol"
if ! systemctl restart otelcol.service; then
  log "restart FAILED"
  journalctl -u otelcol.service -n 30 --no-pager || true
  rollback
  die "collector failed to restart; previous state restored where possible"
fi

# THIS CHECK IS WEAKER THAN IT USED TO BE, AND DELIBERATELY SO. It polled the
# health_check extension on 127.0.0.1:13133; the configs no longer declare any
# extensions, so there is nothing to poll and this falls back to systemd.
#
# WHAT THAT COSTS: `systemctl restart` returns as soon as the process is up,
# BEFORE otelcol has parsed its config and built its pipelines. A config that is
# valid YAML but names a component that does not exist starts, fails, and exits
# a second or two later. So a single is-active immediately after the restart
# would call almost any broken config a success.
#
# Hence a SETTLE WINDOW rather than a poll: the unit must be active continuously
# for SETTLE_SECONDS. That catches a collector that starts and then dies, which
# is the failure the config changes actually produce.
#
# WHAT IT STILL DOES NOT CATCH, and the health endpoint did not either: a
# collector that comes up perfectly and ships nothing, because a receiver got
# EACCES on its log source. Only the journal shows that — see the closing note.
log "waiting ${SETTLE_SECONDS}s for the collector to settle"
settled=true
for _ in $(seq "$SETTLE_SECONDS"); do
  if ! systemctl is-active --quiet otelcol.service; then
    log "unit went inactive during the settle window"
    settled=false
    break
  fi
  sleep 1
done

if [[ "$settled" != true ]]; then
  log "collector did not stay up for ${SETTLE_SECONDS}s"
  journalctl -u otelcol.service -n 30 --no-pager || true
  rollback
  die "collector did not stay up; previous state restored where possible"
fi


# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
log "collector up and stable for ${SETTLE_SECONDS}s"
log "config:  ${CONF}"
log "  $(head -n 1 "$CONF")"
log "groups:  $(id -nG otelcol)"
log "pipelines:"
grep -A2 '^  pipelines:' "$CONF" | sed 's/^/  /' || true

# A healthy collector reading NOTHING looks identical from out here to one
# shipping millions of lines. Point at the one place that tells them apart.
log ""
log "Up does not mean shipping. Verify with:"
log "  sudo journalctl -u otelcol -b | grep -i 'error\\|permission\\|denied'"
exit 0
