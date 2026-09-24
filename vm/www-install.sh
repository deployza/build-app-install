#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# www-install.sh — ORCHESTRATOR for the www.deployza.com host. This is the
# <APP_NAME>.sh that is PUSHED to the VM and run there
# (APP_NAME="www-install"). It does NOT deploy anything itself; it installs
# every app that belongs on this VM by invoking, in order:
#
#   1. www-website.sh    www.deployza.com            the marketing site
#                                                    (per-HOST site, site.d)
#   2. www-apidocs.sh    www.deployza.com/api-docs/  the MkDocs API docs
#                                                    (per-PATH app, app.d)
#
# Same shape as assess-install.sh — see that file for the pattern this follows.
#
# WHY TWO CHILDREN RATHER THAN ONE SCRIPT. These two used to be a single
# www-website.sh. They share a hostname and nothing else: the site is a WAR
# pulled from GCS and unzipped, the docs are a git checkout built on this VM by
# a systemd unit; a site release and a docs commit are unrelated events. Keeping
# them separate means either can be redeployed on its own (`sudo bash
# www-apidocs.sh production`) without touching the other, and each owns exactly
# one nginx file.
#
# ORDERING IS NOT LOAD-BEARING, but it is not arbitrary either. The site script
# writes the host's server{} block, which carries `include
# /etc/nginx/app.d/*.conf;` — the line that makes the docs' drop-in resolve on
# this hostname. nginx resolves that include at reload time, not at write time,
# so the docs drop-in does not have to exist first. Running the site first
# anyway means every reload along the way tests a complete config, and a first
# boot never has a window where www.deployza.com itself is unreachable. Both
# children create /etc/nginx/app.d/ if the image did not, so neither depends on
# the other having run.
#
# If any child fails, `set -e` aborts the whole run (a partial deploy is
# surfaced rather than hidden). Note that a failed DOCS BUILD is deliberately
# not a child failure — www-apidocs.sh logs it and still exits 0, so a
# transient network/secret/mkdocs problem never takes this host's deploy down.
# See refresh_docs_now in that script.
#
# Contract: invoked as `www-install.sh APP_ENV`.
# APP_NAME is fixed to "www-install" here (the pusher resolves this file by
# that name — <clone>/vm/www-install.sh); the single argument is APP_ENV, which
# is passed through verbatim to every child.
#
# Logs — like the child scripts, this only echoes to stdout/stderr. At boot its
# output (and the children's) goes wherever the pusher ran it — there is no
# systemd unit and no journal of its own.
# Run manually over SSH:
#   sudo bash www-install.sh <APP_ENV> 2>&1 | tee /tmp/www-install.log
# -----------------------------------------------------------------------------

# Directory this script lives in, so the children are found regardless of CWD
# (the pusher ships vm/ to /tmp/deployza/repo and runs us from there).
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The child deploy scripts, run in this order. See the header for why the site
# goes first.
readonly CHILD_SCRIPTS=(
  "www-website.sh"
  "www-apidocs.sh"
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
  echo "www-install orchestrator: deploying the site + API docs (${app_env})"
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
    # a child stays runnable standalone (`./www-website.sh`), mirroring the +x
    # the pusher applies to this orchestrator.
    chmod +x "$child_path" 2>/dev/null || true

    echo
    echo "--- Running ${child} (${app_env}) ---------------------------"
    run_child "$child_path" "$app_env"
    echo "--- Finished ${child} ---------------------------------------"
  done

  echo
  echo "Site and API docs deployed."
}

main "$@"
