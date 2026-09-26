# `ansible/` — the pusher

Runs on a **controller** (your laptop today, `ops-vm` later) and reaches
every VM over the IAP tunnel. Nothing in this folder is ever copied to a host.

```
ansible/
├── ansible.cfg          pipelining + ControlPersist — tunnels are expensive to open
├── inventory/hosts.yml  hosts keyed by GCE instance name = vm/<vm>/ folder name
├── playbooks/<vm>.yml   one per VM: one role line per UNIT, each its own tag
├── playbooks/site.yml   every VM, in order
└── roles/
    ├── vm_push          ship the host's vm/<vm>/ folder, once per run
    └── vm_unit          run one unit on the host
```

## A VM is a list of units

A **unit** is one piece of work: one app script (`vm/<vm>/<app>.sh`) or `otel`
(`vm/<vm>/install-otel.sh`, which installs `vm/<vm>/otel.yaml`). Each VM's playbook
lists its units in order, and **every unit is a tag**:

```bash
cd ansible
ansible-playbook playbooks/ziniapps-vm.yml                            # every unit
ansible-playbook playbooks/ziniapps-vm.yml --tags assess-exam         # one app
ansible-playbook playbooks/ziniapps-vm.yml --tags assess-ui,assess-exam
ansible-playbook playbooks/ziniapps-vm.yml --tags apps                # all apps, no otel
ansible-playbook playbooks/ziniapps-vm.yml --tags otel                # collector only
ansible-playbook playbooks/ziniapps-vm.yml --skip-tags otel
ansible-playbook playbooks/ziniapps-vm.yml --list-tags                # what units exist

ansible-playbook playbooks/site.yml --tags otel                       # every collector
```

From a laptop, override the identity — the inventory names the service account
`ops-vm` will use:

```bash
ansible-playbook playbooks/ziniapps-vm.yml -e ansible_user=you_deployza_com
```

The same units run from a clone on the box, because the role only invokes the
scripts:

```bash
sudo bash vm/ziniapps-vm/install.sh production               # every unit
sudo bash vm/ziniapps-vm/install.sh production assess-exam   # one
sudo bash vm/ziniapps-vm/install-otel.sh                     # otel
```

## The decisions worth knowing

- **`vm_push` is tagged `always`**, so whatever `--tags` selects, the scripts are
  on the box. It ships the host's whole `vm/<vm>/` folder and nothing else —
  the folder is self-contained (its own `common.sh`, `units.sh`,
  `install-otel.sh` and `inert.yaml`) and holds only what that host runs, so
  nothing needs pruning. Every host has a folder — `vm/mcp-vm/` is host `mcp`,
  set by its `vm_dir` and its `instance` file — and a host without one is refused. `/tmp/deployza/repo` is wiped
  first, so a removed unit cannot linger and still be runnable.
- **The unit order is written twice**: in the playbook's role list and in
  `vm/<vm>/install.sh`'s `UNITS`. Tags must be static, so the playbook cannot read
  the list from the script. **Change both together.**
- **`never`-tagged units** ship but run only when named. `hundi-ui` on
  `ziniapps-vm` is one: its script exists, it has never been deployed.
- **`app_env` comes from inventory** and is required by every unit except
  `otel`. There is no default — a missing value aborts rather than deploying to
  the wrong environment.
- **`otel` needs no flavor and no render.** `otel.yaml` is the complete config.
  `install-otel.sh` validates it against the host's pinned `otelcol-contrib`,
  checks `host.project` against the metadata server, adds `otelcol` to its log
  groups, then backs up, swaps, restarts and waits for the unit to stay up —
  restoring the backup if it does not.

## Adding a unit

1. Put the script at `vm/<vm>/<unit>.sh` (source `common.sh`, beside it).
2. Add it to `UNITS` in `vm/<vm>/install.sh`.
3. Add `- { role: vm_unit, unit: <unit>, tags: [apps, <unit>] }` to
   `playbooks/<vm>.yml`, in the same position.
4. If it should be collected on its own, add its receiver, `resource/<unit>`
   processor and pipeline to `vm/<vm>/otel.yaml`.

## Not done here

- **Secrets.** None in this folder and none may be added. They come from Secret
  Manager at run time; Pub/Sub needs no credential at all.
- **Dynamic inventory.** Four hosts do not need it yet.
- **Any of it, against a real VM.** Nothing here has been exercised or CI'd.
  `ziniapps-vm` is the only inventory host that exists today: the `mcp` VM was
  deleted on 2026-09-26, and `deployza-vm` and `ops-vm` are not built yet.
