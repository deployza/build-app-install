#!/bin/bash
set -euo pipefail

# TEMPORARY: this installer is disabled — do nothing and return successfully.
# Remove this block to restore the original behaviour (everything below is intact).
# echo "instances/ziniapps-vm/install.sh: temporarily disabled, skipping install."
# exit 0

# -----------------------------------------------------------------------------
# instances/ziniapps-vm/install.sh — ORCHESTRATOR for the ziniapps-vm host. This is
# the script the pusher ships and runs (APP_NAME="assess-install"). It does NOT
# deploy anything itself; it installs every app that belongs on this VM by
# invoking, in order:
#
#   1. assess/assess-server.sh      the assess backend WAR (DB + app.properties
#                                   + logback)
#   2. assess/assess-ui.sh          the static UI WAR
#   3. assess/assess-exam.sh        the exam WAR
#   4. ziniapps/ziniapps-go.sh      go.ziniapps.com   landing page  (per-HOST)
#   5. ziniapps/ziniapps-www.sh     www.ziniapps.com  marketing site (per-HOST)
#
# The children are grouped by PRODUCT, not by which VM they land on: the three
# assess apps sit beside us in vm/assess/, the two sites in vm/ziniapps/. This
# host happens to run both, so the child list crosses a folder — see
# CHILD_SCRIPTS below, where the paths are relative to this script's dir.
#
# Each child is a self-contained deploy script with its own install.properties
# and GCS artifacts. The first three are per-PATH apps sharing the live Tomcat
# and the image's default nginx server block, so each hot-deploys its own
# context (/<ctx>) without touching the others. The last two are per-HOST static
# sites: they serve a domain root via their own nginx server block in
# /etc/nginx/site.d/ rather than a path prefix in /etc/nginx/app.d/.
#
# ORDERING IS LOAD-BEARING for the two site scripts, though only in one
# direction: ziniapps/ziniapps-go.sh's server block does `include /etc/nginx/app.d/*.conf`
# so that go.ziniapps.com keeps serving /assess-ui/ etc. That include is resolved
# by nginx at reload time, not at write time, so the assess drop-ins do not
# strictly have to exist first — but running the per-path apps before the sites
# means every reload along the way tests a complete config, and a first boot
# never has a window where go.ziniapps.com/assess-ui/ 404s.
#
# Contract: invoked as `instances/ziniapps-vm/install.sh APP_ENV`.
# APP_NAME is fixed to "assess-install" here (the pusher resolves this file by
# that name — <clone>/vm/instances/ziniapps-vm/install.sh); the single argument is
# APP_ENV, which is passed through verbatim to every child.
#
# Ordering: the backend goes first so its DB/context are in place before the UI
# and exam apps come up; the two ziniapps sites go last (see above). If any child
# fails, `set -e` aborts the whole run (a partial deploy is surfaced rather than
# hidden).
#
# Logs — like the child scripts, this only echoes to stdout/stderr. At boot its
# output (and the children's) goes wherever the pusher ran it — there is no
# systemd unit and no journal of its own.
# Run manually over SSH:
#   sudo bash instances/ziniapps-vm/install.sh <APP_ENV> 2>&1 | tee /tmp/assess.log
# -----------------------------------------------------------------------------

# Directory this script lives in, so the children are found regardless of CWD
# (the pusher ships vm/ to /tmp/deployza/repo and runs us from there).
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The child deploy scripts, run in this order, as paths RELATIVE TO SCRIPT_DIR
# (vm/instances/ziniapps-vm/). Every app lives under vm/apps/<app>/, one folder per
# app, so each child is reached as ../../apps/<app>/<app>.sh. The first three
# are per-PATH apps (Tomcat contexts + app.d location blocks); the last two are
# per-HOST static sites (site.d server blocks). See the header for why the sites
# come last. The whole vm/ tree is shipped together, so the ../.. costs nothing
# at deploy time.
#
# NOT IN THIS LIST: hundi-ui. vm/apps/hundi-ui/ exists and this host is where it
# is meant to run, but it has never been in the install order and adding it is a
# deploy change, not a reorganisation. Add it deliberately.
readonly CHILD_SCRIPTS=(
  "../../apps/assess-server/assess-server.sh"
  "../../apps/assess-ui/assess-ui.sh"
  "../../apps/assess-exam/assess-exam.sh"
  "../../apps/ziniapps-go/ziniapps-go.sh"
  "../../apps/ziniapps-www/ziniapps-www.sh"
)

# Per-child log dir (a sibling of the clone under the deploy root:
# /tmp/deployza/repo is the clone, /tmp/deployza/logs is ours). This orchestrator
# does NOT keep a log file of its own — its output goes straight to stdout/stderr
# so the pusher's own output captures the whole run. What the log
# dir is for is a per-child FILE copy for manual inspection: each child's output
# is tee'd to both stdout (→ journald) and ${LOG_DIR}/<basename>.log (see
# run_child). The child scripts know NOTHING about logging — they just echo.
readonly LOG_DIR="/tmp/deployza/logs"

# Whether a usable log dir exists (set by init_logging). When false, children run
# unredirected — output still reaches stdout/journald, just without the file copy,
# so a log-dir failure never blocks a deploy.
LOGGING=false

# init_logging: create the shared log dir once, best-effort. We deliberately do
# NOT redirect this orchestrator's own stdout/stderr — journald is its log sink.
# If the dir can't be created we warn and leave LOGGING=false rather than aborting
# under `set -e`.
init_logging() {
  if mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOGGING=true
  else
    echo "WARNING: could not create ${LOG_DIR}; child file logs disabled (stdout only)." >&2
  fi
}

# run_child: invoke one child deploy script with APP_ENV, tee'ing its combined
# stdout+stderr to BOTH stdout (so it flows to journald like everything else) and
# that child's own file (${LOG_DIR}/<basename>.log) for manual inspection. Falls
# back to a plain (unredirected) run when the log dir is unavailable.
# `bash "$child_path"` needs only read permission, so the execute bit is not
# load-bearing; we do not chmod the child here.
run_child() {
  local child_path="$1" app_env="$2"
  if [[ "$LOGGING" == true ]]; then
    local child_log="${LOG_DIR}/$(basename "${child_path%.sh}").log"
    bash "$child_path" "$app_env" 2>&1 | tee -a "$child_log"
  else
    bash "$child_path" "$app_env"
  fi
}

# parse_args: validate the caller's contract and echo APP_ENV.
# APP_ENV is required — refuse to run without it rather than deploying to a
# wrong default environment.
parse_args() {
  local app_env="${1:-}"
  if [[ -z "$app_env" ]]; then
    echo "ERROR: APP_ENV is required." >&2
    echo "Usage: $0 APP_ENV" >&2
    exit 1
  fi
  printf '%s' "$app_env"
}

main() {
  local app_env
  app_env="$(parse_args "$@")"
  init_logging          # create ${LOG_DIR}; per-child output is teed in run_child

  echo "==============================================================="
  echo "assess-install orchestrator: deploying all apps + sites (${app_env})"
  echo "==============================================================="

  local child
  for child in "${CHILD_SCRIPTS[@]}"; do
    local child_path="${SCRIPT_DIR}/${child}"
    if [[ ! -f "$child_path" ]]; then
      echo "ERROR: child deploy script missing: $child_path" >&2
      exit 1
    fi

    # We invoke children via `bash "$child_path"` (in run_child), which needs only
    # read permission — the execute bit is not load-bearing here. Set it anyway so
    # a child stays runnable standalone (`./apps/assess-server/assess-server.sh`), mirroring the +x
    # the pusher applies to this orchestrator.
    chmod +x "$child_path" 2>/dev/null || true

    echo
    echo "--- Running ${child} (${app_env}) ---------------------------"
    run_child "$child_path" "$app_env"
    echo "--- Finished ${child} ---------------------------------------"
  done

  echo
  echo "All apps and sites deployed."
}

main "$@"
