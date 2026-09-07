#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# www-website.sh — app deploy script (the <APP_NAME>.sh that vm-startup.sh
# clones and runs as a child at boot). www-website is the marketing site for
# www.deployza.com: a STATIC site (no database, no app.properties, no logback,
# no Tomcat), packaged as a WAR only because that is what its Maven build
# produces.
#
# A WAR is just a zip, and this one holds nothing but static files, so this
# script UNZIPS it into an nginx document root and lets nginx serve it
# directly — exactly the ziniapps-www.sh model. See
# ../../build-vm-images/docs/website-nginx-plan.md for the cross-repo design.
#
# THIS IS A NEAR-COPY OF ziniapps-www.sh, WITH TWO DELIBERATE ADDITIONS
#
# Like ziniapps-www.sh, this is a per-HOST site (see this repo's CLAUDE.md —
# "Two kinds of app"): it writes a COMPLETE server{} block to
# /etc/nginx/site.d/, and deliberately does NOT include /etc/nginx/app.d/*.conf
# — www.deployza.com is the one product on this host, not a landing page
# linking out to path-prefixed apps, so there is nothing in app.d it needs.
#
# The two additions, both POLICY THIS SCRIPT OWNS (not baked into the nginx
# image, consistent with install-nginx-static.sh shipping no app routing):
#
#   1. A second `location /docs/` block in the generated server config,
#      independent of the WAR unpack — serves the MkDocs site built by the
#      sibling `api-docs` repo (now named `www-apidocs` on GitHub) from
#      DOCS_ROOT. See write_nginx_conf.
#
#   2. A continuous docs-content puller — install_docs_refresh_timer installs
#      and enables a oneshot systemd service + timer that `gsutil rsync`s
#      DOCS_ROOT from GCS every few minutes. The boot-time-only WAR model
#      above doesn't fit MkDocs: docs update far more often than this VM
#      reboots, and there is no WAR/install.properties artifact for it — just
#      a `site/` tree. This is a PULL model deliberately: api-docs's Cloud
#      Build trigger never needs to reach this VM at all (no SSH, no IAP
#      tunnel, no new firewall rule) — it only writes to GCS, and the VM
#      notices on its own schedule.
#
# Whole-site no-cache: EVERY response from this host — the marketing site at
# / and the docs at /docs/ alike — carries
#   Cache-Control: no-cache, must-revalidate
#   Pragma: no-cache
#   Expires: 0
# matching ziniapps-www.sh's policy exactly. Each location that can produce a
# response repeats the three headers rather than inheriting them: add_header
# in a nested location REPLACES any inherited set rather than adding to it.
#
# What this script does:
#   1. downloads the app's install FOLDER and the WAR from GCS
#   2. unzips the WAR into ${WEB_ROOT}/<site>       (the served document root)
#   3. ensures http{} includes /etc/nginx/site.d/   (one-time, idempotent)
#   4. writes /etc/nginx/site.d/<site>.conf         (the per-host server
#      block, / from the WAR + /docs/ from DOCS_ROOT)
#   5. installs + enables the docs-refresh timer     (one-time, idempotent)
#   6. reloads nginx
#
# Contract (see vm-startup.sh): invoked as `<APP_NAME>.sh APP_ENV`.
# APP_NAME is fixed to "www-website" here (this IS that script); the single
# argument is APP_ENV ("$1").
#
# Requires the `nginx` image (build-vm-images/images/ubuntu/nginx/) — or any
# image whose install-nginx-static.sh (or install-nginx.sh) has run. Unlike
# ziniapps-www.sh, this app has no Tomcat dependency at all, so it targets the
# Tomcat-free `nginx` flavor rather than tomcat-nginx-mysql.
#
# GCS layout (${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/):
#   install/                       the whole config folder, copied verbatim:
#     install.properties             ALL deploy values (see the key list below)
#   <install.war>                  the versioned WAR
#
# DOCS content is a SEPARATE GCS path, always "prod" regardless of this VM's
# own APP_ENV — see DOCS_BUCKET_URI: api-docs publishes exactly one docs site
# (no per-environment split), so there is nothing for an APP_ENV-scoped path
# to select between.
#
# install.properties is the single source of truth for the deploy; NOTHING is
# derived by this script. Keys used:
#   install.war                  WAR filename to download and unzip
#   install.server.name          the hostname this block answers for, e.g.
#                                www.deployza.com
#   install.site.name            OPTIONAL. bare name used for the doc-root dir
#                                and the conf filename; defaults to the app name
#                                (www-website).
#   install.web.root             OPTIONAL. nginx static root holding the per-site
#                                dirs; defaults to /var/www/site.
#
# Logs — this script only echoes to stdout/stderr; it is NOT its own systemd
# unit. Where its output lands depends on how it is invoked:
#   * At boot (launched by vm-startup.sh): its output is inherited by the
#     vm-startup.service unit, so it lands in that journal:
#       sudo journalctl -u vm-startup.service -b -f
#   * Run manually over SSH: output goes to your terminal; capture with
#       sudo bash www-website.sh <APP_ENV> 2>&1 | tee /tmp/www-website.log
#
# This script only INSTALLS the files — they are then served by the separate
# 'nginx' service, and refreshed by the separate 'docs-refresh' timer, whose
# logs are elsewhere:
#   sudo journalctl -u nginx -f
#   sudo journalctl -u docs-refresh.service
#   sudo tail -f /var/log/nginx/access.log /var/log/nginx/error.log
# -----------------------------------------------------------------------------

# =============================================================================
# Variable declarations
# =============================================================================

# --- Fixed identity -----------------------------------------------------------
# This script IS the www-website installer, so APP_NAME is fixed rather than
# taken from the launcher. (vm-startup.sh resolves this very file by that name —
# <clone>/vm/www-website.sh — so the name is already implied.) Only APP_ENV
# varies (development/production) and is the sole argument.
readonly APP_NAME="www-website"

# The service that serves the deployed files, and the user it runs its workers
# as. nginx's master runs as root but its workers drop to this user, so the
# static files (WAR content and docs alike) must be readable by it.
readonly NGINX_SERVICE="nginx"
readonly NGINX_USER="www-data"
readonly NGINX_GROUP="www-data"

# The per-HOST routing seam. Created by these scripts, not by the image. One file
# per site: <site>.conf, each holding a complete server{} block, included from
# the http{} block of nginx.conf.
#
# NOTE there is deliberately no NGINX_APP_D constant here, matching
# ziniapps-www.sh: this site does not include the per-path apps (there are none
# on this VM at all — the `nginx` image has no app.d contents baked in either).
readonly NGINX_SITE_D="/etc/nginx/site.d"

# nginx's main config, where the one-time site.d include is added. An http{}-level
# include is the only place a server{} block may appear, and the baked config has
# no such include.
readonly NGINX_CONF_MAIN="/etc/nginx/nginx.conf"

# Marker comment written next to the generated include line, used to detect an
# already-patched nginx.conf. Shared BY VALUE with ziniapps-go.sh/ziniapps-www.sh
# — every per-HOST script uses the same site.d mechanism, so whichever one runs
# first on a given VM adds the include and any other finds the marker and skips.
# Irrelevant in practice here (this VM only ever runs www-website), kept for
# consistency with the other per-HOST scripts rather than invented fresh.
readonly INCLUDE_MARKER="# DEPLOYZA-SITE-D"

# Fallback for install.web.root — the parent holding the per-SITE doc roots.
# Deliberately NOT /var/www/app (the assess-* default): that dir holds per-PATH
# apps served by the image's `_` block, and the two models should not share a
# namespace. Not baked by the image, so this script creates it.
readonly DEFAULT_WEB_ROOT="/var/www/site"

# Where the MkDocs site lives, kept continuously up to date by
# docs-refresh.timer (install_docs_refresh_timer). Separate from WEB_ROOT: the
# WAR's atomic-swap unpack (unpack_war) and the docs' continuous rsync
# (refresh_docs_now / the timer) are two independent update mechanisms with
# different cadences, and must not share a directory tree.
readonly DOCS_ROOT="/var/www/api-docs"

# GCS path the docs are pulled FROM. Always "prod" — see the header note
# above on why this does not follow APP_ENV; "prod" (not "production") to
# match the fleet's one existing convention (products/vms.tf's assess-install
# VM). `-d` (delete) is intentional: a removed/renamed doc page should
# disappear here too, matching api-docs's own `gsutil rsync -d` on publish
# (see api-docs/cloudbuild.yaml).
readonly DOCS_BUCKET_URI="gs://deployza-apps/prod/api-docs/site/"

# systemd units for the continuous docs puller.
readonly DOCS_REFRESH_SERVICE="docs-refresh.service"
readonly DOCS_REFRESH_TIMER="docs-refresh.timer"
readonly DOCS_REFRESH_SERVICE_PATH="/etc/systemd/system/${DOCS_REFRESH_SERVICE}"
readonly DOCS_REFRESH_TIMER_PATH="/etc/systemd/system/${DOCS_REFRESH_TIMER}"

# Base GCS location that holds per-environment release artifacts.
readonly GCS_BASE_URL="gs://deployza-apps"

# --- Populated in main() from the APP_ENV argument ----------------------------
APP_ENV=""              # the single positional argument ("$1"): dev/production
INSTALL_URI=""          # ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/install
STAGE_DIR=""            # local staging dir for the downloaded install files + WAR
INSTALL_PROPS=""        # ${STAGE_DIR}/install.properties

# --- Populated in main() from install.properties ------------------------------
APP_WAR_FILE=""         # install.war          WAR filename to download/unzip
SERVER_NAME=""          # install.server.name  hostname this block answers for
SITE_NAME=""            # install.site.name    dir + conf basename
WEB_ROOT=""             # install.web.root     nginx static root

# --- Derived in main() from the conf keys -------------------------------------
TMP_WAR=""              # ${STAGE_DIR}/${APP_WAR_FILE}  (real versioned name)
WAR_URI=""              # GCS URI of the WAR
DOC_ROOT=""             # ${WEB_ROOT}/${SITE_NAME}      (where the WAR is unzipped)
STAGED_DOC_ROOT=""      # ${WEB_ROOT}/.${SITE_NAME}.new (unzip target, then mv)
OLD_DOC_ROOT=""         # ${WEB_ROOT}/.${SITE_NAME}.old (previous, then rm)
NGINX_CONF=""           # ${NGINX_SITE_D}/${SITE_NAME}.conf

# =============================================================================
# Functions
# =============================================================================

# read_prop <key>: prints the value of the last matching line in
# install.properties, trimmed of surrounding whitespace AND surrounding
# single/double quotes.
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
default_prop() {
  local __var="$1" __key="$2" __default="$3" __val
  __val="$(read_prop "$__key")"
  if [[ -z "$__val" ]]; then
    echo "Key '${__key}' not set; using default: ${__default}"
    __val="$__default"
  fi
  printf -v "$__var" '%s' "$__val"
}

# parse_args: validate the launcher contract and set APP_ENV.
parse_args() {
  APP_ENV="${1:-}"
  if [[ -z "$APP_ENV" ]]; then
    echo "ERROR: APP_ENV is required." >&2
    echo "Usage: $0 APP_ENV" >&2
    exit 1
  fi
}

# require_tools: fail early and by name if the host is missing something we need.
require_tools() {
  local tool missing=()
  for tool in gsutil unzip nginx; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done

  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: required command(s) not found: ${missing[*]}" >&2
    echo "  This script targets the nginx image (nginx + unzip present)." >&2
    exit 1
  fi

  if [[ ! -f "$NGINX_CONF_MAIN" ]]; then
    echo "ERROR: ${NGINX_CONF_MAIN} not found — cannot install the site.d include." >&2
    exit 1
  fi
}

# prepare_staging: (re)create a clean staging dir so it holds only the current
# deploy's artifacts.
prepare_staging() {
  echo "Clearing previous ${APP_NAME} staging dir (${STAGE_DIR})..."
  rm -rf "${STAGE_DIR:?}"
  mkdir -p "$STAGE_DIR"
}

# download_install: recursive copy of the whole install/ folder into STAGE_DIR.
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
# derive the paths that depend on those values.
load_props() {
  require_prop APP_WAR_FILE 'install.war'
  require_prop SERVER_NAME  'install.server.name'
  default_prop SITE_NAME    'install.site.name' "$APP_NAME"
  default_prop WEB_ROOT     'install.web.root'  "$DEFAULT_WEB_ROOT"

  # SERVER_NAME lands inside a server_name directive, so it must be a plain
  # hostname: anything containing whitespace, ';' or '{' could close the
  # directive and inject arbitrary config. Restricting it to DNS-legal characters
  # makes that structurally impossible rather than merely unlikely.
  if [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "ERROR: install.server.name must be a plain hostname (letters, digits," >&2
    echo "  dots and hyphens); got: '${SERVER_NAME}'" >&2
    exit 1
  fi

  # SITE_NAME becomes a directory under WEB_ROOT and the conf filename. A slash
  # would escape WEB_ROOT (and this script rm -rf's those paths).
  if [[ ! "$SITE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: install.site.name must be a bare name matching" >&2
    echo "  [A-Za-z0-9][A-Za-z0-9._-]* (no slashes); got: '${SITE_NAME}'" >&2
    exit 1
  fi

  # The web-root check runs on the defaulted value too, not just a supplied one:
  # it is the standing statement of what this variable may ever hold, and it must
  # not become dead code the day the key is omitted everywhere.
  if [[ "$WEB_ROOT" != /?* || "$WEB_ROOT" == */ ]]; then
    echo "ERROR: install.web.root must be an absolute path with no trailing" >&2
    echo "  slash; got: '${WEB_ROOT}'" >&2
    exit 1
  fi

  TMP_WAR="${STAGE_DIR}/${APP_WAR_FILE}"
  WAR_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_WAR_FILE}"

  # Served doc root, plus the two scratch siblings the atomic swap uses. Both
  # are dotfiles so a half-finished deploy is never picked up as a site dir.
  DOC_ROOT="${WEB_ROOT}/${SITE_NAME}"
  STAGED_DOC_ROOT="${WEB_ROOT}/.${SITE_NAME}.new"
  OLD_DOC_ROOT="${WEB_ROOT}/.${SITE_NAME}.old"

  NGINX_CONF="${NGINX_SITE_D}/${SITE_NAME}.conf"
}

# prepare_web_root: create the per-site static root if it does not exist.
# Unlike /var/www/app (baked empty and www-data-owned by install-nginx.sh), the
# site root is this script's own convention and no image creates it.
prepare_web_root() {
  if [[ ! -d "$WEB_ROOT" ]]; then
    echo "Creating site root ${WEB_ROOT}..."
    mkdir -p "$WEB_ROOT"
    chown "$NGINX_USER":"$NGINX_GROUP" "$WEB_ROOT"
    # 755: nginx workers must traverse it; it holds only public static content.
    chmod 755 "$WEB_ROOT"
  fi
}

# download_war: fetch the WAR into the staging dir under its real versioned
# filename so the staging dir shows exactly what was deployed.
download_war() {
  echo "Downloading WAR ${APP_WAR_FILE}..."
  echo "  WAR: ${WAR_URI}"
  gsutil cp "$WAR_URI" "$TMP_WAR"
}

# unpack_war: unzip the WAR into a scratch dir NEXT TO the live doc root, then
# swap it in with two renames.
#
# Why not unzip straight into ${DOC_ROOT}: nginx is serving out of that dir right
# now. Unzipping in place would expose a half-written tree to live requests, and
# clearing it first would 404 every request for the duration. Unzipping to a
# sibling and renaming makes the cutover a directory swap — each request sees
# either the whole old tree or the whole new one.
#
# The swap is two renames rather than one because rename() cannot replace a
# non-empty directory: move the live tree aside, move the new one in, then delete
# the old.
#
# WEB-INF/ and META-INF/ are dropped after unpacking: they are servlet-container
# metadata with no meaning to nginx, and WEB-INF is exactly the kind of thing
# that must not become web-reachable now that a plain file server owns the tree.
unpack_war() {
  echo "Unpacking WAR into ${DOC_ROOT} (via ${STAGED_DOC_ROOT})..."

  rm -rf "${STAGED_DOC_ROOT:?}" "${OLD_DOC_ROOT:?}"
  mkdir -p "$STAGED_DOC_ROOT"

  # -q quiet, -o overwrite without prompting (unzip is interactive by default and
  # would hang a boot-time deploy waiting on stdin).
  unzip -q -o "$TMP_WAR" -d "$STAGED_DOC_ROOT"

  # Servlet-container metadata — not servable content.
  rm -rf "${STAGED_DOC_ROOT}/WEB-INF" "${STAGED_DOC_ROOT}/META-INF"

  # A bundle with no index.html is almost certainly the wrong artifact (or an
  # unzip that silently produced nothing). Catch it before the swap, while the
  # currently-served site is still untouched.
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

# ensure_site_d_include: create /etc/nginx/site.d/ and make nginx.conf include it
# from the http{} block. One-time and idempotent — the marker comment makes a
# re-run a no-op.
#
# WHY THIS PATCHES nginx.conf AT ALL
#
# A server{} block may only appear at the http{} level. The baked `nginx` image
# includes conf.d/*.conf there (holding the `_` default server) — not a place a
# new server block can go. There is therefore no existing seam for a per-host
# site, and one has to be created.
#
# conf.d/ is avoided even though it would need no patching: it is the IMAGE's
# namespace (install-nginx-static.sh writes static.conf there and deletes files
# it does not expect), and a deploy-time file in an image-owned dir invites a
# collision that stays silent until a reload.
ensure_site_d_include() {
  mkdir -p "$NGINX_SITE_D"

  # Document the contract next to the dir it governs, so it is discoverable from
  # a running VM and not only from this repo.
  cat >"${NGINX_SITE_D}/README" <<'EOF'
Per-SITE nginx server blocks (one file per hostname).

This dir is created by the per-HOST deploy scripts in build-app-install/vm/
(ziniapps-go.sh, ziniapps-www.sh, www-website.sh), NOT by the baked image. It
is included from the http{} block of /etc/nginx/nginx.conf, so each file here
holds a COMPLETE server{} block.

Contrast with /etc/nginx/app.d/, which holds bare location blocks included
INSIDE the image's `_` default server. The two are not interchangeable:
  * a server{} block in app.d is a syntax error
  * a bare location block here is a syntax error

    sudo nginx -t && sudo systemctl reload nginx
EOF

  if grep -q "$INCLUDE_MARKER" "$NGINX_CONF_MAIN"; then
    echo "site.d include already present in ${NGINX_CONF_MAIN}; leaving as is."
    return
  fi

  # The anchor line must exist — it is in the stock nginx.org nginx.conf that
  # install-nginx-static.sh leaves untouched. If it is gone, this file has been
  # customised in a way this script must not guess at: appending blindly could
  # land the include outside http{} (a hard config error) or inside some other
  # block. Fail with the manual fix rather than corrupt the config.
  if ! grep -qE '^\s*include\s+/etc/nginx/conf\.d/\*\.conf;' "$NGINX_CONF_MAIN"; then
    echo "ERROR: could not find the 'include /etc/nginx/conf.d/*.conf;' line in" >&2
    echo "  ${NGINX_CONF_MAIN}, so there is no safe place to add the site.d include." >&2
    echo "  Add this line inside the http{} block by hand, then re-run:" >&2
    echo "      ${INCLUDE_MARKER}" >&2
    echo "      include ${NGINX_SITE_D}/*.conf;" >&2
    exit 1
  fi

  echo "Adding site.d include to ${NGINX_CONF_MAIN}..."
  cp -a "$NGINX_CONF_MAIN" "${NGINX_CONF_MAIN}.deployza-bak"

  # Append after the conf.d include, preserving its indentation. The marker goes
  # on its own line above so a re-run detects it.
  sed -i -E "s|^(\s*)(include\s+/etc/nginx/conf\.d/\*\.conf;)|\1\2\n\1${INCLUDE_MARKER}\n\1include ${NGINX_SITE_D}/*.conf;|" \
    "$NGINX_CONF_MAIN"

  # Verify the edit landed rather than trusting sed's exit status (sed succeeds
  # even when it matches nothing). A failed patch here would otherwise surface as
  # a mysterious 404 later.
  if ! grep -q "$INCLUDE_MARKER" "$NGINX_CONF_MAIN"; then
    echo "ERROR: failed to add the site.d include to ${NGINX_CONF_MAIN}." >&2
    echo "  Original saved at ${NGINX_CONF_MAIN}.deployza-bak" >&2
    exit 1
  fi
}

# prepare_docs_root: create the MkDocs doc root if it does not exist. This
# script only owns the directory's EXISTENCE, not its contents — those arrive
# via docs-refresh.timer (install_docs_refresh_timer / refresh_docs_now).
# Matches /var/www/app's pattern in install-nginx.sh: baked empty, www-data
# owned, populated at deploy/refresh time rather than at image-bake time.
prepare_docs_root() {
  if [[ ! -d "$DOCS_ROOT" ]]; then
    echo "Creating docs root ${DOCS_ROOT}..."
    mkdir -p "$DOCS_ROOT"
    chown "$NGINX_USER":"$NGINX_GROUP" "$DOCS_ROOT"
    chmod 755 "$DOCS_ROOT"
  fi
}

# install_docs_refresh_timer: idempotently install + enable the systemd
# service/timer pair that keeps DOCS_ROOT in sync with GCS.
#
# Unlike ensure_site_d_include (which PATCHES an existing file and needs a
# marker to detect a prior patch), these are WHOLE files this script owns
# outright — writing the same content again is naturally a no-op, so no
# marker file is needed; `daemon-reload` + `enable --now` are both safe to
# repeat on an already-enabled unit.
#
# OnBootSec ensures a freshly (re)provisioned VM is not empty until the first
# tick; OnUnitActiveSec is the steady-state refresh cadence. Both are
# deliberately short (docs update far more often than this VM reboots) but not
# so short that a slow rsync could overlap itself — systemd timers do not
# start a new run while the previous service invocation is still active.
install_docs_refresh_timer() {
  echo "Installing ${DOCS_REFRESH_SERVICE} / ${DOCS_REFRESH_TIMER}..."

  cat >"$DOCS_REFRESH_SERVICE_PATH" <<EOF
# Installed by build-app-install/vm/${APP_NAME}.sh. Do not edit by hand: the
# next deploy overwrites this file.
[Unit]
Description=Pull the MkDocs site (api-docs / www-apidocs) from GCS into ${DOCS_ROOT}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
# Runs as root (no User=), matching how every other gsutil call in this
# script runs (inheriting whatever user launched the deploy — root at boot).
# www-data has no writable \$HOME, and gsutil needs one for its own tracker/
# config files, so running the pull itself as www-data risks a spurious
# failure with nothing wrong with the actual sync. The chown afterward is what
# makes the result readable by nginx's www-data workers instead.
#
# -d deletes local files no longer in the bucket, mirroring api-docs's own
# publish-side \`gsutil rsync -d\` (see api-docs/cloudbuild.yaml) — a removed
# or renamed page disappears here on the next tick, not just on GCS.
ExecStart=/usr/bin/gsutil rsync -r -d ${DOCS_BUCKET_URI} ${DOCS_ROOT}/
ExecStartPost=/bin/chown -R ${NGINX_USER}:${NGINX_GROUP} ${DOCS_ROOT}
EOF
  chmod 644 "$DOCS_REFRESH_SERVICE_PATH"

  cat >"$DOCS_REFRESH_TIMER_PATH" <<EOF
# Installed by build-app-install/vm/${APP_NAME}.sh. Do not edit by hand: the
# next deploy overwrites this file.
[Unit]
Description=Timer for ${DOCS_REFRESH_SERVICE}

[Timer]
# Fires shortly after boot so a fresh/replaced VM isn't serving an empty
# /docs/ until the first steady-state tick below.
OnBootSec=30s
OnUnitActiveSec=3min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$DOCS_REFRESH_TIMER_PATH"

  systemctl daemon-reload
  systemctl enable --now "$DOCS_REFRESH_TIMER"
}

# refresh_docs_now: run one docs pull synchronously during THIS deploy, so a
# freshly provisioned VM (or a manual re-run of this script) doesn't have to
# wait for the timer's first OnBootSec tick before /docs/ has content.
# --wait blocks until the oneshot service's ExecStart actually finishes, so a
# failure here surfaces in this script's own exit status rather than silently
# in a later journal entry.
refresh_docs_now() {
  echo "Running an initial docs pull..."
  systemctl start --wait "$DOCS_REFRESH_SERVICE"
}

# write_nginx_conf: generate this site's server block.
#
# A COMPLETE server{} block, because it is included at the http{} level (see
# ensure_site_d_include). GENERATED rather than copied from GCS: its content is
# fully determined by values we already have (SERVER_NAME, DOC_ROOT, DOCS_ROOT).
#
# `root` for / (the whole host serves from one tree, so the URI appends to the
# root directly), but `alias` for /docs/: alias is the right tool when a URL
# PREFIX maps to a differently-named dir (/docs/ -> ${DOCS_ROOT}, which is NOT
# a subdirectory of DOC_ROOT).
#
# NO default_server on the listen directive: that is the image's `_` block, and
# claiming it here would both be a duplicate-default error and hijack every
# unmatched Host on the VM.
#
# NO `include /etc/nginx/app.d/*.conf;` — this is the one product on this host;
# see this script's header and ziniapps-www.sh's for the same reasoning.
#
# Caching: the three no-store-ish headers go on EVERY response from this site —
# / from the WAR, /docs/ from DOCS_ROOT, and the 404 page alike — so nothing is
# reused from cache without a revalidation round-trip and a redeploy takes
# effect immediately. `always` makes them apply to error responses too
# (add_header otherwise covers only 2xx/3xx). Note that add_header in a nested
# location REPLACES any inherited set rather than adding to it, so EACH
# location that can produce a response repeats them.
write_nginx_conf() {
  echo "Writing nginx server block ${NGINX_CONF}..."

  cat >"$NGINX_CONF" <<EOF
# ${APP_NAME} — generated by build-app-install/vm/${APP_NAME}.sh. Do not edit by
# hand: the next deploy overwrites this file. A COMPLETE server block (this is
# included at the http{} level, not inside the image's default server).

server {
    listen      80;
    listen      [::]:80;

    # This block answers for this hostname only. No default_server — unmatched
    # hosts still fall through to the image's \`_\` block in conf.d/static.conf.
    server_name ${SERVER_NAME};

    root ${DOC_ROOT};
    index index.html;

    client_max_body_size 0;

    # NOTE: app.d is deliberately NOT included here — see this script's header.

    location / {
        # Plain static serving: no SPA fallback, so an unknown path is a real 404
        # rather than a silent index.html.
        try_files \$uri \$uri/ =404;

        # Never reuse a cached response without revalidating — a redeploy is
        # picked up on the next request. Applied to every file by design.
        add_header Cache-Control "no-cache, must-revalidate" always;
        add_header Pragma "no-cache" always;
        add_header Expires 0 always;
    }

    # The MkDocs site (api-docs / www-apidocs), kept in sync by
    # docs-refresh.timer rather than by this deploy — see this script's
    # header. alias, not root: this prefix maps to a directory tree that is
    # NOT under ${DOC_ROOT}.
    location /docs/ {
        alias ${DOCS_ROOT}/;
        try_files \$uri \$uri/ =404;

        add_header Cache-Control "no-cache, must-revalidate" always;
        add_header Pragma "no-cache" always;
        add_header Expires 0 always;
    }

    # The site ships its own 404 page; serve it instead of nginx's default.
    # Marked internal so it cannot be requested directly as /404.html.
    error_page 404 /404.html;
    location = /404.html {
        internal;

        # Repeated, not inherited: add_header in a nested location REPLACES the
        # inherited set rather than adding to it, so without these three the 404
        # page would be the one response from this site a browser may cache.
        add_header Cache-Control "no-cache, must-revalidate" always;
        add_header Pragma "no-cache" always;
        add_header Expires 0 always;
    }
}
EOF

  chmod 644 "$NGINX_CONF"
}

# reload_nginx: validate the whole config, then reload.
#
# `nginx -t` first, and treated as fatal: a reload with a broken config leaves
# the old workers running, so nginx would keep serving the PREVIOUS site while
# reporting success. Failing here surfaces that instead of hiding it.
#
# reload (SIGHUP), not restart: it re-reads config and cycles workers without
# dropping connections or a window where :80 is unbound.
reload_nginx() {
  echo "Validating nginx configuration..."
  if ! nginx -t; then
    echo "ERROR: nginx -t failed; not reloading. ${SITE_NAME} files are in place" >&2
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

  INSTALL_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/install"
  # Staging dir is this app's own sibling of the clone under the shared deploy
  # root (see vm-startup.sh): /tmp/deployza/repo is the clone, /tmp/deployza/
  # <APP_NAME> is ours.
  STAGE_DIR="/tmp/deployza/${APP_NAME}"
  INSTALL_PROPS="${STAGE_DIR}/install.properties"

  prepare_staging
  download_install
  load_props              # reads install.properties, derives the rest of the paths
  prepare_web_root        # create ${WEB_ROOT} if this is a first deploy
  download_war
  unpack_war              # unzip + atomic swap into ${WEB_ROOT}/<site>
  ensure_site_d_include   # one-time: create site.d + include it from nginx.conf
  prepare_docs_root       # create ${DOCS_ROOT} if this is a first deploy
  install_docs_refresh_timer # one-time: install + enable the docs-pull timer
  refresh_docs_now        # populate ${DOCS_ROOT} now rather than waiting on the timer
  write_nginx_conf        # generate the server block (files first, so the routing
                          # never points at a dir that is not populated yet)
  reload_nginx

  echo "Deployment complete."
  echo "Site should be available at: http://${SERVER_NAME}/"
  echo "Docs should be available at: http://${SERVER_NAME}/docs/"
}

main "$@"
