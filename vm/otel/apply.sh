#!/bin/bash
# apply.sh — TARGET-SIDE. Runs ON the VM, as root, after push.sh has unpacked
# this directory there. It never runs at boot and nothing on the VM invokes it.
#
#   sudo /opt/otel/apply.sh <rendered-config.yaml> [env-file]
#
# It swaps /etc/otelcol/config.yaml for the config it is handed, restarts the
# collector, and rolls back if the restarted collector does not come up healthy.
# That is the whole job.
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
#     the post-restart health check below catches all three, and those are the
#     failures that actually happen on a target.
set -euo pipefail

log() { echo "[otel-apply] $*"; }
die() { echo "[otel-apply] ERROR: $*" >&2; exit 1; }

readonly OTELCOL_BIN=/opt/otelcol/bin/otelcol-contrib
readonly CONF=/etc/otelcol/config.yaml
readonly ENVFILE=/etc/otelcol/env
readonly BACKUP_DIR=/etc/otelcol/backup
readonly HEALTH_URL=http://127.0.0.1:13133

# How long to wait for the collector to report healthy after a restart. It has
# to open its exporters (which may do a TLS handshake against ELK or ClickHouse)
# before the health endpoint answers, so this is seconds, not milliseconds.
readonly HEALTH_TIMEOUT=30

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
# healthy forever while shipping nothing. The health check below will NOT catch
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

# The env file carries the exporter endpoint and its credentials, referenced
# from the config as ${env:OTEL_*}. 640 root:otelcol — the collector reads it,
# nobody else does. Absent is legal: a config with no ${env:} references (the
# inert base, or a local-only pipeline) needs none.
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

# Poll the health_check extension. Every config we push declares it on
# 127.0.0.1:13133 — see otelcol-base.yaml in build-vm-images. A config that
# omits it will be rolled back here even if it is perfectly good, which is the
# intended trade: we will not leave a box in a state we cannot confirm.
log "waiting up to ${HEALTH_TIMEOUT}s for health endpoint"
healthy=false
for _ in $(seq "$HEALTH_TIMEOUT"); do
  # The unit dying mid-wait is a definite answer; stop waiting for the timeout.
  if ! systemctl is-active --quiet otelcol.service; then
    log "unit went inactive while waiting"
    break
  fi
  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 1
done

if [[ "$healthy" != true ]]; then
  log "health check FAILED after ${HEALTH_TIMEOUT}s"
  journalctl -u otelcol.service -n 30 --no-pager || true
  rollback
  die "collector did not become healthy; previous state restored where possible"
fi


# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
log "collector healthy"
log "config:  ${CONF}"
log "  $(head -n 1 "$CONF")"
log "groups:  $(id -nG otelcol)"
log "pipelines:"
grep -A2 '^  pipelines:' "$CONF" | sed 's/^/  /' || true

# A healthy collector reading NOTHING looks identical from out here to one
# shipping millions of lines. Point at the one place that tells them apart.
log ""
log "Healthy does not mean shipping. Verify with:"
log "  sudo journalctl -u otelcol -b | grep -i 'error\\|permission\\|denied'"
exit 0
