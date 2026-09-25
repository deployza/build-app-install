#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# vm/deployza-vm/install.sh — everything deployza-vm (www.deployza.com) runs, or
# any unit of it.
#
#   sudo bash vm/deployza-vm/install.sh production                # every unit
#   sudo bash vm/deployza-vm/install.sh production www-apidocs    # docs only
#   sudo bash vm/deployza-vm/install.sh production otel           # collector
#
# From the controller the same units are tags:
#   ansible-playbook playbooks/deployza-vm.yml --tags www-apidocs
#
# THE PLAYBOOK LISTS THE SAME UNITS IN THE SAME ORDER — KEEP THE TWO IN SYNC.
#
#   www-website   www.deployza.com — the marketing site (per-HOST, site.d).
#                 First, because its server block carries
#                 `include /etc/nginx/app.d/*.conf;`, which is what makes the
#                 docs drop-in resolve on this hostname.
#   www-apidocs   www.deployza.com/api-docs/ — the MkDocs docs (per-PATH,
#                 app.d). A failed docs BUILD is deliberately not a failure:
#                 the script logs it and exits 0.
#   otel          the collector config, last.
#
# The site and the docs are separate units precisely so either can be
# redeployed without the other: a site release and a docs commit are unrelated.
#
# THIS HOST DOES NOT EXIST YET in Terraform.
# -----------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly UNITS=(
  www-website
  www-apidocs
  otel
)

source "${SCRIPT_DIR}/units.sh"
run_units "$@"
