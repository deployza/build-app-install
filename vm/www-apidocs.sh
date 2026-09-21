#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# www-apidocs.sh — app deploy script for the API documentation site served at
# https://www.deployza.com/api-docs/.
#
# SPLIT OUT OF www-website.sh. That script used to do two unrelated jobs: serve
# the marketing site at / (a WAR from GCS) and build+serve the MkDocs API docs
# at a path under it. They share nothing but a hostname — different content,
# different source (a GCS artifact vs. a git checkout built on this VM),
# different update trigger (a WAR release vs. a docs commit) — so they are now
# two scripts, run together by www-install.sh.
#
# THIS IS A per-PATH APP (see this repo's CLAUDE.md — "Two kinds of app"): it
# writes BARE LOCATION BLOCKS to /etc/nginx/app.d/, never a server{} block. The
# host's server block is written by www-website.sh, which includes
# /etc/nginx/app.d/*.conf — that include is what makes /api-docs/ reachable on
# www.deployza.com. The two scripts therefore touch DIFFERENT nginx files and
# neither overwrites the other.
#
# Ordering is NOT load-bearing: nginx resolves the app.d include at reload time,
# not at write time, so either script may run first. www-install.sh runs the
# site first anyway, so that every reload along the way tests a complete config.
#
# WHAT THIS SCRIPT DEPLOYS — AND WHERE IT COMES FROM
#
# Nothing from GCS. Unlike every other script in this folder there is no
# install/ folder, no install.properties and no WAR: the docs are BUILT ON THIS
# VM from a `www-apidocs` git checkout (DOCS_REPO_URL) by
# /usr/local/bin/docs-refresh, which this script installs. Every value it needs
# is a constant below rather than a deploy-time property, because there is no
# artifact folder to put properties in — see parse_args for why APP_ENV is still
# required even though it selects nothing.
#
# This REPLACED an earlier design where Cloud Build ran `mkdocs build` and
# published `site/` to GCS for this VM to `gsutil rsync` down — see
# build-vm-images/docs/apidocs-vm-build-plan.md for why: it cuts out a hop, at
# the cost of this VM needing outbound internet (an egress-only external IP,
# build-terraform/website/vms.tf) and read access to a GitHub PAT (Secret
# Manager, cross-project grant — see fetch_github_pat in the generated
# docs-refresh script). www-apidocs' own Cloud Build pipeline is gone as of this
# design; nothing publishes to GCS for this path anymore.
#
# What this script does:
#   1. ensures /etc/nginx/app.d/ exists              (the drop-in seam)
#   2. creates ${DOCS_ROOT}                          (empty; contents come next)
#   3. installs the on-demand docs-refresh service   (one-time, idempotent)
#   4. writes /etc/nginx/app.d/www-apidocs.conf      (the /api-docs/ locations)
#   5. reloads nginx
#   6. builds the docs once, now                     (refresh_docs_now)
#
# Caching: every response this app can produce carries
#   Cache-Control: no-cache, must-revalidate
#   Pragma: no-cache
#   Expires: 0
# matching the whole-host policy www-website.sh applies to /. Each location
# repeats the three headers rather than inheriting them: add_header in a nested
# location REPLACES any inherited set rather than adding to it, and an app.d
# drop-in is nested inside someone else's server block by definition.
#
# Contract (see vm-startup.sh): invoked as `<APP_NAME>.sh APP_ENV`.
# APP_NAME is fixed to "www-apidocs" here (this IS that script); the single
# argument is APP_ENV ("$1").
#
# Requires the `nginx` image (build-vm-images/images/ubuntu/nginx/) — nginx,
# git, gcloud and the baked mkdocs venv (install-mkdocs.sh). No Tomcat, no
# MySQL, no unzip, no gsutil.
#
# Logs — this script only echoes to stdout/stderr; it is NOT its own systemd
# unit. Where its output lands depends on how it is invoked:
#   * At boot (via www-install.sh, launched by vm-startup.sh): its output is
#     inherited by the vm-startup.service unit, so it lands in that journal:
#       sudo journalctl -u vm-startup.service -b -f
#     www-install.sh also tees a per-child copy to /tmp/deployza/logs/.
#   * Run manually over SSH: output goes to your terminal; capture with
#       sudo bash www-apidocs.sh <APP_ENV> 2>&1 | tee /tmp/www-apidocs.log
#
# This script only INSTALLS — the docs are then served by the separate 'nginx'
# service and rebuilt by the separate 'docs-refresh' service, whose logs are
# elsewhere:
#   sudo journalctl -u nginx -f
#   sudo journalctl -u docs-refresh.service
#   sudo tail -f /var/log/nginx/access.log /var/log/nginx/error.log
# -----------------------------------------------------------------------------

# =============================================================================
# Variable declarations
# =============================================================================

# --- Fixed identity -----------------------------------------------------------
# This script IS the www-apidocs installer, so APP_NAME is fixed rather than
# taken from the launcher, exactly like its siblings. Only APP_ENV varies and is
# the sole argument.
readonly APP_NAME="www-apidocs"

# GCS_BASE_URL, STAGE_ROOT and the NGINX_* seams live in vm/common.sh, beside
# this script. This script uses only the NGINX_* ones (it downloads nothing),
# but sources the file whole like every sibling rather than re-declaring
# constants. Everything below is this app's own and deliberately stays here.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# The URL prefix the docs answer on, and the doc root behind it. Kept as one
# pair because changing either alone breaks the mapping.
#
# DOCS_ROOT is deliberately NOT under /var/www/site/<site> (the marketing site's
# tree, owned by www-website.sh's WAR unpack) and not under /var/www/app (the
# per-PATH default for WAR-derived bundles): this content is neither. The WAR's
# atomic-swap unpack and the docs' atomic-swap rebuild are two independent
# update mechanisms with different triggers, and must not share a directory tree
# — that separation is the whole reason these are two scripts.
readonly DOCS_URL_PREFIX="/api-docs"
readonly DOCS_ROOT="/var/www/api-docs"

# The app.d drop-in this script owns. Named after APP_NAME rather than after the
# URL prefix: the filename states which script overwrites it on every deploy.
readonly NGINX_CONF="${NGINX_APP_D}/${APP_NAME}.conf"

# Source repo the docs are built FROM. Always `main`, regardless of this VM's
# APP_ENV: www-apidocs publishes exactly one docs site (no per-environment
# split), so there is nothing an APP_ENV-scoped ref would select between.
readonly DOCS_REPO_URL="https://github.com/deployza/www-apidocs.git"

# Persistent clone, kept across runs for a fast `git fetch` rather than a full
# clone every time (see docs-refresh, generated below). A dotfile under /var/www
# so it is obviously scratch and never mistaken for a served tree.
readonly DOCS_SRC_DIR="/var/www/.www-apidocs-src"

# The mkdocs + plugins venv baked by build-vm-images' nginx flavor
# (install-mkdocs.sh, versions pinned there to match www-apidocs'
# requirements.txt). NOT installed here: PyPI availability must not be a
# deploy-time dependency, same reasoning as graphify's baked venv on the mcp
# image.
readonly MKDOCS_VENV="/opt/mkdocs/venv"

# Secret Manager id + PROJECT of the read-only GitHub PAT docs-refresh clones
# with. Shared with the `mcp` flavor's own PAT (build-terraform's
# builds/secrets.tf, secret id `github-readonly-pat` — renamed from
# `mcp-github-pat` now that it's not mcp-only) rather than minting a second one
# — see build-vm-images/docs/apidocs-vm-build-plan.md. It lives in
# tools-tech-463909, a different project than this VM's own
# (www-website-460108), so the project must be named explicitly; gcp-secret's
# metadata-server trick (read the CALLING VM's own project) does not apply to a
# cross-project secret. Reading it requires the per-secret grant in
# build-terraform's builds/secrets.tf — without it this fails closed with a 403,
# not silently.
readonly GITHUB_PAT_SECRET="github-readonly-pat"
readonly GITHUB_PAT_PROJECT="tools-tech-463909"

# The on-demand docs builder's systemd unit — no timer (see
# install_docs_refresh_service's header for why).
readonly DOCS_REFRESH_SERVICE="docs-refresh.service"
readonly DOCS_REFRESH_SERVICE_PATH="/etc/systemd/system/${DOCS_REFRESH_SERVICE}"
readonly DOCS_REFRESH_SCRIPT="/usr/local/bin/docs-refresh"

# --- Populated in main() from the APP_ENV argument ----------------------------
APP_ENV=""              # the single positional argument ("$1"): dev/production

# =============================================================================
# Functions
# =============================================================================

# parse_args: validate the launcher contract and set APP_ENV.
#
# APP_ENV is required but, uniquely in this folder, selects NOTHING: there are
# no per-environment artifacts for this app (no GCS folder at all) and the docs
# always come from `main`. It stays mandatory rather than optional so this
# script obeys the same launcher contract as every sibling and can sit in any
# orchestrator's CHILD_SCRIPTS without a special case.
parse_args() {
  APP_ENV="${1:-}"
  if [[ -z "$APP_ENV" ]]; then
    echo "ERROR: APP_ENV is required." >&2
    echo "Usage: $0 APP_ENV" >&2
    exit 1
  fi
  echo "APP_ENV=${APP_ENV} accepted for the launcher contract; this app has no"
  echo "  per-environment artifacts — the docs always build from ${DOCS_REPO_URL} (main)."
}

# require_tools: fail early and by name if the host is missing something we need.
#
# No gsutil and no unzip in this list, unlike every sibling: this script
# downloads no GCS artifact and unpacks no WAR.
require_tools() {
  local tool missing=()
  for tool in nginx git gcloud; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done

  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: required command(s) not found: ${missing[*]}" >&2
    echo "  This script targets the nginx image (nginx + git + gcloud present)." >&2
    exit 1
  fi

  # Fail loudly at deploy time, not later at the first docs-refresh run: the
  # mkdocs venv is baked by build-vm-images' nginx flavor (install-mkdocs.sh),
  # so its absence means this VM booted an image that predates that installer,
  # or a non-nginx flavor entirely.
  if [[ ! -x "${MKDOCS_VENV}/bin/mkdocs" ]]; then
    echo "ERROR: ${MKDOCS_VENV}/bin/mkdocs not found." >&2
    echo "  This image is missing the baked mkdocs venv (build-vm-images'" >&2
    echo "  install-mkdocs.sh) — rebuild/redeploy from the nginx image family." >&2
    exit 1
  fi
}

# ensure_app_d: create the per-PATH drop-in dir if it is missing.
#
# On the tomcat-nginx-mysql image this dir is baked (install-nginx.sh) and the
# per-path scripts merely write into it. The Tomcat-free `nginx` flavor this app
# targets ships NO app routing at all (install-nginx-static.sh), so on this host
# the dir may legitimately not exist yet — and nothing else on the VM creates
# it. Creating it here is idempotent and keeps a first boot from failing on an
# ordering detail. www-website.sh does the same before including it, so whichever
# of the two runs first wins and the other finds the dir already there.
ensure_app_d() {
  if [[ ! -d "$NGINX_APP_D" ]]; then
    echo "Creating app drop-in dir ${NGINX_APP_D}..."
    mkdir -p "$NGINX_APP_D"
    chmod 755 "$NGINX_APP_D"
  fi
}

# prepare_docs_root: create the MkDocs doc root if it does not exist. This
# function owns the directory's EXISTENCE only, not its contents — those arrive
# via docs-refresh.service (install_docs_refresh_service / refresh_docs_now).
# Matches /var/www/app's pattern in install-nginx.sh: created empty, www-data
# owned, populated at deploy/refresh time.
prepare_docs_root() {
  if [[ ! -d "$DOCS_ROOT" ]]; then
    echo "Creating docs root ${DOCS_ROOT}..."
    mkdir -p "$DOCS_ROOT"
    chown "$NGINX_USER":"$NGINX_GROUP" "$DOCS_ROOT"
    # 755: nginx workers must traverse it; it holds only public static content.
    chmod 755 "$DOCS_ROOT"
  fi
}

# install_docs_refresh_service: idempotently install /usr/local/bin/docs-refresh
# (the actual clone+build+swap logic) plus the oneshot systemd service that runs
# it.
#
# NO TIMER — this is deliberately a MANUAL/on-demand process, not a continuous
# background one: DOCS_ROOT is (re)built exactly once per run of THIS script
# (refresh_docs_now, called from main() below), the same "boot-time-only, re-run
# to update" model every app here follows (build-design.md §5/§8: push new
# content, then re-run the startup on the box). Updating the docs later —
# without a full redeploy — means either `sudo google_metadata_script_runner
# startup` (re-runs the whole orchestrator) or `sudo systemctl start
# docs-refresh.service` directly, the latter being strictly cheaper since it
# skips the nginx steps entirely.
#
# WHY A SEPARATE SCRIPT FILE, not an inline ExecStart: the logic (fetch a
# secret, clone-or-fetch, mkdocs build, atomic swap) is real multi-step shell,
# and a heredoc'd ExecStart of that size is unreadable and hard to shellcheck.
# Written to /usr/local/bin rather than baked into the image, matching this
# repo's own split (build-vm-images bakes the toolchain; deploy scripts own
# deploy logic) — see build-vm-images/docs/apidocs-vm-build-plan.md.
#
# These are WHOLE files this script owns outright — writing the same content
# again is naturally a no-op, so no marker file is needed and `daemon-reload` is
# safe to repeat.
install_docs_refresh_service() {
  echo "Installing ${DOCS_REFRESH_SCRIPT} and ${DOCS_REFRESH_SERVICE}..."

  cat >"$DOCS_REFRESH_SCRIPT" <<EOF
#!/bin/bash
# docs-refresh — build www-apidocs' MkDocs site and swap it into ${DOCS_ROOT}.
# Installed by build-app-install/vm/${APP_NAME}.sh (install_docs_refresh_service).
# Do not edit by hand: the next deploy overwrites this file.
#
# ExecStart of ${DOCS_REFRESH_SERVICE} — on demand only, no timer: run once per
# deploy of ${APP_NAME}.sh, or by hand with
# \`sudo systemctl start ${DOCS_REFRESH_SERVICE}\`. A failed build never touches
# the live site: DOCS_ROOT is only replaced after \`mkdocs build --strict\` exits
# 0, so the last good build keeps serving and this run's failure only shows up
# in the journal (sudo journalctl -u ${DOCS_REFRESH_SERVICE}).
#
# NO \`set -x\` — this script's environment briefly holds GITHUB_PAT. See
# fetch_github_pat.
set -euo pipefail

DOCS_SRC_DIR="${DOCS_SRC_DIR}"
DOCS_ROOT="${DOCS_ROOT}"
DOCS_STAGED="\${DOCS_ROOT}.new"
DOCS_OLD="\${DOCS_ROOT}.old"
MKDOCS_VENV="${MKDOCS_VENV}"
GITHUB_PAT_SECRET="${GITHUB_PAT_SECRET}"
GITHUB_PAT_PROJECT="${GITHUB_PAT_PROJECT}"
NGINX_USER="${NGINX_USER}"
NGINX_GROUP="${NGINX_GROUP}"

log() { echo "[docs-refresh] \$*"; }

ASKPASS_SCRIPT="\$(mktemp)"
cleanup() {
  rm -f "\$ASKPASS_SCRIPT"
  unset GITHUB_PAT
}
trap cleanup EXIT

# fetch_github_pat: read the read-only GitHub PAT into process memory only, then
# point GIT_ASKPASS at a throwaway helper so git never sees the token on argv or
# writes it into a clone URL / .git/config. Same mechanism as build-vm-images'
# mcp flavor (gcp-secret + mcp-git-askpass), reimplemented inline here rather
# than shared with a baked binary: this is the only thing on this VM that ever
# clones a repo, so there is no second caller to share one with.
# GITHUB_PAT_PROJECT is passed explicitly (unlike mcp's gcp-secret, which reads
# the CALLING VM's own project off the metadata server) because this secret
# lives in a different project than this VM's own — see this script's installer
# (build-app-install/vm/${APP_NAME}.sh) for the grant this depends on.
fetch_github_pat() {
  GITHUB_PAT="\$(gcloud secrets versions access latest \\
    --secret="\$GITHUB_PAT_SECRET" --project="\$GITHUB_PAT_PROJECT")"
  export GITHUB_PAT

  cat >"\$ASKPASS_SCRIPT" <<'ASKPASS'
#!/bin/bash
case "\$1" in
    Username*) printf 'x-access-token\\n' ;;
    *) printf '%s\\n' "\${GITHUB_PAT:?}" ;;
esac
ASKPASS
  chmod 700 "\$ASKPASS_SCRIPT"
  export GIT_ASKPASS="\$ASKPASS_SCRIPT"
  export GIT_TERMINAL_PROMPT=0
}

# sync_repo: shallow-clone on first run, fast-forward to origin/main after.
# Depth 1 throughout: mkdocs builds the working tree, not the history.
sync_repo() {
  if [[ -d "\${DOCS_SRC_DIR}/.git" ]]; then
    git -C "\$DOCS_SRC_DIR" fetch --depth 1 origin main
    git -C "\$DOCS_SRC_DIR" reset --hard FETCH_HEAD
    git -C "\$DOCS_SRC_DIR" clean -fdx
  else
    mkdir -p "\$(dirname "\$DOCS_SRC_DIR")"
    git clone --depth 1 --branch main "${DOCS_REPO_URL}" "\$DOCS_SRC_DIR"
  fi
}

# build_site: mkdocs build --strict into a scratch dir NEXT TO the live
# DOCS_ROOT, mirroring the atomic-swap pattern www-website.sh uses for its own
# WAR — a failed or in-progress build must never be visible to nginx.
build_site() {
  rm -rf "\${DOCS_STAGED:?}"
  ( cd "\$DOCS_SRC_DIR" && "\${MKDOCS_VENV}/bin/mkdocs" build --strict --site-dir "\$DOCS_STAGED" )
  chown -R "\${NGINX_USER}:\${NGINX_GROUP}" "\$DOCS_STAGED"
}

# swap_in: two-rename swap — rename() cannot replace a non-empty directory.
swap_in() {
  rm -rf "\${DOCS_OLD:?}"
  if [[ -d "\$DOCS_ROOT" ]]; then
    mv "\$DOCS_ROOT" "\$DOCS_OLD"
  fi
  mv "\$DOCS_STAGED" "\$DOCS_ROOT"
  rm -rf "\${DOCS_OLD:?}"
}

main() {
  fetch_github_pat
  log "syncing www-apidocs..."
  sync_repo
  log "building..."
  build_site
  swap_in
  log "done — \${DOCS_ROOT} updated"
}

main "\$@"
EOF
  chmod 750 "$DOCS_REFRESH_SCRIPT"
  chown root:root "$DOCS_REFRESH_SCRIPT"

  cat >"$DOCS_REFRESH_SERVICE_PATH" <<EOF
# Installed by build-app-install/vm/${APP_NAME}.sh. Do not edit by hand: the
# next deploy overwrites this file.
#
# NOT enabled and NO [Install] section — deliberately on-demand only. Run by
# that script once per deploy (refresh_docs_now) and otherwise by hand:
#   sudo systemctl start ${DOCS_REFRESH_SERVICE}
[Unit]
Description=Build the MkDocs site (www-apidocs) into ${DOCS_ROOT}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
# Runs as root (no User=): needs to reach Secret Manager as this VM's own
# service account, write scratch files, and chown the result to ${NGINX_USER}.
# See ${DOCS_REFRESH_SCRIPT} for what actually runs.
ExecStart=${DOCS_REFRESH_SCRIPT}
EOF
  chmod 644 "$DOCS_REFRESH_SERVICE_PATH"

  systemctl daemon-reload
}

# write_nginx_conf: generate this app's location blocks.
#
# BARE LOCATION BLOCKS ONLY — no server{} wrapper. This file is included from
# INSIDE a server block (www-website.sh's, and the image's `_` default server
# where one exists), so a server{} here would be a syntax error. GENERATED
# rather than copied from GCS: its content is fully determined by two constants
# above, DOCS_URL_PREFIX and DOCS_ROOT.
#
# `alias`, not `root`: alias is the right tool when a URL PREFIX maps to a
# differently-named dir (${DOCS_URL_PREFIX}/ -> ${DOCS_ROOT}, which is not a
# subdirectory of whatever `root` the enclosing server block set).
#
# Longest-prefix matching means these locations win over the enclosing block's
# `location /`, so the marketing site's root handler never sees these requests.
#
# Caching: the three no-store-ish headers are repeated in EACH location rather
# than inherited — add_header in a nested location REPLACES any inherited set
# rather than adding to it, and this file is nested by definition. `always`
# makes them apply to error responses too (add_header otherwise covers only
# 2xx/3xx).
write_nginx_conf() {
  echo "Writing nginx location blocks ${NGINX_CONF}..."

  cat >"$NGINX_CONF" <<EOF
# ${APP_NAME} — generated by build-app-install/vm/${APP_NAME}.sh. Do not edit by
# hand: the next deploy overwrites this file. BARE location blocks (this is
# included INSIDE a server block, so it must not contain one).

# Bare ${DOCS_URL_PREFIX} (no trailing slash) does NOT match
# \`location ${DOCS_URL_PREFIX}/\` below — nginx prefix-location matching
# requires the trailing slash to already be in the request URI, so without this
# it falls through to the enclosing server's \`location /\` (the marketing
# site's WAR root), where nothing by that name exists, and 404s. Redirect first
# so both spellings reach the docs site.
location = ${DOCS_URL_PREFIX} {
    return 301 ${DOCS_URL_PREFIX}/;
}

# The MkDocs site (www-apidocs), built by ${DOCS_REFRESH_SERVICE} rather than by
# this deploy directly — see this script's header. alias, not root: this prefix
# maps to a directory tree that is not under the enclosing server's root.
location ${DOCS_URL_PREFIX}/ {
    alias ${DOCS_ROOT}/;
    index index.html;

    # Plain static serving: no SPA fallback, so an unknown path is a real 404
    # rather than a silent index.html.
    try_files \$uri \$uri/ =404;

    client_max_body_size 0;

    # Never reuse a cached response without revalidating — a docs refresh is
    # picked up on the next request. Repeated here, not inherited: add_header in
    # a nested location REPLACES the inherited set.
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
# the old workers running, so nginx would keep serving the PREVIOUS config while
# reporting success. Failing here surfaces that instead of hiding it.
#
# Note this validates the ENTIRE config, including www-website.sh's server block
# and any other app.d drop-in — a sibling's broken file fails this too. That is
# the point: a reload is all-or-nothing anyway.
#
# reload (SIGHUP), not restart: it re-reads config and cycles workers without
# dropping connections or a window where :80 is unbound.
reload_nginx() {
  echo "Validating nginx configuration..."
  if ! nginx -t; then
    echo "ERROR: nginx -t failed; not reloading. ${NGINX_CONF} is in place but" >&2
    echo "  the routing is not live. Fix the config above and run:" >&2
    echo "    sudo nginx -t && sudo systemctl reload ${NGINX_SERVICE}" >&2
    exit 1
  fi

  echo "Reloading ${NGINX_SERVICE}..."
  systemctl reload "$NGINX_SERVICE"
}

# refresh_docs_now: run one docs build synchronously during THIS deploy — the
# only time DOCS_ROOT is (re)built automatically; see
# install_docs_refresh_service's header for the manual/on-demand model.
#
# DELIBERATELY NON-FATAL, and called LAST in main() (after write_nginx_conf +
# reload_nginx). A docs build needs the network, a cross-project secret and a
# clean `mkdocs build --strict`; any of those can fail transiently, and under
# this script's own `set -euo pipefail` an unguarded `systemctl start --wait`
# would then abort the run. Ordering it last means there is nothing left to
# abort here; keeping it non-fatal additionally means this script still exits 0,
# so an orchestrator's `set -e` does not stop the remaining children over a docs
# build (see www-install.sh). The routing is already live by this point — a
# failed build just means ${DOCS_ROOT} still holds the last good site, or, on a
# first deploy, nothing yet and ${DOCS_URL_PREFIX}/ 404s.
refresh_docs_now() {
  echo "Running an initial docs build..."
  if ! systemctl start --wait "$DOCS_REFRESH_SERVICE"; then
    echo "WARNING: initial docs build failed — ${DOCS_ROOT} may be empty or" >&2
    echo "  stale. The rest of the host is unaffected. Retry with:" >&2
    echo "    sudo systemctl start ${DOCS_REFRESH_SERVICE}" >&2
    echo "  and see why with:" >&2
    echo "    sudo journalctl -u ${DOCS_REFRESH_SERVICE}" >&2
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  parse_args "$@"
  require_tools

  ensure_app_d                 # create the drop-in dir if the image did not
  prepare_docs_root            # create ${DOCS_ROOT} if this is a first deploy
  install_docs_refresh_service # one-time: install the on-demand docs-build service
  write_nginx_conf             # generate the ${DOCS_URL_PREFIX}/ location blocks
  reload_nginx
  refresh_docs_now             # build+swap ${DOCS_ROOT} now, this deploy — LAST
                               # and non-fatal (see its own header)

  echo "Deployment complete."
  echo "Docs should be available at ${DOCS_URL_PREFIX}/ on this host — the"
  echo "  hostname and its server block belong to www-website.sh."
}

main "$@"
