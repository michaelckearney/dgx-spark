# DGX Spark — Setup Guide

## Prerequisites

Already present on a stock DGX Spark (Ubuntu-based):

- `git`, `curl`, `python3`
- `sudo` privileges for your user
- Docker + NVIDIA Container Toolkit (pre-installed — this repo does not touch them)

## Running it

```bash
git clone https://github.com/michaelckearney/dgx-spark.git
cd dgx-spark
./setup.sh --check   # dry run: shows a diff of what would change
./setup.sh           # apply
```

You'll be prompted for your sudo password. The script installs Ansible if it
isn't already present, then runs `ansible/playbook.yml` against localhost.

There is no background reconciliation. If you change something in this repo,
nothing happens on the machine until you re-run `./setup.sh` yourself.

## What gets configured

### System level (Ansible)

| Component | Details |
|---|---|
| Docker group | Your user added to `docker`. Docker itself untouched. |
| CLI tooling | `vim`, `zsh`, `git` via apt |
| Login shell | Set to `/usr/bin/zsh` |
| Oh My Zsh | Cloned to `~/.oh-my-zsh` |
| Powerlevel10k | Cloned to `~/.oh-my-zsh/custom/themes/powerlevel10k` |
| Ollama | Native install, `ollama.service` enabled and started |
| chezmoi | Installed to `/usr/local/bin/chezmoi` |

### User level (chezmoi)

| File | Source |
|---|---|
| `~/.bashrc` | `chezmoi/dot_bashrc` |
| `~/.zshrc` | `chezmoi/dot_zshrc` |
| `~/.p10k.zsh` | `chezmoi/dot_p10k.zsh` |

### What is NOT modified

- Docker CE (pre-installed on the DGX Spark)
- NVIDIA Container Toolkit / Runtime
- NVIDIA drivers and CUDA
- System kernel and firmware

## Ollama

Installed natively rather than containerized, so models sit at a known path
and the GPU is accessed directly.

```bash
systemctl status ollama          # service state
ollama list                      # installed models
ollama pull llama3.2             # add a model
du -sh /usr/share/ollama/.ollama/models
```

The model directory is pinned explicitly by a systemd drop-in at
`/etc/systemd/system/ollama.service.d/10-models-dir.conf`, generated from the
`ollama_models_dir` variable in `ansible/group_vars/all.yml`. Change that
variable and re-run `./setup.sh` to relocate model storage.

Models are deliberately **not** declared in this repo — pull what you want,
when you want it.

## Running other things on the machine

Containers and experiments are intentionally out of scope. Run them directly:

```bash
# example: PersonaPlex, which ships its own compose file
git clone https://github.com/NVIDIA/personaplex.git
cd personaplex
echo "HF_TOKEN=hf_..." > .env
docker compose up -d
```

Nothing in this repo will start, stop, or remove those.

## Adding new configuration

### New system package or service
Add a role under `ansible/roles/` and list it in `ansible/playbook.yml`.
Re-run `./setup.sh` to apply.

### New dotfile
Add a file to `chezmoi/` following
[chezmoi naming conventions](https://www.chezmoi.io/reference/source-state-attributes/):

- `dot_` prefix → `.` in the target (`dot_gitconfig` → `~/.gitconfig`)
- `private_` prefix → permissions set to `0600`

Re-run `./setup.sh` to apply.

## Troubleshooting

### "Permission denied" when running Docker
Log out and back in so the `docker` group membership takes effect.

### Ansible fails to install
```bash
sudo apt-get update && sudo apt-get install -y software-properties-common
```

### chezmoi conflicts
```bash
chezmoi apply --force
```

### Ollama won't start
```bash
systemctl status ollama
journalctl -u ollama -n 50 --no-pager
```
