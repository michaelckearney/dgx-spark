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
| Passwordless sudo | `/etc/sudoers.d/50-<user>-nopasswd`, plus sudo I/O logging |
| CLI tooling | `vim`, `zsh`, `git`, `ripgrep`, `gh` via apt |
| Login shell | Set to `/usr/bin/zsh` |
| Oh My Zsh | Cloned to `~/.oh-my-zsh` |
| Powerlevel10k | Cloned to `~/.oh-my-zsh/custom/themes/powerlevel10k` |
| Ollama | Native install, `ollama.service` enabled and started |
| chezmoi | Installed to `/usr/local/bin/chezmoi` |
| Hermes Agent | Installed to `~/.local/bin/hermes`, **left unconfigured** |

### User level (chezmoi)

| File | Source |
|---|---|
| `~/.bashrc` | `chezmoi/dot_bashrc` |
| `~/.zshrc` | `chezmoi/dot_zshrc` |
| `~/.p10k.zsh` | `chezmoi/dot_p10k.zsh` |
| `~/.gitconfig` | `chezmoi/dot_gitconfig.tmpl` (templated identity + gh credential helper) |

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

## Secrets

`setup.sh` never prompts and supplies no credentials. `configure.sh` collects
them, needs no sudo, and is safe to re-run:

```bash
./configure.sh              # prompt for anything still missing
./configure.sh github       # rotate exactly one
./configure.sh --list       # show what is configured — never values
```

**Nothing is stored by this repo.** Each secret is written straight through to
the tool that owns it, so no secret exists in two places and there is no extra
store to protect:

| Secret | Written to | Used for |
|---|---|---|
| `github` | gh's own token store, via `gh auth login --with-token` | `git push` over HTTPS |
| `telegram` | `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env` (`0600`), then `hermes gateway install` | Hermes messaging |

Status is derived by asking the real consumer (`gh auth status`, grepping the
`.env`), not from a manifest of our own — so it cannot drift.

**Everything here is optional and skippable.** Press Enter at any prompt to skip
that secret; `configure.sh` still exits 0, because not having set something up
yet is a normal state rather than a failure. Nothing else in the repo depends on
either credential — `setup.sh` never consults them, Hermes runs fine from the
terminal without Telegram, and the only consequence of skipping `github` is that
pushing over HTTPS won't work until you supply it.

### GitHub token

Create at <https://github.com/settings/tokens>. Needs `repo` scope (classic) or
Contents: read and write (fine-grained). Without it `gh auth login` still
succeeds and `git push` fails later.

**A PAT does not refresh itself**, unlike `gh auth login`'s browser flow. When it
expires, pushes start failing with no other warning — re-run
`./configure.sh github`.

### Telegram

Bot token from [@BotFather](https://t.me/BotFather); your numeric ID from
[@userinfobot](https://t.me/userinfobot).

Leaving the allowlist blank is safe — Hermes denies unknown senders and routes
them through DM pairing (`hermes gateway pairing approve`). Blank does **not**
mean anyone can use the bot.

Two things `configure.sh` handles that are easy to get wrong by hand:

- `hermes config set TELEGRAM_ALLOWED_USERS ...` silently writes a **dead key**
  into `config.yaml` that nothing reads. The allowlist must go into `.env`
  directly (or via `hermes config set telegram.allow_from`).
- A malformed or placeholder bot token is accepted by the `.env` writer and then
  **silently disables** the Telegram adapter at gateway start — an error in the
  log and nothing else. `configure.sh` validates against Hermes' own regex
  before writing.

Check the gateway with `hermes gateway status` or
`journalctl --user -u hermes-gateway -f`.

## Hermes Agent

The `hermes` role installs the CLI with `--non-interactive`. That runs every
install stage except `setup` (API keys and settings) and `gateway`
(Telegram/Discord), so Hermes arrives **installed but unconfigured** — by
design.

To configure it, start the vLLM workload first, then:

```bash
hermes model    # Custom endpoint → http://localhost:8000/v1 → blank API key
hermes tools    # toggle capabilities
hermes          # open the TUI
```

`hermes model` lists whatever the endpoint reports at `/v1/models`, so the
server must be running or the list comes back empty.

Notes:

- Upgrade with `hermes update`, not by re-running `setup.sh`. The install task
  is guarded by `creates:` and won't re-run once the binary exists.
- `ripgrep` is installed by the `tooling` role, covering the helper prompt that
  `--non-interactive` skips. **`ffmpeg` is not** — its only use in Hermes is
  TTS voice messages via a messaging gateway, and it pulls ~174 MB of desktop
  multimedia libraries. Add it to the `tooling` role if you enable Telegram
  and want voice messages.
- Config lives at `~/.hermes/config.yaml` — a single file, safe to commit.
  Once you're happy with it, add it to `chezmoi/dot_hermes/config.yaml`.
- **Never use `exact_dot_hermes/`** in chezmoi. `~/.hermes` also contains the
  code checkout, a vendored `uv`, a vendored Node, sessions, and logs; the
  `exact_` prefix would delete all of it.
- `~/.hermes/.env` holds API keys (`chmod 600`) and must stay out of git.
- Hermes executes shell commands and persists skills between sessions. If you
  later enable a messaging gateway, restrict allowed user IDs — blank means
  anyone who finds the bot can drive it.
- Rollback: `hermes uninstall`, then `rm -rf ~/.hermes`.

## Running other things on the machine

Most containers and experiments are out of scope — run them directly:

```bash
# example: PersonaPlex, which ships its own compose file
git clone https://github.com/NVIDIA/personaplex.git
cd personaplex
echo "HF_TOKEN=hf_..." > .env
docker compose up -d
```

The exception is [`workloads/`](../workloads/), which version-controls Compose
files for things launched by hand — currently a vLLM server for
`nvidia/Qwen3.6-35B-A3B-NVFP4`:

```bash
docker compose -f workloads/vllm/compose.yaml up -d
```

Nothing in `workloads/` is wired to Ansible, has a restart policy, or starts on
boot. See [`workloads/vllm/README.md`](../workloads/vllm/README.md).

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
