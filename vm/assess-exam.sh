#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# assess-exam.sh — app deploy script (the <APP_NAME>.sh that vm-startup.sh clones
# and runs as a child at boot). assess-exam is a STATIC UI bundle: no database, no
# app.properties, no external logback — and, as of the nginx cutover, NO TOMCAT.
#
# The artifact is still packaged as a WAR (that is what the Maven build
# produces), but a WAR is just a zip, and this one holds nothing but static
# files. So instead of handing it to Tomcat we UNZIP it into the nginx static
# root and let nginx serve it directly. Nothing about this app needs a servlet
# container.
#
# What this script does:
#   1. downloads the app's install FOLDER and the WAR from GCS
#   2. unzips the WAR into ${WEB_ROOT}/<ctx>          (the served document root)
#   3. writes /etc/nginx/app.d/<ctx>.conf             (the routing drop-in)
#   4. reloads nginx
#
# Contract (see vm-startup.sh): invoked as `<APP_NAME>.sh APP_ENV`.
# APP_NAME is fixed to "assess-exam" here (this IS that script); the single
# argument is APP_ENV ("$1").
#
# Requires the tomcat-nginx-mysql image (or any image whose install-nginx.sh has
# run): this script writes into /etc/nginx/app.d/, the routing seam that image
# bakes EMPTY on purpose. See build-vm-images/scripts/ubuntu/install-nginx.sh
# and /etc/nginx/app.d/README on the VM itself.
#
# GCS layout (${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/):
#   install/                       the whole config folder, copied verbatim:
#     install.properties             ALL deploy values (see the key list below)
#   <install.war>                  the versioned WAR
#
# install.properties is the single source of truth for the deploy; NOTHING is
# derived by this script. Keys used:
#   install.war                  WAR filename to download and unzip
#   install.app.context.path     URL path and dir name -> ${WEB_ROOT}/<ctx>, /<ctx>
#   install.web.root             OPTIONAL. nginx static root holding the per-app
#                                dirs; defaults to /var/www/app, the dir the
#                                tomcat-nginx-mysql image bakes for this. Set it
#                                only to serve from somewhere the image does not
#                                prepare — see DEFAULT_WEB_ROOT below.
#
# NOTE — keys that are NO LONGER read, and the file that is no longer installed:
#   install.catalina.home        Tomcat home; meaningless now that nginx serves
#                                this app. Harmless if still present in the file.
#   <ctx>.xml                    the per-webapp Tomcat context descriptor. nginx
#                                has no equivalent — its routing is the app.d
#                                drop-in this script GENERATES (write_nginx_conf)
#                                rather than a file copied from GCS.
# The install/ folder in GCS therefore needs no change for this cutover; the
# leftover key and descriptor are simply ignored.
#
# Caching — every response from this app is served with
#   Cache-Control: no-cache, must-revalidate
#   Pragma: no-cache
#   Expires: 0
# so a browser always revalidates before reusing anything, and a redeploy is
# picked up on the next request rather than after a cache expiry. This is applied
# to EVERY file (not just index.html) by deliberate choice — see write_nginx_conf.
#
# Logs — this script only echoes to stdout/stderr; it is NOT its own systemd
# unit. Where its output lands depends on how it is invoked:
#   * At boot (launched by vm-startup.sh): its output is inherited by the
#     vm-startup.service unit, so it lands in that journal:
#       sudo journalctl -u vm-startup.service -b -f
#   * Run manually over SSH: output goes to your terminal; capture with
#       sudo bash assess-exam.sh <APP_ENV> 2>&1 | tee /tmp/assess-exam.log
#
# This script only INSTALLS the files — they are then served by the separate
# 'nginx' service, whose logs are elsewhere:
#   sudo journalctl -u nginx -f
#   sudo tail -f /var/log/nginx/access.log /var/log/nginx/error.log
# -----------------------------------------------------------------------------

# =============================================================================
# Variable declarations
# =============================================================================
# All variables are declared here up front. Static values are set inline;
# values that depend on runtime input (the APP_ENV argument, or keys read from
# install.properties) are declared empty here and populated in main() as they
# become available. The comment on each explains where its value comes from.

# --- Fixed identity -----------------------------------------------------------
# This script IS the assess-exam installer, so APP_NAME is fixed rather than taken
# from the launcher. (vm-startup.sh resolves this very file by that name —
# <clone>/vm/assess-exam.sh — so the name is already implied.) Only APP_ENV varies
# (development/production) and is the sole argument.
readonly APP_NAME="assess-exam"

# The service that serves the deployed files, and the user it runs its workers
# as. nginx's master runs as root but its workers drop to this user, so the
# static files must be readable by it. (The baked image creates /var/www/app
# owned by www-data; we match that ownership.)
readonly NGINX_SERVICE="nginx"
readonly NGINX_USER="www-data"
readonly NGINX_GROUP="www-data"

# The routing seam baked EMPTY into the tomcat-nginx-mysql image: the :80 server
# block does `include /etc/nginx/app.d/*.conf;`, so a file dropped here adds
# location blocks to it. This script owns exactly one file in that dir —
# <ctx>.conf — and never touches the server block itself.
readonly NGINX_APP_D="/etc/nginx/app.d"

# Fallback for install.web.root — the static root the tomcat-nginx-mysql image
# bakes (empty, www-data-owned) for exactly this purpose. It is the PARENT that
# holds the per-app dirs, not one app's dir: this script installs into
# ${WEB_ROOT}/<ctx>, so both apps share the root and differ by context path.
#
# It stays overridable rather than hardcoded because install.properties is this
# deploy's single source of truth; the default only spares every app from
# restating the one value the image already guarantees. Overriding it means
# pre-creating that dir on the VM with www-data able to traverse it — nothing
# outside this path is created or chowned by the image.
readonly DEFAULT_WEB_ROOT="/var/www/app"

# Base GCS location that holds per-environment release artifacts. The install/
# folder and the WAR for this deploy live under
# ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/.
readonly GCS_BASE_URL="gs://deployza-apps"

# --- Populated in main() from the APP_ENV argument ----------------------------
APP_ENV=""              # the single positional argument ("$1"): dev/production
INSTALL_URI=""          # ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/install
STAGE_DIR=""            # local staging dir for the downloaded install files + WAR
INSTALL_PROPS=""        # ${STAGE_DIR}/install.properties

# --- Populated in main() from install.properties ------------------------------
APP_WAR_FILE=""         # install.war              WAR filename to download/unzip
CONTEXT_PATH=""         # install.app.context.path context name (URL /<ctx>)
WEB_ROOT=""             # install.web.root         nginx static root

# --- Derived in main() from the conf keys -------------------------------------
TMP_WAR=""              # ${STAGE_DIR}/${APP_WAR_FILE}  (real versioned name)
WAR_URI=""              # GCS URI of the WAR
DOC_ROOT=""             # ${WEB_ROOT}/${CONTEXT_PATH}   (where the WAR is unzipped)
STAGED_DOC_ROOT=""      # ${WEB_ROOT}/.${CONTEXT_PATH}.new  (unzip target, then mv)
OLD_DOC_ROOT=""         # ${WEB_ROOT}/.${CONTEXT_PATH}.old  (previous, then rm)
NGINX_CONF=""           # ${NGINX_APP_D}/${CONTEXT_PATH}.conf

# =============================================================================
# Functions
# =============================================================================

# read_prop <key>: prints the value of the last matching line in
# install.properties, trimmed of surrounding whitespace AND surrounding
# single/double quotes (values like install.web.root="..." may be quoted
# in the file).
read_prop() {
  local key="$1" val
  val="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$INSTALL_PROPS" \
    | tail -n1 \
    | sed 's/[[:space:]]*$//')"
  val="${val%\"}"; val="${val#\"}"   # strip a matching pair of double quotes
  val="${val%\'}"; val="${val#\'}"   # strip a matching pair of single quotes
  printf '%s' "$val"
}

# require_prop <var> <key>: read a key that must be non-empty, or abort.
require_prop() {
  local __var="$1" __key="$2" __val
  __val="$(read_prop "$__key")"
  if [[ -z "$__val" ]]; then
    echo "ERROR: required key '${__key}' not set in ${INSTALL_PROPS}." >&2
    exit 1
  fi
  printf -v "$__var" '%s' "$__val"
}

# default_prop <var> <key> <default>: read an optional key, falling back to the
# default when it is absent or empty. The fallback is announced, so a deploy log
# always shows which value was used and whether it came from the file.
#
# Use this ONLY where the default is a path the image itself bakes — the value
# still gets the same validation as a supplied one, so the guard does not go dead
# just because the key was omitted.
default_prop() {
  local __var="$1" __key="$2" __default="$3" __val
  __val="$(read_prop "$__key")"
  if [[ -z "$__val" ]]; then
    echo "Key '${__key}' not set; using image default: ${__default}"
    __val="$__default"
  fi
  printf -v "$__var" '%s' "$__val"
}

# parse_args: validate the launcher contract and set APP_ENV.
# APP_ENV is required — refuse to run without it rather than deploying to a
# wrong default environment.
parse_args() {
  APP_ENV="${1:-}"
  if [[ -z "$APP_ENV" ]]; then
    echo "ERROR: APP_ENV is required." >&2
    echo "Usage: $0 APP_ENV" >&2
    exit 1
  fi
}

# require_tools: fail early and by name if the host is missing something we need.
# `unzip` is the one genuinely new dependency of the nginx cutover — the Tomcat
# version of this script never unpacked the WAR itself. On an image where it is
# absent, failing here with a clear message beats failing mid-deploy inside
# unpack_war with the old app already torn down.
require_tools() {
  local tool missing=()
  for tool in gsutil unzip nginx; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done

  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: required command(s) not found: ${missing[*]}" >&2
    echo "  This script targets the tomcat-nginx-mysql image (nginx + unzip present)." >&2
    exit 1
  fi

  # The app.d dir is created by the image's install-nginx.sh. If it is missing,
  # this host's nginx has no routing seam and a dropped .conf would never be
  # included — the deploy would "succeed" while serving 404s.
  if [[ ! -d "$NGINX_APP_D" ]]; then
    echo "ERROR: ${NGINX_APP_D} does not exist — this host was not built from an" >&2
    echo "  nginx-enabled image (see build-vm-images/scripts/ubuntu/install-nginx.sh)." >&2
    exit 1
  fi
}

# prepare_staging: (re)create a clean staging dir so it holds only the current
# deploy's artifacts. The install/ contents and the WAR share this one dir — the
# WAR's filename (install.war) never collides with an install file.
prepare_staging() {
  echo "Clearing previous ${APP_NAME} staging dir (${STAGE_DIR})..."
  rm -rf "${STAGE_DIR:?}"
  mkdir -p "$STAGE_DIR"
}

# download_install: recursive copy of the whole install/ folder into STAGE_DIR.
# Trailing '/*' copies its contents straight into STAGE_DIR (rather than nesting
# an install/ dir inside it). Verifies install.properties landed.
download_install() {
  echo "Downloading install folder for ${APP_NAME} (${APP_ENV})..."
  echo "  install: ${INSTALL_URI}/"
  gsutil -m cp -r "${INSTALL_URI}/*" "$STAGE_DIR/"

  if [[ ! -f "$INSTALL_PROPS" ]]; then
    echo "ERROR: install.properties missing after download: $INSTALL_PROPS" >&2
    exit 1
  fi
}

# load_props: read every deploy value straight from install.properties and
# derive the paths that depend on those values. install.properties is the single
# source of truth — nothing here is derived from anything but its keys.
#
# install.catalina.home is deliberately NOT read: this app no longer goes near
# Tomcat. A stale copy of the key in install.properties is ignored, so the GCS
# install/ folder needs no edit for the nginx cutover.
load_props() {
  require_prop APP_WAR_FILE      'install.war'
  require_prop CONTEXT_PATH      'install.app.context.path'
  default_prop WEB_ROOT          'install.web.root' "$DEFAULT_WEB_ROOT"

  # Guard the two values that get interpolated into paths we rm -rf and into the
  # generated nginx config. A context path containing a slash would both escape
  # ${WEB_ROOT} and produce a location block that does not mean what it looks
  # like; an empty-ish web root would aim the swap at /.
  #
  # The web-root check runs on the defaulted value too, not just a supplied one:
  # it is the standing statement of what this variable may ever hold, and it must
  # not become dead code the day the key is omitted everywhere.
  if [[ ! "$CONTEXT_PATH" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: install.app.context.path must be a bare name matching" >&2
    echo "  [A-Za-z0-9][A-Za-z0-9._-]* (no slashes); got: '${CONTEXT_PATH}'" >&2
    exit 1
  fi
  if [[ "$WEB_ROOT" != /?* || "$WEB_ROOT" == */ ]]; then
    echo "ERROR: install.web.root must be an absolute path with no trailing" >&2
    echo "  slash; got: '${WEB_ROOT}'" >&2
    exit 1
  fi

  # WAR: staged under its real versioned name so the staging dir shows exactly
  # what was deployed; unzipped into ${WEB_ROOT}/<ctx>.
  TMP_WAR="${STAGE_DIR}/${APP_WAR_FILE}"
  WAR_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_WAR_FILE}"

  # Served doc root, plus the two scratch siblings the atomic swap uses. Both
  # are dotfiles so a half-finished deploy is never picked up as an app dir.
  DOC_ROOT="${WEB_ROOT}/${CONTEXT_PATH}"
  STAGED_DOC_ROOT="${WEB_ROOT}/.${CONTEXT_PATH}.new"
  OLD_DOC_ROOT="${WEB_ROOT}/.${CONTEXT_PATH}.old"

  NGINX_CONF="${NGINX_APP_D}/${CONTEXT_PATH}.conf"
}

# download_war: fetch the WAR into the staging dir under its real versioned
# filename so the staging dir shows exactly what was deployed.
download_war() {
  echo "Downloading WAR ${APP_WAR_FILE}..."
  echo "  WAR: ${WAR_URI}"
  gsutil cp "$WAR_URI" "$TMP_WAR"
}

# unpack_war: unzip the WAR into a scratch dir NEXT TO the live doc root, then
# swap it in with two renames. A WAR is just a zip; this one holds only static
# files, so unzipping it IS the deploy.
#
# Why not unzip straight into ${DOC_ROOT}: nginx is serving out of that dir right
# now. Unzipping in place would expose a half-written tree to live requests, and
# clearing it first would 404 every request for the duration. Unzipping to a
# sibling and renaming makes the cutover a directory swap — each request sees
# either the whole old tree or the whole new one.
#
# The swap is two renames rather than one because rename() cannot replace a
# non-empty directory: move the live tree aside, move the new one in, then delete
# the old. The gap between them is a couple of syscalls wide.
#
# WEB-INF/ and META-INF/ are dropped after unpacking: they are servlet-container
# metadata with no meaning to nginx, and WEB-INF is exactly the kind of thing
# that must not become web-reachable now that a plain file server owns the tree.
unpack_war() {
  echo "Unpacking WAR into ${DOC_ROOT} (via ${STAGED_DOC_ROOT})..."

  # Leftovers from an interrupted previous run would otherwise merge into this
  # deploy's tree.
  rm -rf "${STAGED_DOC_ROOT:?}" "${OLD_DOC_ROOT:?}"
  mkdir -p "$STAGED_DOC_ROOT"

  # -q quiet, -o overwrite without prompting (unzip is interactive by default and
  # would hang a boot-time deploy waiting on stdin).
  unzip -q -o "$TMP_WAR" -d "$STAGED_DOC_ROOT"

  # Servlet-container metadata — not servable content.
  rm -rf "${STAGED_DOC_ROOT}/WEB-INF" "${STAGED_DOC_ROOT}/META-INF"

  # A bundle with no index.html is almost certainly the wrong artifact (or an
  # unzip that silently produced nothing). Catch it before the swap, while the
  # currently-served app is still untouched.
  if [[ ! -f "${STAGED_DOC_ROOT}/index.html" ]]; then
    echo "ERROR: no index.html in the unpacked WAR (${STAGED_DOC_ROOT})." >&2
    echo "  Is ${APP_WAR_FILE} really the static ${APP_NAME} bundle?" >&2
    rm -rf "${STAGED_DOC_ROOT:?}"
    exit 1
  fi

  # nginx workers run as ${NGINX_USER}; dirs need +x to be traversed. Ownership
  # is set BEFORE the swap so the tree is already correct the moment it goes live.
  chown -R "$NGINX_USER":"$NGINX_GROUP" "$STAGED_DOC_ROOT"
  chmod -R u=rwX,go=rX "$STAGED_DOC_ROOT"

  # Two-step swap (rename cannot clobber a non-empty dir).
  if [[ -d "$DOC_ROOT" ]]; then
    mv "$DOC_ROOT" "$OLD_DOC_ROOT"
  fi
  mv "$STAGED_DOC_ROOT" "$DOC_ROOT"
  rm -rf "${OLD_DOC_ROOT:?}"

  echo "Unpacked $(find "$DOC_ROOT" -type f | wc -l) files to ${DOC_ROOT}"
}

# write_nginx_conf: generate this app's routing drop-in. Per the app.d contract
# (see /etc/nginx/app.d/README) the file holds ONLY location blocks — it is
# included INSIDE the baked :80 server{} block, so a server{} wrapper here would
# be a syntax error.
#
# This file is GENERATED, not copied from GCS: unlike the Tomcat <ctx>.xml it
# replaces, its content is fully determined by two values we already have
# (CONTEXT_PATH and WEB_ROOT). Generating it keeps the routing in the same place
# as the code that installs the files.
#
# `alias` rather than `root`: with root, nginx appends the FULL request URI to
# the path, so /<ctx>/app.js under root ${WEB_ROOT} would resolve to
# ${WEB_ROOT}/<ctx>/app.js only because the dir happens to share the context
# name. alias replaces the matched prefix instead, which states the mapping
# outright and keeps working if the two ever diverge.
#
# The exact-match /<ctx> block exists because /<ctx> (no trailing slash) does not
# match the /<ctx>/ prefix location; without it the bare URL 404s. The redirect
# also normalizes relative asset URLs in index.html, which resolve differently
# with and without the trailing slash.
#
# Caching: the three no-store-ish headers go on EVERY response from this app —
# not just index.html — so nothing is ever reused from cache without a
# revalidation round-trip and a redeploy takes effect immediately. `always` makes
# them apply to error responses too (add_header otherwise covers only 2xx/3xx).
# Note that add_header in a nested location REPLACES any inherited set rather
# than adding to it, so each location that needs these headers repeats them.
write_nginx_conf() {
  echo "Writing nginx routing drop-in ${NGINX_CONF}..."

  cat >"$NGINX_CONF" <<EOF
# ${APP_NAME} — generated by build-app-install/vm/${APP_NAME}.sh. Do not edit by
# hand: the next deploy overwrites this file. Location blocks only (this is
# included inside the :80 server block baked by install-nginx.sh).

# Bare /${CONTEXT_PATH} does not match the /${CONTEXT_PATH}/ prefix below, so send
# it to the canonical trailing-slash form (relative asset URLs depend on it).
location = /${CONTEXT_PATH} {
    return 301 /${CONTEXT_PATH}/;
}

location /${CONTEXT_PATH}/ {
    alias ${DOC_ROOT}/;
    index index.html;

    # Plain static serving: no SPA fallback, so an unknown path is a real 404
    # rather than a silent index.html.
    try_files \$uri \$uri/ =404;

    # Never reuse a cached response without revalidating — a redeploy is picked
    # up on the next request. Applied to every file in this app by design.
    add_header Cache-Control "no-cache, must-revalidate" always;
    add_header Pragma "no-cache" always;
    add_header Expires 0 always;
}
EOF

  chmod 644 "$NGINX_CONF"
}

# reload_nginx: validate the whole config, then reload.
#
# `nginx -t` first, and treated as fatal: a reload with a broken config leaves
# the old workers running, so nginx would keep serving the PREVIOUS app while
# reporting success. Failing here surfaces that instead of hiding it. The test
# covers every app.d drop-in, so a sibling app's broken file fails this too —
# correct, since the reload would not have applied either way.
#
# reload (SIGHUP), not restart: it re-reads config and cycles workers without
# dropping connections or a window where :80 is unbound.
reload_nginx() {
  echo "Validating nginx configuration..."
  if ! nginx -t; then
    echo "ERROR: nginx -t failed; not reloading. ${CONTEXT_PATH} files are in place" >&2
    echo "  at ${DOC_ROOT} but the routing is not live. Fix the config above and run:" >&2
    echo "    sudo nginx -t && sudo systemctl reload ${NGINX_SERVICE}" >&2
    exit 1
  fi

  echo "Reloading ${NGINX_SERVICE}..."
  systemctl reload "$NGINX_SERVICE"
}

# =============================================================================
# Main
# =============================================================================
main() {
  parse_args "$@"
  require_tools

  # Paths that depend only on APP_ENV / APP_NAME.
  INSTALL_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/install"
  # Staging dir is this app's own sibling of the clone under the shared deploy
  # root (see vm-startup.sh): /tmp/deployza/repo is the clone, /tmp/deployza/
  # <APP_NAME> is ours. Same path whether launched by vm-startup.sh at boot or
  # run standalone over SSH.
  STAGE_DIR="/tmp/deployza/${APP_NAME}"
  INSTALL_PROPS="${STAGE_DIR}/install.properties"

  prepare_staging
  download_install
  load_props            # reads install.properties, derives the rest of the paths
  download_war
  unpack_war            # unzip + atomic swap into ${WEB_ROOT}/<ctx>
  write_nginx_conf      # generate the app.d drop-in (files first, so the routing
                        # never points at a dir that is not populated yet)
  reload_nginx

  echo "Deployment complete."
  echo "App should be available at: /${CONTEXT_PATH}/"
}

main "$@"
