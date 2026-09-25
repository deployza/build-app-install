#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# vm/ziniapps-vm/install.sh — everything ziniapps-vm runs, or any unit of it.
#
#   sudo bash vm/ziniapps-vm/install.sh production                # every unit
#   sudo bash vm/ziniapps-vm/install.sh production apps           # apps only
#   sudo bash vm/ziniapps-vm/install.sh production assess-exam    # one unit
#   sudo bash vm/ziniapps-vm/install.sh production otel           # collector
#
# From the controller the same units are tags:
#   ansible-playbook playbooks/ziniapps-vm.yml --tags assess-exam
#
# THE ORDER BELOW IS LOAD-BEARING, and the playbook lists the same units in the
# same order — KEEP THE TWO IN SYNC.
#
#   assess-server   first: its DB and context are in place before the UI and
#                   exam apps come up
#   assess-ui, assess-exam
#                   per-PATH static bundles (/etc/nginx/app.d/<ctx>.conf)
#   ziniapps-go, ziniapps-www
#                   per-HOST sites (/etc/nginx/site.d/). Last, because
#                   ziniapps-go's server block includes app.d/*.conf so that
#                   go.ziniapps.com keeps serving /assess-ui/ etc. — running the
#                   per-path apps first means every reload tests a complete
#                   config.
#   otel            last: its filelog receivers then point at log dirs that
#                   already exist (filelog tolerates missing ones, so this is
#                   preference, not requirement).
#
# NOT IN THE LIST: hundi-ui. Its script is here and this is the host it is meant
# for, but it has never been deployed. Naming it runs it
# (`install.sh production hundi-ui`); adding it below is a deploy change.
# -----------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly UNITS=(
  assess-server
  assess-ui
  assess-exam
  ziniapps-go
  ziniapps-www
  otel
)

source "${SCRIPT_DIR}/../units.sh"
run_units "$@"
