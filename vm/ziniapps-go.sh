#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# ziniapps-go.sh — app deploy script (the <APP_NAME>.sh that vm-startup.sh clones
# and runs as a child at boot). ziniapps-go is the landing page for
# go.ziniapps.com: a STATIC site (no database, no app.properties, no logback, no
# Tomcat), packaged as a WAR only because that is what its Maven build produces.
#
# A WAR is just a zip, and this one holds nothing but static files, so — exactly
# as assess-ui.sh does — this script UNZIPS it into an nginx document root and
# lets nginx serve it directly.
#
# WHAT MAKES THIS SCRIPT DIFFERENT FROM assess-ui.sh
#
# assess-ui/assess-exam/assess-server each serve a PATH PREFIX (/<ctx>/) inside
# the ONE `_` default server block the image bakes. This app serves the DOMAIN
# ROOT of a specific hostname instead — go.ziniapps.com/ — and a root cannot be
# expressed as a path-prefix drop-in: two apps would each need `location /` in
# the same server block, which is a config conflict.
#
# So this script writes a per-HOST server block (a `site.d` drop-in) rather than
# a per-path location block (an `app.d` drop-in). See write_nginx_conf and
# ensure_site_d_include below.
#
# WHY THE ASSESS APPS KEEP WORKING
#
# Adding a server block whose server_name matches go.ziniapps.com means nginx
# routes that Host to THIS block, not to the baked `_` default. The assess
# location blocks live in app.d and are included by the `_` block, so they would
# stop resolving on this host — go.ziniapps.com/assess-ui/ would 404.
#
# That is exactly the layout ziniapps-go depends on: its index.html links to
# "assess-ui/session-login.html" as a RELATIVE url, which only resolves if the
# assess apps are served from the same host as this landing page.
#
# The fix is one line: this server block ALSO does
#   include /etc/nginx/app.d/*.conf;
# so it inherits every existing per-path drop-in verbatim. Nothing about
# assess-ui.sh / assess-exam.sh / assess-server.sh changes, and the assess apps
# remain reachable at go.ziniapps.com/assess-ui/ etc. The `location /` in this
# file only catches what those prefixes do not — nginx always prefers the longest
# matching prefix, so /assess-ui/ still wins over /.
#
# What this script does:
#   1. downloads the app's install FOLDER and the WAR from GCS
#   2. unzips the WAR into ${WEB_ROOT}/<site>       (the served document root)
#   3. ensures http{} includes /etc/nginx/site.d/   (one-time, idempotent)
#   4. writes /etc/nginx/site.d/<site>.conf         (the per-host server block)
#   5. reloads nginx
#
# Contract (see vm-startup.sh): invoked as `<APP_NAME>.sh APP_ENV`.
# APP_NAME is fixed to "ziniapps-go" here (this IS that script); the single
# argument is APP_ENV ("$1").
#
# Requires the tomcat-nginx-mysql image (or any image whose install-nginx.sh has
# run): this script needs /etc/nginx/app.d/ to exist (it includes it from the
# server block it writes) and creates /etc/nginx/site.d/ alongside it.
#
# GCS layout (${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/):
#   install/                       the whole config folder, copied verbatim:
#     install.properties             ALL deploy values (see the key list below)
#   <install.war>                  the versioned WAR
#
# install.properties is the single source of truth for the deploy; NOTHING is
# derived by this script. Keys used:
#   install.war                  WAR filename to download and unzip
#   install.server.name          the hostname this block answers for, e.g.
#                                go.ziniapps.com. This is what makes the app a
#                                SITE rather than a path — it has no analogue in
#                                the assess-* scripts.
#   install.site.name            OPTIONAL. bare name used for the doc-root dir
#                                and the conf filename; defaults to the app name
#                                (ziniapps-go). Only set it if two deploys of
#                                this app must coexist on one VM.
#   install.web.root             OPTIONAL. nginx static root holding the per-site
#                                dirs; defaults to /var/www/site. NOTE this is a
#                                DIFFERENT default from the assess-* scripts
#                                (/var/www/app) — see DEFAULT_WEB_ROOT below.
#
# Caching — every response from this app is served with
#   Cache-Control: no-cache, must-revalidate
#   Pragma: no-cache
#   Expires: 0
# so a browser always revalidates before reusing anything, and a redeploy is
# picked up on the next request rather than after a cache expiry. This matches
# the assess-* scripts and is applied to EVERY file, not just index.html.
#
# Logs — this script only echoes to stdout/stderr; it is NOT its own systemd
# unit. Where its output lands depends on how it is invoked:
#   * At boot (launched by vm-startup.sh): its output is inherited by the
#     vm-startup.service unit, so it lands in that journal:
#       sudo journalctl -u vm-startup.service -b -f
#   * Run manually over SSH: output goes to your terminal; capture with
#       sudo bash ziniapps-go.sh <APP_ENV> 2>&1 | tee /tmp/ziniapps-go.log
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
# This script IS the ziniapps-go installer, so APP_NAME is fixed rather than
# taken from the launcher. (vm-startup.sh resolves this very file by that name —
# <clone>/vm/ziniapps-go.sh — so the name is already implied.) Only APP_ENV
# varies (development/production) and is the sole argument.
readonly APP_NAME="ziniapps-go"

# The service that serves the deployed files, and the user it runs its workers
# as. nginx's master runs as root but its workers drop to this user, so the
# static files must be readable by it.
readonly NGINX_SERVICE="nginx"
readonly NGINX_USER="www-data"
readonly NGINX_GROUP="www-data"

# The per-PATH routing seam baked EMPTY into the tomcat-nginx-mysql image. This
# script writes NOTHING here — it is referenced only so the server block this
# script generates can include it, keeping the assess-* apps reachable on this
# host (see the header). Its existence is the image check in require_tools.
readonly NGINX_APP_D="/etc/nginx/app.d"

# The per-HOST routing seam, created by this script (the image does not bake it —
# it predates any host-based app). One file per site: <site>.conf, each holding a
# complete server{} block. Distinct from app.d both in content (server blocks vs.
# bare location blocks) and in where it is included from (http{} level, not
# inside a server block) — mixing the two would be a syntax error either way.
readonly NGINX_SITE_D="/etc/nginx/site.d"

# nginx's main config, where the one-time site.d include is added. Editing this
# file is what makes a per-host block possible at all: an http{}-level include is
# the only place a server{} block may appear, and the baked config has no such
# include.
readonly NGINX_CONF_MAIN="/etc/nginx/nginx.conf"

# Marker comment written next to the generated include line, used to detect an
# already-patched nginx.conf. Grepping for the marker rather than for the include
# path means a hand-written include with different spacing is not mistaken for
# ours (and ours is not duplicated).
readonly INCLUDE_MARKER="# DEPLOYZA-SITE-D"

# Fallback for install.web.root — the parent holding the per-SITE doc roots.
#
# Deliberately NOT /var/www/app (the assess-* default): that dir holds per-PATH
# apps served by the `_` block, and the two models should not share a namespace —
# a site named the same as a context path would otherwise collide silently.
# Unlike /var/www/app this dir is not baked by the image, so this script creates
# it (see prepare_web_root).
readonly DEFAULT_WEB_ROOT="/var/www/site"

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

  # app.d is created by the image's install-nginx.sh. This script writes nothing
  # into it, but the server block it generates INCLUDES it — and nginx treats a
  # missing include path as a hard config error (unlike the *.conf wildcard,
  # which may legally match zero files). A missing dir here also means this host
  # was not built from an nginx-enabled image at all.
  if [[ ! -d "$NGINX_APP_D" ]]; then
    echo "ERROR: ${NGINX_APP_D} does not exist — this host was not built from an" >&2
    echo "  nginx-enabled image (see build-vm-images/scripts/ubuntu/install-nginx.sh)." >&2
    exit 1
  fi

  if [[ ! -f "$NGINX_CONF_MAIN" ]]; then
    echo "ERROR: ${NGINX_CONF_MAIN} not found — cannot install the site.d include." >&2
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
load_props() {
  require_prop APP_WAR_FILE 'install.war'
  require_prop SERVER_NAME  'install.server.name'
  default_prop SITE_NAME    'install.site.name' "$APP_NAME"
  default_prop WEB_ROOT     'install.web.root'  "$DEFAULT_WEB_ROOT"

  # Guard every value that gets interpolated into a path we rm -rf or into the
  # generated nginx config.
  #
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

  # WAR: staged under its real versioned name so the staging dir shows exactly
  # what was deployed; unzipped into ${WEB_ROOT}/<site>.
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
#
# Unlike /var/www/app (baked empty and www-data-owned by install-nginx.sh), the
# site root is this script's own convention and no image creates it. Creating it
# here rather than requiring a manual mkdir keeps a first deploy onto a fresh VM
# a one-step operation.
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
# A server{} block may only appear at the http{} level. The baked image includes
# conf.d/*.conf there (holding the `_` default server) and app.d/*.conf INSIDE
# that server — neither is a place a new server block can go. There is therefore
# no existing seam for a per-host site, and one has to be created.
#
# WHY NOT DROP THE SERVER BLOCK INTO conf.d/ INSTEAD
#
# It would work today with no patching at all: conf.d/*.conf is already included
# at the http level. It is avoided because conf.d is the IMAGE's namespace —
# install-nginx.sh writes tomcat.conf there and removes files it does not expect
# (it deletes the stock default.conf). A deploy-time file in an image-owned dir
# invites exactly the kind of collision that is silent until a reload. site.d is
# unambiguously the deploy's.
#
# The insert targets the `include /etc/nginx/conf.d/*.conf;` line that the stock
# nginx.org nginx.conf carries inside http{}. Appending after it keeps the new
# include inside http{} without this script having to parse brace nesting, and
# ORDER matters: conf.d holds the `_` default_server, and a default_server must
# be defined before... actually no — nginx resolves default_server irrespective
# of order. The reason to go after is simpler: it reads as "the image's config,
# then ours".
ensure_site_d_include() {
  mkdir -p "$NGINX_SITE_D"

  # Document the contract next to the dir it governs, so it is discoverable from
  # a running VM and not only from this repo. Rewritten every deploy (cheap, and
  # keeps it accurate if the contract changes).
  cat >"${NGINX_SITE_D}/README" <<'EOF'
Per-SITE nginx server blocks (one file per hostname).

This dir is created by the ziniapps-* deploy scripts in build-app-install/vm/,
NOT by the baked image. It is included from the http{} block of
/etc/nginx/nginx.conf, so each file here holds a COMPLETE server{} block.

Contrast with /etc/nginx/app.d/, which holds bare location blocks included
INSIDE the image's `_` default server. The two are not interchangeable:
  * a server{} block in app.d is a syntax error
  * a bare location block here is a syntax error

A site block that must also expose the per-path apps (assess-ui, assess-exam,
assess-server) includes app.d itself:

    include /etc/nginx/app.d/*.conf;

Without that line, those paths resolve ONLY on hostnames that fall through to
the `_` default server.

    sudo nginx -t && sudo systemctl reload nginx
EOF

  if grep -q "$INCLUDE_MARKER" "$NGINX_CONF_MAIN"; then
    echo "site.d include already present in ${NGINX_CONF_MAIN}; leaving as is."
    return
  fi

  # The anchor line must exist — it is in the stock nginx.org nginx.conf that
  # install-nginx.sh leaves untouched. If it is gone, this file has been
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

# write_nginx_conf: generate this site's server block.
#
# Unlike the assess-* drop-ins this is a COMPLETE server{} block, because it is
# included at the http{} level (see ensure_site_d_include). It is GENERATED
# rather than copied from GCS: its content is fully determined by two values we
# already have (SERVER_NAME and DOC_ROOT).
#
# `root` rather than `alias` here — the reverse of assess-ui.sh. alias is the
# right tool when a URL PREFIX maps to a differently-named dir (/assess-ui/ ->
# /var/www/app/assess-ui/). This block serves the whole host from one tree, so
# the URI appends to the root directly and `root` states that plainly.
#
# NO default_server on the listen directive: that is the image's `_` block, and
# claiming it here would both be a duplicate-default error and hijack every
# unmatched Host on the VM. This block answers for its server_name only;
# everything else keeps falling through to the baked default exactly as before.
#
# include app.d: keeps /assess-ui/, /assess-exam/ and /assess-server/ reachable on
# this host. Longest-prefix matching means those locations win over `location /`
# below, so the landing page's relative links resolve. See the header for why
# this line is load-bearing rather than defensive.
#
# Caching: the three no-store-ish headers go on EVERY response this block itself
# serves, so nothing is reused from cache without a revalidation round-trip and a
# redeploy takes effect immediately. `always` makes them apply to error responses
# too (add_header otherwise covers only 2xx/3xx). Note that add_header in a nested
# location REPLACES any inherited set rather than adding to it, so each location
# repeats them — which is also why the included app.d drop-ins carry their own
# copies rather than relying on anything set here.
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
    # hosts still fall through to the image's \`_\` block in conf.d/tomcat.conf.
    server_name ${SERVER_NAME};

    root ${DOC_ROOT};
    index index.html;

    # Let the app tier decide its own body limit, matching the image's default
    # server; 0 disables nginx's 1m cap.
    client_max_body_size 0;

    # Per-PATH apps (assess-ui, assess-exam, assess-server) written by their own
    # deploy scripts. Included here so they stay reachable on this host now that
    # it no longer falls through to the default server. Their /<ctx>/ prefixes
    # are longer than "/" below, so nginx matches them first.
    include ${NGINX_APP_D}/*.conf;

    # The landing page itself: everything the prefixes above did not claim.
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
}
EOF

  chmod 644 "$NGINX_CONF"
}

# reload_nginx: validate the whole config, then reload.
#
# `nginx -t` first, and treated as fatal: a reload with a broken config leaves
# the old workers running, so nginx would keep serving the PREVIOUS site while
# reporting success. Failing here surfaces that instead of hiding it. The test
# covers every app.d and site.d file, so a sibling's broken config fails this too
# — correct, since the reload would not have applied either way.
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
  load_props              # reads install.properties, derives the rest of the paths
  prepare_web_root        # create ${WEB_ROOT} if this is a first deploy
  download_war
  unpack_war              # unzip + atomic swap into ${WEB_ROOT}/<site>
  ensure_site_d_include   # one-time: create site.d + include it from nginx.conf
  write_nginx_conf        # generate the server block (files first, so the routing
                          # never points at a dir that is not populated yet)
  reload_nginx

  echo "Deployment complete."
  echo "Site should be available at: http://${SERVER_NAME}/"
}

main "$@"
