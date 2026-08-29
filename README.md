# dgx-spark

Personal setup notes — and a script — for getting a new NVIDIA DGX Spark into
the state I like.

This is **not** a fleet management system. Nothing here runs on a schedule,
polls GitHub, or reconciles in the background. It's a record of how I set my
machine up, in a form I can actually re-run if I ever start over.

## Usage

```bash
git clone https://github.com/michaelckearney/dgx-spark.git
cd dgx-spark
./setup.sh --check   # see what would change
./setup.sh           # install and configure everything
./configure.sh       # supply the secrets a public repo can't contain
```

Re-run either any time. `setup.sh` is idempotent and never prompts;
`configure.sh` only asks for what is still missing.

The opinions here are mine (zsh, Powerlevel10k, Ollama), but nothing is tied
to my identity. Anything personal — SSH keys, git authorship — goes in
`local.yml`, which is gitignored:

```bash
cp local.yml.example local.yml    # then edit
./setup.sh
```

That keeps this repo safe to clone: a stranger running it authorises nobody
and commits as `user@hostname`, rather than silently inheriting my keys and my
name. Command-line `--extra-vars` still overrides both.

## Scope

**In scope** — configuring the machine itself:

- **Docker group** — adds me to the `docker` group for sudo-less access
  (Docker itself is pre-installed on the DGX Spark and is *not* touched)
- **Passwordless sudo** — so the Hermes agent can act unattended, with sudo
  I/O logging on so privileged sessions stay auditable (`sudoreplay -l`)
- **SSH access** — authorises the public keys listed in `local.yml` and
  tightens `~/.ssh` to `0700`. Never removes existing keys, so the
  NVIDIA-provisioned one keeps working.
- **CLI tooling** — `vim`, `zsh`, `git`, `ripgrep`, `gh`
- **Shell** — zsh as login shell, Oh My Zsh, Powerlevel10k
- **Dotfiles** — `~/.bashrc`, `~/.zshrc`, `~/.p10k.zsh`, applied via chezmoi
- **Tailscale** — installed and running, joined via `configure.sh`. Gives the
  machine a private `100.x` address reachable from my own devices anywhere.
  SSH is unchanged — same OpenSSH, same keys; Tailscale only supplies the route.
  Tailscale SSH (`--ssh`) is deliberately *not* enabled, since it would
  authenticate by tailnet membership rather than by private key on a host with
  passwordless sudo.
- **Ollama** — installed natively, running as a systemd service
- **Hermes Agent** — installed, left unconfigured (see below)

**Out of scope** — what I happen to be running on it:

Experiments, containers, and one-off services don't belong here. Things like
[PersonaPlex](https://github.com/NVIDIA/personaplex) ship their own Compose
files upstream — clone them somewhere and run them directly when you want
them. Keeping them out of this repo means nothing gets resurrected by a
config sync I forgot about.

**The one exception** is [`workloads/`](workloads/), which stores Compose
files for things I launch by hand. Nothing in there is wired to Ansible — it's
version-controlled so I don't have to re-derive a long flag list, not so that
something runs it for me.

vLLM does carry `restart: unless-stopped`, which is a deliberate exception to
the no-auto-start rule rather than a lapse. It once crashed mid-request
(`CUBLAS_STATUS_INTERNAL_ERROR`) and stayed dead, while the Hermes Telegram
gateway — which *does* auto-start — carried on accepting messages it had no
model to answer. `unless-stopped` revives what stopped by accident and leaves
alone what I stopped on purpose, which is the distinction that actually
matters. I still start it by hand the first time.

## Installed vs. running

The dividing line this repo cares about: Ansible is good at *"make sure X is
installed."* It is bad at *"keep X running."* So installation lives in
`ansible/`, and anything that runs lives in `workloads/` and is started
manually.

Hermes follows this too. The `hermes` role installs the CLI with
`--non-interactive`, which skips the setup wizard — so it arrives installed but
unconfigured. Configure it by hand (`hermes model`, `hermes tools`) against a
running vLLM endpoint; once the configuration is worth keeping, check
`~/.hermes/config.yaml` into `chezmoi/`. Its `~/.hermes/.env` holds API keys
and never belongs in git.

## Where things live on disk

| What | Path |
|---|---|
| Ollama binary | `/usr/local/bin/ollama` |
| Ollama models | `/usr/share/ollama/.ollama/models` |
| Ollama service override | `/etc/systemd/system/ollama.service.d/10-models-dir.conf` |
| chezmoi binary | `/usr/local/bin/chezmoi` |
| chezmoi source | the `chezmoi/` directory in this repo |
| Oh My Zsh | `~/.oh-my-zsh` |
| Powerlevel10k | `~/.oh-my-zsh/custom/themes/powerlevel10k` |

Ollama is installed natively rather than in a container specifically so the
model directory is a real, browsable path — and so it talks to the GPU
directly, without a passthrough layer in between.

## Repository structure

```
├── setup.sh                             # Install/converge. Never prompts.
├── configure.sh                         # Supply secrets. Prompts.
├── local.yml.example                    # → local.yml (gitignored): keys, identity
├── ansible/
│   ├── playbook.yml
│   ├── group_vars/all.yml
│   └── roles/
│       ├── docker/                      # docker group membership only
│       ├── sudo/                        # passwordless sudo + I/O logging
│       ├── ssh/                         # authorized_keys + ~/.ssh perms
│       ├── tailscale/                   # client install, joined by configure.sh
│       ├── tooling/                     # vim, zsh, git, ripgrep, gh,
│       │                                #   oh-my-zsh, p10k
│       ├── ollama/                      # native Ollama install + service
│       ├── chezmoi/                     # chezmoi install + apply
│       └── hermes/                      # Hermes CLI install (unconfigured)
├── chezmoi/
│   ├── dot_bashrc
│   ├── dot_zshrc
│   ├── dot_p10k.zsh
│   └── dot_gitconfig.tmpl               # templated git identity + gh helper
├── workloads/                           # manual only — nothing auto-runs
│   └── vllm/                            # Qwen3.6-35B-A3B NVFP4 server
└── docs/setup.md
```

## Secrets

`setup.sh` installs everything but supplies no credentials. `configure.sh`
collects them:

```bash
./configure.sh              # anything still missing
./configure.sh telegram     # rotate just one
./configure.sh --list       # what's configured — never values
```

**This repo stores no secrets.** Each is written straight through to the tool
that owns it — `gh`'s token store, and Hermes' `~/.hermes/.env` (mode `0600`).
There is no second copy to drift out of sync and no additional store to secure.
"Is it configured?" is answered by asking the real consumer.

| Secret | Goes to | For |
|---|---|---|
| `github` | gh's token store | pushing over HTTPS |
| `telegram` | `~/.hermes/.env` + gateway service | Hermes messaging |
| `tailscale` | the tailnet join itself | remote SSH from anywhere |

The GitHub token needs `repo` scope (classic) or Contents: read and write
(fine-grained). Note that a PAT, unlike `gh auth login`'s browser flow, does not
refresh itself — when it expires pushes start failing, and
`./configure.sh github` replaces it.

## Design principles

- **Runs when I say so** — no timers, no daemons, no polling
- **Idempotent** — safe to re-run at any point
- **Non-destructive** — never reinstalls or modifies pre-installed system
  software (Docker, NVIDIA Container Toolkit, drivers, CUDA)
- **Machine setup, not workload definition** — this repo describes the
  computer, not what's currently running on it
