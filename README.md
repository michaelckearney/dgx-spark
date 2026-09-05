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
to my identity. Set your own for commit authorship — either edit
`git_user_name` / `git_user_email` in `ansible/group_vars/all.yml`, or pass
them per run:

```bash
./setup.sh --extra-vars "git_user_name='Ada Lovelace' git_user_email=ada@example.com"
```

Left alone they default to this machine's `user@hostname`, so the repo works
as-is for anyone without inheriting someone else's identity.

## SSH access from your laptop

Not managed by this repo — it's a one-time step, run **from the laptop you
connect from**:

```bash
ssh-copy-id -f -i ~/.ssh/id_rsa.pub <user>@<host>.local
```

**The `-f` is not optional.** `ssh-copy-id`'s "already installed" check is
*"can I log into this host?"*, not *"is this particular key present?"*. The DGX
Spark ships with an NVIDIA Sync key and an `~/.ssh/config` entry pointing at it,
so the check always succeeds and the tool skips the copy with:

```
WARNING: All keys were skipped because they already exist on the remote system.
```

That message is wrong — your key was never installed. `-f` skips the check.

Verify by counting keys (expect 2, yours plus NVIDIA's):

```bash
ssh <user>@<host>.local 'grep -c . ~/.ssh/authorized_keys'
```

### Why this matters beyond convenience

Non-interactive SSH — `BatchMode`, which GUI tools like the Hermes desktop app
use — has **no password fallback**. Until your key is authorised you get two
symptoms with one cause, which is easy to misread as an application bug:

| | |
|---|---|
| Interactive `ssh` | works — falls back to password auth |
| `ssh -o BatchMode=yes` | `Permission denied (publickey,password)` |

Confirm with the exact mode those tools use:

```bash
ssh -o BatchMode=yes <user>@<tailscale-ip> 'echo works'
```

If that still fails, check `~/.ssh` on the target: the Spark ships it `0775`,
and sshd's `StrictModes` rejects keys from a group-writable `~/.ssh` — which
presents as a rejected key rather than a permissions problem. `chmod 700 ~/.ssh`.

## Scope

**In scope** — configuring the machine itself:

- **Docker group** — adds me to the `docker` group for sudo-less access
  (Docker itself is pre-installed on the DGX Spark and is *not* touched)
- **Passwordless sudo** — so the Hermes agent can act unattended, with sudo
  I/O logging on so privileged sessions stay auditable (`sudoreplay -l`)
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
- **llama-swap** — a model gateway on `127.0.0.1:8000`, installed natively and
  run as a systemd service. Hermes asks it for a model by name; it starts the
  right vLLM container on demand and brings it back if it dies. The one
  daemon this repo runs — see [The one daemon](#the-one-daemon)
- **Hermes Agent** — installed, left unconfigured (see below)

**Out of scope** — what I happen to be running on it:

Experiments, containers, and one-off services don't belong here. Things like
[PersonaPlex](https://github.com/NVIDIA/personaplex) ship their own Compose
files upstream — clone them somewhere and run them directly when you want
them. Keeping them out of this repo means nothing gets resurrected by a
config sync I forgot about.

**The one exception** is [`workloads/`](workloads/), which stores the
definitions for things I launch by hand. It's version-controlled so I don't
have to re-derive a long flag list, not so that something runs it for me.

[`workloads/llama-swap/config.yaml`](workloads/llama-swap/config.yaml) is the
exception to the exception: Ansible copies it to `/etc/llama-swap/config.yaml`,
because the gateway that reads it is a service and services read their config
from `/etc`. Ansible still only *installs* it — it lands at converge time and
the service is reloaded once, deliberately. It is not watched and not polled;
llama-swap's `--watch-config` exists and is not used.

It lives in `workloads/` rather than inside the role because it is the same
long vLLM flag list the directory exists to preserve, and it belongs next to
[`workloads/vllm/README.md`](workloads/vllm/README.md), which explains where
those flags come from.

## Installed vs. running

The dividing line this repo cares about: Ansible is good at *"make sure X is
installed."* It is bad at *"keep X running."* So installation lives in
`ansible/`, and workloads live in `workloads/` and are started on demand.

Keeping something running is systemd's job, not Ansible's — which is why the
one service this repo runs gets a unit rather than a converge-time `docker
compose up`. Ansible installs and enables it; systemd keeps it alive. See
[The one daemon](#the-one-daemon).

Hermes follows this too. The `hermes` role installs the CLI with
`--non-interactive`, which skips the setup wizard — so it arrives installed but
unconfigured. Configure it by hand (`hermes model`, `hermes tools`) against the
gateway; once the configuration is worth keeping, check `~/.hermes/config.yaml`
into `chezmoi/`. Its `~/.hermes/.env` holds API keys and never belongs in git.

## The one daemon

The rule was *no timers, no daemons, no polling*. `llama-swap` breaks it. This
is the argument for why, so that it reads as a decision rather than a drift.

**What runs is a router, not a workload.** llama-swap is a small Go process
holding `127.0.0.1:8000`. It owns no GPU, loads no weights, and does nothing
until something asks it for a model. No preload hook is configured, so a
rebooted machine nobody talks to sits at **zero** GPU — which is *more*
faithful to "runs when I say so" than the thing it replaces: a vLLM container
with `restart: unless-stopped` that came back at every boot and held ~60 GB
waiting for a request that might never arrive.

**It retires an exception rather than adding one.** vLLM carried
`restart: unless-stopped` because it once crashed mid-request
(`CUBLAS_STATUS_INTERNAL_ERROR`) and stayed dead, while the Hermes Telegram
gateway — which *does* auto-start — carried on accepting messages it had no
model to answer. That policy fixed the container but not the incident: the
request in flight when it died still failed, and so did every request during
the multi-minute reload. llama-swap notices the engine exit, relaunches on the
next request, and **holds that request until the model is ready**. The caller
sees a slow reply instead of an error. Same problem, better answer — and the
container no longer needs a restart policy, which also removes the second
controller that would otherwise be fighting the gateway over the GPU.

**It still doesn't poll.** `--watch-config` polls the config file every two
seconds and is deliberately unused. That file is only ever written by
`./setup.sh`, which reloads the service itself.

What this costs: a crash at 03:00 is repaired on the next request, not
proactively. This is recovery on demand, not supervision. For the thing it's
for — surviving an overnight run, where requests are arriving — that's the
right trade, but it is a trade.

Operational detail lives in
[`workloads/llama-swap/README.md`](workloads/llama-swap/README.md).

## Where things live on disk

| What | Path |
|---|---|
| Ollama binary | `/usr/local/bin/ollama` |
| Ollama models | `/usr/share/ollama/.ollama/models` |
| Ollama service override | `/etc/systemd/system/ollama.service.d/10-models-dir.conf` |
| llama-swap binary | `/usr/local/bin/llama-swap` |
| llama-swap config | `/etc/llama-swap/config.yaml` (from `workloads/llama-swap/config.yaml`) |
| llama-swap service | `/etc/systemd/system/llama-swap.service` |
| HuggingFace model cache | `~/.cache/huggingface/hub` (bind-mounted into every vLLM container) |
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
├── configure.sh                         # Supply secrets. Prompts, no sudo.
├── ansible/
│   ├── playbook.yml
│   ├── group_vars/all.yml
│   └── roles/
│       ├── docker/                      # docker group membership only
│       ├── sudo/                        # passwordless sudo + I/O logging
│       ├── tooling/                     # vim, zsh, git, ripgrep, gh,
│       │                                #   oh-my-zsh, p10k
│       ├── ollama/                      # native Ollama install + service
│       ├── llama_swap/                  # model gateway install + service
│       ├── chezmoi/                     # chezmoi install + apply
│       └── hermes/                      # Hermes CLI install (unconfigured)
├── chezmoi/
│   ├── dot_bashrc
│   ├── dot_zshrc
│   ├── dot_p10k.zsh
│   └── dot_gitconfig.tmpl               # templated git identity + gh helper
├── workloads/
│   ├── llama-swap/                      # model catalogue — copied to /etc
│   └── vllm/                            # Qwen3.6-35B-A3B NVFP4: flags + why
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

- **Runs when I say so** — no timers, no polling, and no workload starts
  itself. One daemon is an exception; see [The one daemon](#the-one-daemon)
- **Idempotent** — safe to re-run at any point
- **Non-destructive** — never reinstalls or modifies pre-installed system
  software (Docker, NVIDIA Container Toolkit, drivers, CUDA)
- **Machine setup, not workload definition** — this repo describes the
  computer, not what's currently running on it
