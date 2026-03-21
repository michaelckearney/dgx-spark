# DGX Spark — Setup Guide

## Prerequisites

The target machine must have the following already installed:

- `git`
- `curl`
- `sudo` (with privileges for the current user)
- `python3`

These are pre-installed on the DGX Spark (Ubuntu-based).

## Bootstrap (First Run)

Run this single command on the target machine:

```bash
curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
```

This will:

1. Clone the repository to `~/dgx-spark`
2. Install Ansible if it's not already present
3. Run the Ansible playbook, which:
   - Installs Docker CE
   - Installs chezmoi and applies dotfiles (`~/.bashrc`)

You will be prompted for your sudo password (via `--ask-become-pass`).

## Re-running (Reconcile Drift)

To re-apply the full configuration at any time:

```bash
curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
```

Or, if the repo is already cloned:

```bash
cd ~/dgx-spark
git pull
ansible-playbook --inventory ansible/inventory.ini --ask-become-pass ansible/playbook.yml
```

Both approaches are idempotent and safe to run repeatedly.

## What Gets Configured

### System Level (Ansible)

| Component | Details |
|---|---|
| Docker CE | Installed from official Docker apt repository, service enabled |
| Docker group | Target user added to `docker` group |
| chezmoi | Installed to `/usr/local/bin/chezmoi` |

### User Level (chezmoi)

| File | Source |
|---|---|
| `~/.bashrc` | `chezmoi/dot_bashrc` in this repo |

## Adding New Configuration

### New system package or service
Add a new Ansible role under `ansible/roles/` and include it in `ansible/playbook.yml`.

### New dotfile
Add a new file to the `chezmoi/` directory following [chezmoi naming conventions](https://www.chezmoi.io/reference/source-state-attributes/):
- `dot_` prefix → `.` in the target (e.g., `dot_gitconfig` → `~/.gitconfig`)
- `private_` prefix → file permissions set to `0600`

Then re-run the bootstrap or `chezmoi apply`.

## Troubleshooting

### "Permission denied" when running Docker
Log out and back in after the first run so the `docker` group membership takes effect.

### Ansible fails to install
Ensure the `ppa:ansible/ansible` PPA is accessible. On some systems you may need to run:
```bash
sudo apt-get update && sudo apt-get install -y software-properties-common
```

### chezmoi conflicts
If chezmoi detects conflicts with existing files, it will prompt for resolution. You can force-apply with:
```bash
chezmoi apply --force
```
