# vm/common.sh — constants shared by every VM deploy script under this folder.
#
# IT SITS AT THE vm/ ROOT, above the three layer folders. vm/ is organised by
# LAYER, not by product:
#
#   vm/apps/<app>/<app>.sh          install one app
#   vm/apps/<app>/receiver.yaml     what that app writes, when it writes
#                                   somewhere no system fragment reaches
#                                   (assess-server only, today)
#   vm/systems/<server>.yaml        what a given server writes — RECEIVERS ONLY
#   vm/systems/_base.yaml           journald + hostmetrics; every host, always
#   vm/instances/<vm>/install.sh    install everything one HOST runs
#   vm/instances/<vm>/exporter.yaml that host's processors AND exporters
#   vm/instances/<vm>/pipeline.yaml that host's service graph — one pipeline
#                                   per service, hand-written
#
# THE OTEL SPLIT IS RECEIVERS VS EVERYTHING ELSE. apps/ and systems/ say what a
# piece of software writes and where — true on every host that runs it.
# instances/ says what one host does with it, because a VM runs ONE collector
# with ONE config.yaml and therefore one set of resource attributes and exactly
# one destination. vm/otel/push.sh assembles the two.
#
# There is exactly ONE common.sh for all of them: these values are owned by the
# infrastructure, not by an app, so a bucket change stays a single edit.
#
# NOT EXECUTABLE, NOT A DEPLOY SCRIPT. It is sourced (never run) by each
# vm/apps/<app>/<app>.sh, relative to that script's own directory:
#
#   readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../../common.sh"
#
# THE PUSHER MUST SHIP THE WHOLE vm/ TREE, not a single script and not a single
# folder: this file has to be two levels above the app that sources it, and
# vm/instances/<vm>/install.sh reaches sideways into vm/apps/. A push that copied only
# <APP_NAME>.sh would break at the `source` line. (Before 2026-09-24 a baked boot launcher cloned the whole
# repo, which satisfied this for free; it is now the pusher's job.)
#
# THERE IS A SECOND COPY AT docker/common.sh, and that is deliberate: each
# platform folder is self-contained, the same way vm/apps/<app>/<app>.sh and
# docker/<app>.sh are separate copies rather than one script behind a flag
# (CLAUDE.md, "vm/ vs. docker/"). The price is that GCS_BASE_URL and STAGE_ROOT
# appear in both files — CHANGE THE BUCKET IN BOTH OR THE TWO PLATFORMS PULL
# FROM DIFFERENT PLACES. The docker copy holds only those two; the NGINX_*
# seams below are VM-only (no nginx in the app containers).
#
# WHAT BELONGS HERE: values that are identical for every app on every platform
# and are owned by the infrastructure (the artifact bucket, the paths the
# images bake). Changing one of these is then one edit, not ten — which is the
# whole reason this file exists.
#
# WHAT DOES NOT: anything that differs by app — APP_NAME, the context path,
# DEFAULT_WEB_ROOT (/var/www/app for per-PATH apps, /var/www/site for per-HOST
# sites). Those stay in the script that owns them.
#
# Everything here is `readonly`: each deploy script is its own `bash` process
# (a instances/<vm>/install.sh orchestrator runs children via `bash <child>`),
# so the file is sourced exactly once per process and a re-source cannot
# collide. The orchestrators themselves do not source this — they deploy
# nothing, they only invoke the children.

# --- Artifact store -----------------------------------------------------------
# Base GCS location holding per-environment release artifacts. Each app's
# install/ (or conf/) folder and WAR live under
# ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/.
#
# The bucket is read by the VM's compute service account — a new bucket needs
# an IAM grant in build-terraform before a host can pull from it. KEEP IN SYNC
# WITH docker/common.sh.
readonly GCS_BASE_URL="gs://dz-builds"

# --- Local staging ------------------------------------------------------------
# Parent of every app's staging dir; each script stages into
# ${STAGE_ROOT}/${APP_NAME}, the sibling of the pushed scripts
# (${STAGE_ROOT}/repo). Same path whether pushed or run by hand over SSH.
# KEEP IN SYNC WITH docker/common.sh.
readonly STAGE_ROOT="/tmp/deployza"

# --- nginx seams baked by the VM images (VM-ONLY) -----------------------------
# No equivalent in docker/common.sh: the app containers run Tomcat as PID 1
# with no nginx in front of them.
# app.d: per-PATH apps drop <ctx>.conf here; it is included from inside the
# image's `_` default server block, so these files hold bare location blocks.
# The dir is created by the image (install-nginx.sh), not by a deploy script.
readonly NGINX_APP_D="/etc/nginx/app.d"

# site.d: per-HOST sites drop <site>.conf here, each a complete server{} block.
# A server block may only appear at the http{} level, so this dir is included
# from nginx.conf itself — and is created by the per-host deploy scripts, which
# also add that include idempotently, guarded by INCLUDE_MARKER.
readonly NGINX_SITE_D="/etc/nginx/site.d"
readonly NGINX_CONF_MAIN="/etc/nginx/nginx.conf"
readonly INCLUDE_MARKER="# DEPLOYZA-SITE-D"

# The service to reload after writing a conf, and the identity nginx reads
# static files as (so unpacked doc roots are chowned to it).
readonly NGINX_SERVICE="nginx"
readonly NGINX_USER="www-data"
readonly NGINX_GROUP="www-data"
