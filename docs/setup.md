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
| llama-swap | Native install, `llama-swap.service` enabled and started, `127.0.0.1:8000` |
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

Ollama shares the machine's unified memory with vLLM. If a model load fails on
memory even within capacity, check `ollama ps` first — llama-swap's
one-model-at-a-time rule only covers its own models.

## llama-swap

The model gateway, and the one daemon this repo runs — see
[The one daemon](../README.md#the-one-daemon) for why that exception exists.
It holds `127.0.0.1:8000` and starts the right vLLM container on demand.

```bash
systemctl status llama-swap
journalctl -u llama-swap -f
curl -sS http://localhost:8000/v1/models    # catalogue, loaded or not
docker ps                                   # what is actually resident
```

The model catalogue is `workloads/llama-swap/config.yaml`, copied to
`/etc/llama-swap/config.yaml` by the `llama_swap` role. Edit it in the repo and
re-run `./setup.sh`; the role validates it before moving it into place and
reloads the service with `SIGHUP`, which leaves an already-loaded model
running. Version and listen address come from `llama_swap_*` in
`ansible/group_vars/all.yml`.

**Nothing is loaded at boot.** A rebooted machine nobody talks to holds zero
GPU, while `/v1/models` still answers.

**The endpoint has no authentication** — inference, the `/ui` log stream, and
`POST /api/models/unload` are all open to whoever reaches the port. Loopback
binding is the whole of the access control. Reach the UI over SSH:

```bash
ssh -L 8000:127.0.0.1:8000 <user>@<host>
```

Adding a model has traps worth reading before you try —
[`workloads/llama-swap/README.md`](../workloads/llama-swap/README.md) covers
them, chiefly that `cmd` is not run through a shell, so `${HOME}` in a volume
mount silently causes a 21.85 GiB re-download.

## Secrets

`setup.sh` never prompts and supplies no credentials. `configure.sh` collects
them and is safe to re-run. It needs no sudo except for `tailscale`, which
cannot join a tailnet without root — silent here given the passwordless sudo
this repo configures:

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
| `tailscale` | consumed by `tailscale up` at join time; nothing is kept | remote SSH from anywhere |

Status is derived by asking the real consumer (`gh auth status`, grepping the
`.env`), not from a manifest of our own — so it cannot drift.

**Everything here is optional and skippable.** Press Enter at any prompt to skip
that secret; `configure.sh` still exits 0, because not having set something up
yet is a normal state rather than a failure. Nothing else in the repo depends on
either credential — `setup.sh` never consults them, Hermes runs fine from the
terminal without Telegram, and the only consequence of skipping `github` is that
pushing over HTTPS won't work until you supply it.

### GitHub token

Create at <https://github.com/settings/tokens>. Use a **classic** token with
**both** scopes:

| Scope | Why |
|---|---|
| `repo` | pushing over HTTPS |
| `read:org` | required by `gh auth login` itself — it refuses the token without it |

`read:org` is easy to miss: `gh` rejects the token outright with
`missing required scope 'read:org'`. Fine-grained tokens don't advertise scopes
in the way `gh` checks for them and are likely to be rejected, so classic is the
reliable choice here.

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

## Tailscale

Puts this machine on a private WireGuard mesh so you can reach it from your own
devices on any network — no port forwarding, no dynamic DNS, nothing exposed to
the public internet.

**SSH does not change.** Same OpenSSH, same keys, same `authorized_keys`;
Tailscale only supplies the network path. Connect with the machine's tailnet
address or its MagicDNS name:

```bash
tailscale ip -4          # on the Spark: its 100.x address
ssh michaelckearney@100.x.y.z
```

**Your laptop needs the Tailscale client too**, signed in to the same account —
it's a mesh, so there's no tailnet to reach the Spark over otherwise.

Ansible installs the client and starts `tailscaled`; joining happens in
`./configure.sh tailscale` with a one-off auth key from
<https://login.tailscale.com/admin/settings/keys>. The key is written to a
mode-`0600` temp file and passed as `--auth-key=file:...` rather than on the
command line, where it would be visible in `ps`; a trap removes it on every exit
path including Ctrl-C.

### Two expiries, and only one will bite you

| | Lifetime | Effect |
|---|---|---|
| **Auth key** | 90 days max | Only used at join. Expiry does **not** kick an already-joined machine off. |
| **Node key** | **180 days** by default | The machine **silently drops off the tailnet**. |

Turn off key expiry for this device at
<https://login.tailscale.com/admin/machines>. Nothing will warn you first —
remote access just stops working one day months from now.

### Not enabled

**Tailscale SSH (`--ssh`)** is deliberately off. It would add a second login
path authenticated by tailnet membership instead of by private key, meaning any
device you ever add to the tailnet gets a shell — on a host with passwordless
sudo and an agent holding terminal and browser tools. Reversible at any time
with `tailscale set --ssh` if you decide you want it.

**`tailscale serve` / `funnel`** are also unused. `serve` would expose a local
port to the tailnet; `funnel` exposes it to the public internet. Never point
either at port 8000 or at Open WebUI — neither has any authentication.

Port 8000 is now llama-swap, which raises the stakes: alongside inference it
serves a live log stream at `/ui` and an unauthenticated
`POST /api/models/unload`. Use an SSH tunnel
(`ssh -L 8000:127.0.0.1:8000 <user>@<host>`) rather than widening the binding.

## Hermes Agent

The `hermes` role installs the CLI with `--non-interactive`. That runs every
install stage except `setup` (API keys and settings) and `gateway`
(Telegram/Discord), so Hermes arrives **installed but unconfigured** — by
design.

To configure it:

```bash
hermes model    # Custom endpoint → http://localhost:8000/v1 → blank API key
hermes tools    # toggle capabilities
hermes          # open the TUI
```

`hermes model` lists whatever the endpoint reports at `/v1/models`. That is now
the llama-swap gateway, which answers with the full catalogue whether or not a
model is loaded — so nothing needs starting first.

**Set a request timeout that outlasts a model load.** This is the one manual
step the gateway depends on. Hermes retries transport errors, but its budget is
roughly 45–60 seconds — an order of magnitude short of a vLLM reload. The
design works by the gateway *holding* the request until the model is ready, so
Hermes never enters retry; if Hermes gives up first, that hold is wasted. In
`~/.hermes/config.yaml`:

```yaml
providers:
  <provider_id>:
    timeout_seconds: 2100
    stale_timeout_seconds: 300
```

`providers` is empty by default, so you are adding this block. Read the file
after `hermes model` has run to find the real `<provider_id>`. The values must
exceed `healthCheckTimeout` in the gateway's config (1800s) — see the timeout
ladder in [`workloads/llama-swap/README.md`](../workloads/llama-swap/README.md).
This is also the first thing that makes `~/.hermes/config.yaml` genuinely worth
committing to `chezmoi/`.

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

The exception is [`workloads/`](../workloads/), which version-controls the
definitions for things launched by hand, plus the llama-swap model catalogue —
the one file there that Ansible does deploy, to `/etc/llama-swap/config.yaml`.

Local models are no longer started by hand at all. Ask the gateway for one by
name and it starts the container for you:

```bash
curl -sS http://localhost:8000/v1/models
```

See [`workloads/llama-swap/README.md`](../workloads/llama-swap/README.md) for
operating it and [`workloads/vllm/README.md`](../workloads/vllm/README.md) for
what the Qwen3.6 flags mean and how to run it standalone when debugging.

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
