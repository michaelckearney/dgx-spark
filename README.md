# dgx-spark

GitOps-style configuration management for a personal NVIDIA DGX Spark AI workstation.

This repository is the **single source of truth** for fully configuring the machine from scratch. It is designed to be idempotent, declarative, and re-runnable at any time.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
```

That's it. One command bootstraps everything. After the first run, a systemd timer automatically reconciles the system with this repo every minute.

## Architecture

The system has three layers:

| Layer | Tool | Scope |
|---|---|---|
| **Bootstrap** | `bash` | Install Ansible, invoke `ansible-pull` |
| **System config** | Ansible (`ansible-pull`) | User permissions, services, developer tooling |
| **User config** | chezmoi | Dotfiles (`~/.bashrc`, etc.) |

### How it works

1. **Bootstrap** installs Ansible and runs `ansible-pull` once
2. **`ansible-pull`** clones this repo to `/opt/dgx-spark` and runs the playbook
3. **The playbook** configures Docker group access, installs chezmoi, applies dotfiles, and sets up a systemd timer
4. **The timer** runs `ansible-pull` every minute going forward — the system is self-managing

## Repository Structure

```
├── bootstrap/bootstrap.sh                          # Single entrypoint script
├── ansible/
│   ├── playbook.yml                                # Main playbook
│   ├── group_vars/all.yml                          # Shared variables
│   └── roles/
│       ├── docker/tasks/main.yml                   # Docker group membership
│       ├── chezmoi/tasks/main.yml                  # chezmoi install + apply
│       └── reconcile/
│           ├── tasks/main.yml                      # systemd timer setup
│           ├── handlers/main.yml                   # systemd reload handler
│           └── templates/
│               ├── dgx-spark-reconcile.service.j2  # oneshot service unit
│               └── dgx-spark-reconcile.timer.j2    # 1-minute timer unit
├── chezmoi/
│   └── dot_bashrc                                  # Managed ~/.bashrc
└── docs/
    └── setup.md                                    # Detailed setup guide
```

## What It Configures

- **Docker group** — adds target user to `docker` group for sudo-less access (Docker itself is pre-installed on the DGX Spark)
- **chezmoi** — installed to `/usr/local/bin`, applies dotfiles from this repo
- **`~/.bashrc`** — managed shell configuration
- **Reconcile timer** — systemd timer that runs `ansible-pull` every minute

## Automatic Reconciliation

After bootstrap, push changes to this repo and they'll be applied within a minute. Check status:

```bash
systemctl status dgx-spark-reconcile.timer    # timer status
journalctl -u dgx-spark-reconcile.service -f  # live logs
```

## Documentation

See [docs/setup.md](docs/setup.md) for detailed setup instructions, troubleshooting, and how to extend the configuration.

## Design Principles

- **Idempotent** — every operation is safe to repeat
- **Declarative** — configuration is defined in code, not applied manually
- **Self-managing** — after bootstrap, the system auto-reconciles with the repo
- **Separation of concerns** — system config (Ansible) vs user config (chezmoi)
- **Minimal bootstrap** — the shell script is thin; all logic lives in Ansible
- **Non-destructive** — does not reinstall or modify pre-installed system software (Docker, NVIDIA drivers, etc.)
