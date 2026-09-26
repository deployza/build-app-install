# vm/ziniapps-vm/common.sh — constants shared by every deploy script in this folder.
#
# EACH VM FOLDER IS SELF-CONTAINED — everything a host runs sits in its folder:
#
#   vm/<vm>/install.sh      run every unit this host has, in order — or any of
#                           them: `install.sh production assess-exam`
#   vm/<vm>/<app>.sh        ONE UNIT: install one app on this host
#   vm/<vm>/otel.yaml       this host's COMPLETE collector config — receivers,
#                           processors, exporters, service
#   vm/<vm>/install-otel.sh ONE UNIT (`otel`): validate, swap in, restart and
#                           verify otel.yaml; roll back on failure
#   vm/<vm>/units.sh        the runner install.sh sources
#   vm/<vm>/inert.yaml      collect nothing, send nowhere (--inert)
#   vm/<vm>/common.sh       this file
#
# An app that ran on two hosts would have a copy of its script in each folder.
# None does today.
#
# EVERY VM FOLDER HAS ITS OWN COPY OF THIS FILE, identical today. The price:
# CHANGE THE BUCKET (or any value below) IN EVERY vm/<vm>/common.sh — and in
# docker/common.sh — or hosts pull from different places.
#
# NOT EXECUTABLE, NOT A DEPLOY SCRIPT. It is sourced (never run) from the
# sourcing script's own directory:
#
#   readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"
#
# SHIP THE FOLDER, NOT A FILE: an app script copied on its own breaks at the
# `source` line. ansible/roles/vm_push ships vm/<vm>/ whole.
#
# THERE IS A SECOND COPY AT docker/common.sh, and that is deliberate: each
# platform folder is self-contained, the same way vm/<vm>/<app>.sh and
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
# Everything here is `readonly`: each unit is its own `bash` process (units.sh
# runs each via `bash <script>`), so the file is sourced exactly once per
# process and a re-source cannot collide. install.sh itself does not source it.

# --- Artifact store -----------------------------------------------------------
# Base GCS location holding per-environment release artifacts. Each app's
# install/ (or conf/) folder and WAR live under
# ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/.
#
# The bucket is read by the VM's attached service account — a new bucket needs
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
