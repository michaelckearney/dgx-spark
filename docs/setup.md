# DGX Spark — Setup Guide

## Prerequisites

The target machine must have the following already installed:

- `git`
- `curl`
- `sudo` (with privileges for the current user)
- `python3`
- Docker (pre-installed on the DGX Spark)

These are pre-installed on the DGX Spark (Ubuntu-based).

## Bootstrap (First Run)

Run this single command on the target machine:

```bash
curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
```

This will:

1. Install Ansible if it's not already present
2. Run `ansible-pull`, which:
   - Clones the repository to `/opt/dgx-spark`
   - Runs the Ansible playbook, which:
     - Adds the target user to the `docker` group (Docker itself is pre-installed)
     - Installs chezmoi and applies dotfiles (`~/.bashrc`)
     - Installs a systemd timer for automatic reconciliation

After the first run, the system is **self-managing** — a systemd timer runs `ansible-pull` every minute to pull changes and re-apply the playbook.

## Automatic Reconciliation

After bootstrap, a systemd timer (`dgx-spark-reconcile.timer`) runs every minute. It:

1. Pulls the latest changes from the Git repository
2. Runs the full Ansible playbook (only if changes are detected)
3. Applies any new system or user configuration

### Checking timer status

```bash
systemctl status dgx-spark-reconcile.timer
```

### Viewing reconcile logs

```bash
journalctl -u dgx-spark-reconcile.service -f
```

### Manually triggering a reconcile

```bash
sudo systemctl start dgx-spark-reconcile.service
```

### Disabling automatic reconciliation

```bash
sudo systemctl stop dgx-spark-reconcile.timer
sudo systemctl disable dgx-spark-reconcile.timer
```

## Manual Re-run

You can always re-run the bootstrap command to force a full reconciliation:

```bash
curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
```

This is idempotent and safe to run at any time.

## What Gets Configured

### System Level (Ansible)

| Component | Details |
|---|---|
| Docker group | Target user added to `docker` group (Docker is pre-installed, not modified) |
| chezmoi | Installed to `/usr/local/bin/chezmoi` |
| Reconcile timer | systemd timer running `ansible-pull` every minute |

### User Level (chezmoi)

| File | Source |
|---|---|
| `~/.bashrc` | `chezmoi/dot_bashrc` in this repo |

### What is NOT modified

The following pre-installed components are **not touched** by this playbook:

- Docker CE (pre-installed on DGX Spark)
- NVIDIA Container Toolkit / Runtime
- NVIDIA drivers and CUDA
- System kernel and firmware

## Adding New Configuration

### New system package or service
Add a new Ansible role under `ansible/roles/` and include it in `ansible/playbook.yml`. The change will be picked up automatically within a minute.

### New dotfile
Add a new file to the `chezmoi/` directory following [chezmoi naming conventions](https://www.chezmoi.io/reference/source-state-attributes/):
- `dot_` prefix → `.` in the target (e.g., `dot_gitconfig` → `~/.gitconfig`)
- `private_` prefix → file permissions set to `0600`

Push to the repo and the reconcile timer will apply it automatically.

## Troubleshooting

### "Permission denied" when running Docker
Log out and back in after the first run so the `docker` group membership takes effect.

### Ansible fails to install
Ensure the `ppa:ansible/ansible` PPA is accessible. On some systems you may need to run:
```bash
sudo apt-get update && sudo apt-get install -y software-properties-common
```

### chezmoi conflicts
If chezmoi detects conflicts with existing files, you can force-apply with:
```bash
chezmoi apply --force
```

### Timer not running
```bash
systemctl status dgx-spark-reconcile.timer
journalctl -u dgx-spark-reconcile.service --no-pager -n 50
```
