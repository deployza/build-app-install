#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# vm/mcp-vm/install.sh — everything the MCP server (host `mcp`, mcp.deployza.com)
# runs, or any unit of it.
#
#   sudo bash vm/mcp-vm/install.sh production            # every unit
#   sudo bash vm/mcp-vm/install.sh production mcp        # the app only
#   sudo bash vm/mcp-vm/install.sh production otel       # collector
#
# From the controller the same units are tags:
#   ansible-playbook playbooks/mcp-vm.yml --tags mcp
#
# THE PLAYBOOK LISTS THE SAME UNITS IN THE SAME ORDER — KEEP THE TWO IN SYNC.
#
#   mcp    the MCP server: graphify, the OAuth gateway, the hourly refresh and
#          their config (mcp.sh, payload in ./mcp/). The image bakes only the
#          venv they run in, so a VM booted from it serves nothing until this
#          unit has run once.
#   otel   the collector config, last. This folder has no otel.yaml, so it
#          installs inert.yaml — collect nothing, send nowhere.
#
# The folder is vm/mcp-vm/ but the host is `mcp`: see the `instance` file.
# -----------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly UNITS=(
  mcp
  otel
)

source "${SCRIPT_DIR}/units.sh"
run_units "$@"
