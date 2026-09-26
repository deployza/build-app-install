#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# mcp.sh — app deploy script for the Deployza MCP server (mcp.deployza.com): the
# graphify knowledge-graph server, the OAuth gateway in front of it, and the
# hourly refresh that keeps the graph current.
#
# THE IMAGE BAKES ONLY THE RUNTIME. build-vm-images' `mcp` flavor
# (install-mcp.sh) puts down /opt/mcp/venv — graphify with every tree-sitter
# grammar, and fastmcp — and nothing else. Everything that makes that venv the
# Deployza MCP server is installed here, from the files in ./mcp/ beside this
# script:
#
#   /etc/mcp/mcp.env                  every tunable (paths, ports, domain,
#                                     secret ids, org, excludes)
#   /usr/local/bin/<helper>           gcp-secret, mcp-serve, mcp-auth,
#                                     mcp-refresh, mcp-md-graph, mcp-git-askpass,
#                                     mcp-log-failure, mcp-boot
#   /usr/local/bin/<module>.py        mcp_auth_app.py (the gateway),
#                                     mcp_md_extract.py (vendored, Apache-2.0)
#   /etc/sudoers.d/mcp                the one privileged command the refresh needs
#   /etc/systemd/system/<unit>        mcp-boot, mcp, mcp-auth, mcp-refresh(.timer),
#                                     mcp-refresh-failed
#
# plus the unprivileged `mcp` system user. Until image 1-3 all of this was baked,
# so changing one line of mcp.env meant a rebake and a VM replacement — which
# throws away /data (the graph, the clones, the OAuth token store) and signs
# everyone out. Now it is a push:
#
#   ansible-playbook playbooks/mcp-vm.yml --tags mcp
#   sudo bash vm/mcp-vm/install.sh production mcp          (on the box)
#
# What this script does, in order:
#   1. checks the runtime the image must provide           (require_runtime)
#   2. PRE-FLIGHT, touching nothing on the host:            (preflight)
#        - the gateway imports cleanly against the baked fastmcp
#        - the vendored Markdown extractor still matches the baked graphify
#        - the sudoers drop-in parses
#      These were bake-time checks while the code was baked. They run against
#      the files in ./mcp/, so a bad push fails HERE with the old install still
#      serving, not after it has been overwritten.
#   3. creates the `mcp` user if missing                    (ensure_user)
#   4. installs the files above, each by atomic rename      (install_files)
#   5. enables the units                                    (enable_units)
#   6. provisions /data and applies any new migration        (provision_data)
#   7. restarts the server and the gateway, starts the timer (start_services)
#   8. waits, and fails if the gateway did not stay up      (verify_gateway)
#
# A FRESH VM (booted from an image that bakes no app) serves nothing until this
# has run once. From then on it needs nothing at boot: the units are enabled and
# express the whole boot sequence themselves (mcp-boot -> mcp + mcp-auth, and
# the timer's OnBootSec=2min refresh). A brand-new VM's first graph takes ~12 min;
# /healthz answers 503 until then, which is the designed path.
#
# NO ROLLBACK, unlike install-otel.sh. Pre-flight is the guard: it catches the
# failures a version skew can cause before anything is replaced. A failure after
# that point (a missing secret, most likely) is reported with the unit's journal
# and fixed forward.
#
# Contract: invoked as `mcp.sh APP_ENV`. APP_ENV is required but selects NOTHING,
# as in www-apidocs.sh: there is one MCP server, it reads no GCS artifact, and its
# configuration is ./mcp/mcp.env. It stays mandatory so this script obeys the same
# contract as every other unit.
#
# Requires the `mcp` image (family dz-mcp, build-vm-images/images/ubuntu/mcp/): the venv, plus
# git, jq, curl and gcloud from the baseline installers. Also works on an image
# that predates 1-3 — those bake the same venv, and this overwrites their baked
# copies of the files above in place.
#
# Logs — this script only echoes. The services it installs log to the journal:
#   sudo journalctl -u mcp-auth.service -u mcp.service -f
#   sudo journalctl -u mcp-refresh.service
#   sudo journalctl -u mcp-boot.service -b
# -----------------------------------------------------------------------------

# =============================================================================
# Variable declarations
# =============================================================================

readonly APP_NAME="mcp"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# The payload this script installs, shipped beside it by vm_push. Every file in it
# is installed verbatim — see the lists below.
readonly SRC_DIR="${SCRIPT_DIR}/mcp"

# Scratch for pre-flight (the extractor fixture, the sudoers candidate). This
# app's sibling of the pushed scripts, like every other unit's staging dir.
readonly STAGE_DIR="${STAGE_ROOT}/${APP_NAME}"

# --- What the image provides ---------------------------------------------------
# Baked by build-vm-images' install-mcp.sh. Also named, identically, as MCP_VENV
# in mcp/mcp.env — change both or neither.
readonly MCP_VENV="/opt/mcp/venv"

# --- What this script installs -------------------------------------------------
readonly SVC_USER="mcp"
# NOT arbitrary: graphify's `global add` writes to Path.home()/".graphify",
# hardcoded upstream with no flag to redirect it, so HOME has to sit in /data with
# the rest of the state. --no-create-home because mcp-boot creates it, per boot.
# Matches MCP_HOME in mcp/mcp.env and SVC_HOME in mcp/mcp-boot.
readonly SVC_HOME="/data/mcp"

readonly ENV_DIR="/etc/mcp"
readonly BIN_DIR="/usr/local/bin"
readonly UNIT_DIR="/etc/systemd/system"
readonly SUDOERS_FILE="/etc/sudoers.d/mcp"

# Invoked as commands — by a unit's ExecStart=, by git's GIT_ASKPASS or by another
# helper — so each is named in-tree exactly as installed, with no extension.
readonly HELPERS=(
  gcp-secret mcp-serve mcp-auth mcp-refresh mcp-md-graph
  mcp-git-askpass mcp-log-failure mcp-boot
)

# 644, not executable. mcp_auth_app.py is handed to the venv's python by mcp-auth,
# which fetches its four secrets first — run directly it would exit at Config().
# mcp_md_extract.py is imported by mcp-md-graph from its own directory.
readonly MODULES=(mcp_auth_app.py mcp_md_extract.py)

readonly UNITS_ALL=(
  mcp-boot.service mcp.service mcp-auth.service
  mcp-refresh.service mcp-refresh.timer mcp-refresh-failed.service
)
# Two units are deliberately NOT enabled: mcp-refresh.service is pulled in by its
# timer, and mcp-refresh-failed.service is an OnFailure= target.
readonly UNITS_ENABLED=(
  mcp-boot.service mcp.service mcp-auth.service mcp-refresh.timer
)

# How long the gateway must stay up after its restart. It fetches four secrets
# before it binds :8080, and a failure makes it exit and retry every
# RestartSec=10 — this outlasts one full cycle of that.
readonly SETTLE_SECONDS=20

# --- Populated in main() from the APP_ENV argument ----------------------------
APP_ENV=""

# =============================================================================
# Functions
# =============================================================================

log() { echo "[mcp] $*"; }
die() { echo "[mcp] ERROR: $*" >&2; exit 1; }

# parse_args: validate the caller's contract and set APP_ENV.
parse_args() {
  APP_ENV="${1:-}"
  case "$APP_ENV" in
    development|production) ;;
    "") die "APP_ENV is required. Usage: $0 APP_ENV" ;;
    *)  die "APP_ENV must be 'development' or 'production', not '${APP_ENV}'" ;;
  esac
  [[ "$(id -u)" -eq 0 ]] || die "must run as root (use sudo)"
  log "APP_ENV=${APP_ENV} accepted for the standard contract; there is one MCP"
  log "  server and its configuration is ${SRC_DIR}/mcp.env."
}

# require_runtime: fail early and by name if this is not an `mcp` image, or the
# folder arrived incomplete.
require_runtime() {
  local tool missing=()
  for tool in git jq curl gcloud visudo systemctl adduser; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  (( ${#missing[@]} == 0 )) \
    || die "required command(s) not found: ${missing[*]} — this script targets the mcp image"

  [[ -x "${MCP_VENV}/bin/graphify" && -x "${MCP_VENV}/bin/python" ]] \
    || die "${MCP_VENV} is missing or has no graphify — boot this VM from the dz-mcp image family"

  local f
  for f in mcp.env "${HELPERS[@]}" "${MODULES[@]}" "${UNITS_ALL[@]}"; do
    [[ -f "${SRC_DIR}/${f}" ]] || die "${SRC_DIR}/${f} is missing — push the whole vm/mcp-vm/ folder"
  done
}

# preflight: every check that can fail because the pushed code and the baked
# runtime disagree. Runs against ${SRC_DIR}; touches nothing outside ${STAGE_DIR}.
preflight() {
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"

  # --- Gateway import check ------------------------------------------------
  # fastmcp is pre-1.0 and moving, and mcp_auth_app.py imports eight symbols from
  # six of its submodules. A FASTMCP_VERSION bump that moves or renames any of
  # them must break HERE — not as a gateway that will not start and a service
  # that answers nothing.
  #
  # It imports the module rather than running it: constructing the app needs
  # four secrets and a Google client.
  log "pre-flight: gateway imports against $("${MCP_VENV}/bin/python" -c 'from importlib.metadata import version; print("fastmcp", version("fastmcp"))')"
  "${MCP_VENV}/bin/python" - "${SRC_DIR}/mcp_auth_app.py" <<'IMPORTCHECK'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("mcp_auth_app", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert hasattr(module, "build_app"), "mcp_auth_app.build_app is missing"
print("[mcp] pre-flight: mcp_auth_app imports cleanly", file=sys.stderr)
IMPORTCHECK

  # --- Vendored-extractor drift check -------------------------------------
  # mcp_md_extract.py is a frozen copy of graphify's Markdown extractor. It does
  # not move when the image's graphify does, so without this an image bump would
  # silently ship stale extraction behaviour.
  #
  # The fixture is written here rather than pointed at a repo so the check is
  # self-contained and identical on every push. It exercises the parts most
  # likely to drift: frontmatter, nested headings, a fenced block, and all three
  # link forms (inline, reference-style, wikilink).
  #
  # Run from ${SRC_DIR}: mcp-md-graph puts its own directory on sys.path, so it
  # imports the extractor BEING PUSHED, not the one currently installed.
  local fixture="${STAGE_DIR}/md-fixture"
  mkdir -p "$fixture"
  cat > "${fixture}/index.md" <<'FIX'
---
title: "Index"
tags: [a, b]
nested:
  key: value
---
# Index
Inline [link](./other.md), a [[wikilink]], and a ref [label].

[label]: ./other.md

## Section
```
# not a heading
```
### Deeper
FIX
  cat > "${fixture}/other.md" <<'FIX'
# Other
Back to [Index](./index.md).
FIX
  # The [[wikilink]] above resolves to this file, so the check covers the
  # wikilink path rather than only its dangling-target branch.
  cat > "${fixture}/wikilink.md" <<'FIX'
# Wikilink target
FIX

  log "pre-flight: vendored extractor against $("${MCP_VENV}/bin/graphify" --version 2>&1 | head -n1)"
  "${MCP_VENV}/bin/python" "${SRC_DIR}/mcp-md-graph" "$fixture" --self-test

  # --- sudoers ---------------------------------------------------------------
  # A malformed drop-in breaks sudo for EVERY user on the box. Validate the
  # candidate before it is live, not after.
  write_sudoers "${STAGE_DIR}/sudoers"
  visudo -cf "${STAGE_DIR}/sudoers" >/dev/null \
    || die "the sudoers drop-in does not parse — not installing anything"

  log "pre-flight passed"
}

# write_sudoers <path>: the one privileged operation the refresh needs.
#
# mcp-refresh runs as the unprivileged mcp user but must restart the server when
# the graph changes — the server reads the graph into memory at startup and holds
# it, so a restart is the only way to pick up a new one. This grants exactly that
# command and nothing else.
write_sudoers() {
  cat > "$1" <<'SUDOERS'
# Installed by build-ops/vm/mcp-vm/mcp.sh. Do not edit by hand: the next deploy
# overwrites this file.
mcp ALL=(root) NOPASSWD: /usr/bin/systemctl restart mcp.service
SUDOERS
}

# ensure_user: create the service user on first deploy.
#
# --no-create-home is deliberate: the home is /data/mcp, which mcp-boot creates
# and chowns per boot (see SVC_HOME above for why it must be there). Images
# before 1-3 baked this user, so on those it already exists and is left alone.
ensure_user() {
  if id -u "$SVC_USER" >/dev/null 2>&1; then
    log "user ${SVC_USER} exists"
    return
  fi
  log "creating system user ${SVC_USER} (home ${SVC_HOME}, created by mcp-boot)"
  adduser --system --group --disabled-password --no-create-home \
    --home "$SVC_HOME" --shell /usr/sbin/nologin "$SVC_USER"
}

# put <mode> <src> <dest>: install one root-owned file by ATOMIC RENAME.
#
# Not a plain `install` over the destination: mcp-refresh may be mid-run while
# this deploys, and bash reads a script as it executes it — rewriting that file in
# place can make the running refresh execute a mix of old and new lines. A rename
# gives the new file a new inode; the running process keeps the old one.
put() {
  local mode="$1" src="$2" dest="$3"
  install -o root -g root -m "$mode" "$src" "${dest}.new"
  mv -f "${dest}.new" "$dest"
}

# install_files: everything in ${SRC_DIR}, to where the units expect it.
install_files() {
  log "installing ${ENV_DIR}/mcp.env, ${#HELPERS[@]} helpers, ${#MODULES[@]} modules, sudoers, ${#UNITS_ALL[@]} units"

  mkdir -p "$ENV_DIR"
  put 644 "${SRC_DIR}/mcp.env" "${ENV_DIR}/mcp.env"

  local f
  for f in "${HELPERS[@]}"; do put 755 "${SRC_DIR}/${f}" "${BIN_DIR}/${f}"; done
  for f in "${MODULES[@]}"; do put 644 "${SRC_DIR}/${f}" "${BIN_DIR}/${f}"; done

  # The candidate validated in preflight, byte for byte.
  put 440 "${STAGE_DIR}/sudoers" "$SUDOERS_FILE"

  for f in "${UNITS_ALL[@]}"; do put 644 "${SRC_DIR}/${f}" "${UNIT_DIR}/${f}"; done
}

enable_units() {
  systemctl daemon-reload
  systemctl enable "${UNITS_ENABLED[@]}"
}

# provision_data: make sure /data, swap and the service home exist, and apply any
# migration this push brought.
#
# On a VM that has not provisioned yet (the first push to a fresh one), START the
# unit, so it is active and every Requires= on it is satisfied for this boot.
#
# On one that has, run the SCRIPT, not `systemctl restart mcp-boot.service`: a
# restart propagates to every active unit that Requires= it — including an
# in-flight mcp-refresh, which would be killed part-way through a `global add`.
# The script is idempotent by design (it runs on every boot), so running it again
# here only does what is new: a migration shipped with this push applies now,
# alongside the code that needs it, rather than at the next reboot.
provision_data() {
  if systemctl is-active --quiet mcp-boot.service; then
    log "mcp-boot already ran this boot — re-running it for any new migration"
    "${BIN_DIR}/mcp-boot"
  else
    log "starting mcp-boot.service (first provisioning on this boot)"
    systemctl start mcp-boot.service
  fi
}

# start_services: pick up the new code and config.
#
# RESTART, not reload — neither process has an ExecReload. Both restarts are
# brief: the gateway's token store is on /data and survives it (nobody is signed
# out), and graphify re-reads the graph in ~2 s of 503, the same cost the hourly
# refresh pays whenever the graph moves.
#
# On a fresh VM mcp.service then crash-loops until the first refresh produces a
# graph. That is expected, and why it is not what verify_gateway checks.
#
# The timer is STARTED, not restarted: on a VM that has been up longer than its
# OnBootSec=2min, starting it fires the first refresh immediately — exactly what a
# first push wants — and on one where it is already active it is a no-op.
start_services() {
  log "restarting mcp.service and mcp-auth.service"
  systemctl restart mcp.service mcp-auth.service
  systemctl start mcp-refresh.timer
}

# verify_gateway: the gateway is the only publicly reachable process, so it is
# the one that must be up. `systemctl restart` returns before it has fetched its
# secrets; a missing secret or a denied grant makes it exit a moment later and
# retry forever. Wait, then check it is still running.
verify_gateway() {
  log "waiting ${SETTLE_SECONDS}s for mcp-auth.service to settle"
  sleep "$SETTLE_SECONDS"
  if ! systemctl is-active --quiet mcp-auth.service; then
    journalctl -u mcp-auth.service -n 30 --no-pager >&2 || true
    die "mcp-auth.service did not stay up (journal above). The files are installed; fix the cause — most often a secret in Secret Manager with no value, or no accessor grant — and re-run."
  fi
  log "mcp-auth.service is up"
}

# =============================================================================
# Main
# =============================================================================
main() {
  parse_args "$@"
  require_runtime
  preflight          # touches nothing outside ${STAGE_DIR}
  ensure_user
  install_files
  enable_units
  provision_data
  start_services
  verify_gateway

  rm -rf "$STAGE_DIR"
  log "Deployment complete."
  log "  graph refresh: sudo journalctl -u mcp-refresh.service -f"
  log "  a fresh VM answers /healthz with 503 until its first graph (~12 min)."
}

main "$@"
