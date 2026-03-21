# DGX Spark — GitOps Configuration Plan

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Repo URL | `https://github.com/michaelckearney/dgx-spark` | Public repo, curl-accessible |
| Clone location | `/opt/dgx-spark` (managed by `ansible-pull`) | System-level, consistent path |
| Target user | Parameterized via `--extra-vars` | Flexible across machines |
| Shell | bash (default) | Keep it simple for now |
| System packages | Docker only | Minimal starting point |
| Dotfiles | `~/.bashrc` only | Expand later as needed |
| Secrets | Deferred | Not needed yet |
| Auto-reconciliation | `ansible-pull` + systemd timer (every minute) | Self-managing after bootstrap |

---

## Repository Structure

```
dgx-spark/
├── README.md
├── bootstrap/
│   └── bootstrap.sh                                # Single entrypoint script
├── ansible/
│   ├── playbook.yml                                # Main playbook
│   ├── group_vars/
│   │   └── all.yml                                 # Shared variables
│   └── roles/
│       ├── docker/
│       │   └── tasks/main.yml                      # Install Docker CE
│       ├── chezmoi/
│       │   └── tasks/main.yml                      # Install chezmoi + apply dotfiles
│       └── reconcile/
│           ├── tasks/main.yml                      # Install systemd timer
│           ├── handlers/main.yml                   # systemd reload handler
│           └── templates/
│               ├── dgx-spark-reconcile.service.j2  # oneshot service unit
│               └── dgx-spark-reconcile.timer.j2    # 1-minute timer unit
├── chezmoi/
│   └── dot_bashrc                                  # chezmoi-managed ~/.bashrc
├── docs/
│   └── setup.md                                    # Setup and recovery docs
└── plans/
    └── implementation-plan.md                      # This file
```

---

## Execution Flow

```
User runs curl | bash
  └── bootstrap.sh
        ├── Installs Ansible (if missing)
        └── Runs ansible-pull
              └── Clones repo to /opt/dgx-spark
              └── Runs playbook.yml
                    ├── Role: docker
                    │     └── Docker CE installed, service enabled, user in docker group
                    ├── Role: chezmoi
                    │     └── chezmoi installed, ~/.bashrc applied
                    └── Role: reconcile
                          └── systemd timer installed (runs ansible-pull every minute)

After bootstrap, the timer auto-reconciles:
  Timer fires every minute
    └── ansible-pull
          └── git pull (lightweight if no changes)
          └── Runs playbook (idempotent, fast if nothing changed)
```

---

## Files

| # | File | Description |
|---|---|---|
| 1 | `bootstrap/bootstrap.sh` | Bootstrap entrypoint — installs Ansible, runs `ansible-pull` |
| 2 | `ansible/playbook.yml` | Main playbook (localhost, roles: docker, chezmoi, reconcile) |
| 3 | `ansible/group_vars/all.yml` | Shared variables (repo_url, target_user, etc.) |
| 4 | `ansible/roles/docker/tasks/main.yml` | Docker CE installation from official apt repo |
| 5 | `ansible/roles/chezmoi/tasks/main.yml` | chezmoi install + apply dotfiles |
| 6 | `ansible/roles/reconcile/tasks/main.yml` | systemd timer/service installation |
| 7 | `ansible/roles/reconcile/handlers/main.yml` | systemd daemon-reload handler |
| 8 | `ansible/roles/reconcile/templates/dgx-spark-reconcile.service.j2` | oneshot service unit |
| 9 | `ansible/roles/reconcile/templates/dgx-spark-reconcile.timer.j2` | 1-minute timer unit |
| 10 | `chezmoi/dot_bashrc` | Managed `~/.bashrc` |
| 11 | `docs/setup.md` | Setup guide and troubleshooting |
| 12 | `README.md` | Project overview and quickstart |

---

## What This Does NOT Include (Yet)

- No secrets management (deferred)
- No editor configs (deferred)
- No zsh/starship/fancy shell (deferred)
- No SSH config (deferred)
- No git config (deferred)
- No CI/CD or automated testing (deferred)

These can all be added incrementally by adding new Ansible roles or chezmoi files.
Changes will be auto-applied by the reconcile timer within a minute of pushing to the repo.
