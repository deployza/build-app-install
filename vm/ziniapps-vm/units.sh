# vm/<vm>/units.sh — the runner behind this folder's install.sh.
#
# EVERY VM FOLDER HAS ITS OWN COPY, so each folder is self-contained. The
# copies are identical today; a change to one is a change to all of them.
#
# SOURCED, NEVER EXECUTED (no shebang, no `set -e`). A VM's install.sh declares
# its ordered UNITS and hands its arguments to run_units:
#
#   readonly UNITS=(assess-server assess-ui otel)
#   source "${SCRIPT_DIR}/units.sh"
#   run_units "$@"
#
# A UNIT is one piece of work on this host, and one of two kinds:
#
#   <app>   vm/<vm>/<app>.sh APP_ENV     install one app
#   otel    vm/<vm>/install-otel.sh     install vm/<vm>/otel.yaml
#
# USAGE, as seen through install.sh:
#
#   install.sh APP_ENV                  every unit in UNITS, in order
#   install.sh APP_ENV apps             every app unit in UNITS (not otel)
#   install.sh APP_ENV assess-exam      one unit
#   install.sh APP_ENV assess-ui otel   several, in the order given
#
# A unit named explicitly need not be in UNITS — any <name>.sh in the VM's
# folder runs. That is how a script that exists but is deliberately left out of
# the default run (hundi-ui on ziniapps-vm) is still reachable on purpose.
#
# FAILURE STOPS THE RUN: a partial deploy is surfaced rather than hidden.
#
# Each unit's output goes to stdout (the pusher's log) and is also tee'd to
# /tmp/deployza/logs/<unit>.log for inspection on the box. A log dir that cannot
# be created only disables the file copy — it never blocks a deploy.

readonly UNITS_LOG_DIR="/tmp/deployza/logs"

_units_die() { echo "[install] ERROR: $*" >&2; exit 1; }

_units_run_one() {
  local vm_dir="$1" vm="$2" app_env="$3" unit="$4"
  local -a cmd
  if [[ "$unit" == "otel" ]]; then
    cmd=(bash "${vm_dir}/install-otel.sh" --vm "$vm")
  else
    [[ -f "${vm_dir}/${unit}.sh" ]] \
      || _units_die "no unit '${unit}' on ${vm} (expected ${vm_dir}/${unit}.sh, or 'otel' / 'apps')"
    cmd=(bash "${vm_dir}/${unit}.sh" "$app_env")
  fi

  echo
  echo "--- ${unit} (${app_env}) ---------------------------------------"
  if mkdir -p "$UNITS_LOG_DIR" 2>/dev/null; then
    "${cmd[@]}" 2>&1 | tee -a "${UNITS_LOG_DIR}/${unit}.log"
  else
    "${cmd[@]}"
  fi
  echo "--- ${unit} finished -------------------------------------------"
}

# run_units APP_ENV [unit ...] — uses the caller's UNITS and SCRIPT_DIR.
run_units() {
  local app_env="${1:-}"
  case "$app_env" in
    development|production) shift ;;
    "") _units_die "APP_ENV is required. Usage: $0 APP_ENV [unit ...]   (units: ${UNITS[*]}, apps)" ;;
    *)  _units_die "APP_ENV must be 'development' or 'production', not '${app_env}'" ;;
  esac
  [[ "$(id -u)" -eq 0 ]] || _units_die "must run as root (use sudo)"

  # The host is the folder name, or the `instance` file beside it when the two
  # differ (vm/mcp-vm/ is host `mcp`) — the same rule install-otel.sh applies,
  # which refuses a --vm that disagrees with it.
  local vm_dir="$SCRIPT_DIR" vm
  if [[ -f "${SCRIPT_DIR}/instance" ]]; then
    vm="$(tr -d '[:space:]' < "${SCRIPT_DIR}/instance")"
  else
    vm="$(basename "$SCRIPT_DIR")"
  fi

  # Expand the selection: nothing means UNITS; `apps` means UNITS minus otel.
  local -a selected=()
  local u a
  if [[ $# -eq 0 ]]; then
    selected=("${UNITS[@]}")
  else
    for u in "$@"; do
      if [[ "$u" == "apps" ]]; then
        for a in "${UNITS[@]}"; do [[ "$a" == "otel" ]] || selected+=("$a"); done
      else
        selected+=("$u")
      fi
    done
  fi

  echo "==============================================================="
  echo "  ${vm}: ${selected[*]} (${app_env})"
  echo "==============================================================="

  for u in "${selected[@]}"; do
    _units_run_one "$vm_dir" "$vm" "$app_env" "$u"
  done

  echo
  echo "[install] ${vm}: done — ${selected[*]}"
}
