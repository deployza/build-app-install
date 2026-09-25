# docker/common.sh — constants shared by every container deploy script in this
# folder.
#
# NOT EXECUTABLE, NOT A DEPLOY SCRIPT. It is sourced (never run) by each
# docker/<app>.sh, from its own directory:
#
#   readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"
#
# The launcher clones this WHOLE repo before running
# <clone>/docker/<APP_NAME>.sh, so this file is always beside the script that
# sources it. A launcher that copied one script instead of cloning would
# break — don't introduce one.
#
# THERE ARE VM COPIES AT vm/<vm>/common.sh, and that is deliberate: each platform
# folder is self-contained, the same way vm/<app>.sh and docker/<app>.sh are
# separate copies rather than one script behind a flag (CLAUDE.md, "vm/ vs.
# docker/"). The price is that both values below also appear there — CHANGE THE
# BUCKET IN BOTH OR THE TWO PLATFORMS PULL FROM DIFFERENT PLACES.
#
# This copy is SHORTER than the VM ones on purpose. vm/<vm>/common.sh also carries the
# NGINX_* seams; there is no nginx in an app container (Tomcat is PID 1 and
# serves directly), so those constants have nothing to configure here. Do not
# add them for symmetry.
#
# WHAT BELONGS HERE: values identical for every containerised app and owned by
# the infrastructure. WHAT DOES NOT: anything per-app (APP_NAME, context path).
# Note also that nothing here may name the `tomcat` user or group — it does not
# exist in these images, and a chown to it aborts the deploy under `set -e`.
#
# Both values are `readonly`: each deploy script is its own `bash` process, so
# the file is sourced exactly once per process and a re-source cannot collide.

# --- Artifact store -----------------------------------------------------------
# Base GCS location holding per-environment release artifacts. Each app's conf/
# folder and WAR live under ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/.
#
# The bucket is read by the service account the container runs as — a new
# bucket needs an IAM grant in build-terraform before a host can pull from it.
# KEEP IN SYNC WITH every vm/<vm>/common.sh.
readonly GCS_BASE_URL="gs://dz-builds"

# --- Local staging ------------------------------------------------------------
# Parent of every app's staging dir; each script stages into
# ${STAGE_ROOT}/${APP_NAME}, the sibling of the launcher's clone
# (${STAGE_ROOT}/repo). KEEP IN SYNC WITH every vm/<vm>/common.sh.
readonly STAGE_ROOT="/tmp/deployza"
