# dgx-spark

GitOps-style configuration management for a personal NVIDIA DGX Spark AI workstation.

This repository is the **single source of truth** for fully configuring the machine from scratch. It is designed to be idempotent, declarative, and re-runnable at any time.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
```

That's it. One command bootstraps everything.

## Architecture

The system has three layers:

| Layer | Tool | Scope |
|---|---|---|
| **Bootstrap** | `bash` | Clone repo, install Ansible, invoke playbook |
| **System config** | Ansible | Packages, services, Docker, developer tooling |
| **User config** | chezmoi | Dotfiles (`~/.bashrc`, etc.) |

## Repository Structure

```
├── bootstrap/bootstrap.sh          # Single entrypoint script
├── ansible/
│   ├── inventory.ini               # Localhost inventory
│   ├── playbook.yml                # Main playbook
│   ├── group_vars/all.yml          # Shared variables
│   └── roles/
│       ├── docker/tasks/main.yml   # Docker CE installation
│       └── chezmoi/tasks/main.yml  # chezmoi install + apply
├── chezmoi/
│   └── dot_bashrc                  # Managed ~/.bashrc
└── docs/
    └── setup.md                    # Detailed setup guide
```

## What It Configures

- **Docker CE** — installed from official apt repository, service enabled, user added to `docker` group
- **chezmoi** — installed to `/usr/local/bin`, applies dotfiles from this repo
- **`~/.bashrc`** — managed shell configuration with sensible defaults

## Re-running

Safe to re-run at any time to reconcile drift:

```bash
curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
```

## Documentation

See [docs/setup.md](docs/setup.md) for detailed setup instructions, troubleshooting, and how to extend the configuration.

## Design Principles

- **Idempotent** — every operation is safe to repeat
- **Declarative** — configuration is defined in code, not applied manually
- **Separation of concerns** — system config (Ansible) vs user config (chezmoi)
- **Minimal bootstrap** — the shell script is thin; all logic lives in Ansible
- **Reproducible** — a fresh machine can be fully configured from this repo alone
