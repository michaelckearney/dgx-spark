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
./setup.sh
```

That is the whole thing. One command, first run and every run after.

It installs Ansible if you don't have it, configures the machine, and — if
anything still needs a value from you, like a GitHub token — asks for it right
there. Press Enter at any prompt to skip it; you won't be asked again, and
nothing else breaks.

Re-run it any time. Every step is idempotent, and it only asks about things it
has never asked about before.

```bash
./setup.sh --check   # dry run: shows what would change, changes nothing
```

Anything else you pass goes straight through to `ansible-playbook`, which is
what makes this work:

```bash
./setup.sh --extra-vars "git_user_name='Ada Lovelace' git_user_email=ada@example.com"
```

Left alone, the git identity defaults to this machine's `user@hostname`, so the
repo works as-is for anyone without inheriting someone else's.

### When nobody is at the keyboard

`./setup.sh` is also what an agent or a cron job runs. With no terminal
attached it asks nothing at all: it applies every secret already stored, skips
the rest, prints what is still missing, and exits 0. A missing secret makes the
result smaller — it never blocks the run.

That is why there is no separate configure step. There used to be one, and it
existed only to keep prompts away from unattended runs; detecting the terminal
does the same job without making you learn a second command.

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
- **Dotfiles** — `~/.bashrc`, `~/.zshrc`, `~/.p10k.zsh`, `~/.gitconfig`
- **Tailscale** — installed and running, joined once you supply a credential. Gives the
  machine a private `100.x` address reachable from my own devices anywhere.
  SSH is unchanged — same OpenSSH, same keys; Tailscale only supplies the route.
  Tailscale SSH (`--ssh`) is deliberately *not* enabled, since it would
  authenticate by tailnet membership rather than by private key on a host with
  passwordless sudo.
- **Ollama** — installed natively, running as a systemd service
- **llama-swap** — a model gateway on `127.0.0.1:8000`, installed natively and
  run as a systemd service. Hermes asks it for a model by name; it starts the
  right vLLM container on demand and brings it back if it dies. The one
  model gateway — see [What it installs, it runs](#what-it-installs-it-runs)
- **Hermes Agent** — installed, left unconfigured (see below)
- **Hermes agent profiles** — repo-managed, materialised from
  [`profiles/`](profiles/) on every run. `sysadmin` makes OS changes *through*
  this repo: it edits the `tooling` role, converges, verifies, and commits.
  `harbor` develops the Harbor project and deliberately makes no OS changes at
  all — it says what it needs and hands that work to `sysadmin`.

  The split is about context rather than permissions. Knowing how to edit these
  roles is a lot of detail that has nothing to do with Harbor, so only one
  profile carries it. Each profile's contract is its `SOUL.md`; its reference
  documentation lives in `profiles/<name>/skills/` and is read **in place**,
  never copied — a profile's own `skills/` directory belongs to the agent, and
  Ansible must not touch what `hermes update` and the background review write
  there. Both profiles commit but never push, and neither has a gateway.

**Out of scope** — what I happen to be running on it:

Experiments, containers, and one-off services don't belong here. Things like
[PersonaPlex](https://github.com/NVIDIA/personaplex) ship their own Compose
files upstream — clone them somewhere and run them directly when you want
them. Keeping them out of this repo means nothing gets resurrected by a
config sync I forgot about.

[`workloads/llama-swap/`](workloads/llama-swap/) is the one thing that sits
between the two. It holds the model catalogue and the notes on operating the
gateway — not a workload to launch, but the description of what the gateway is
allowed to launch, and the provenance of every non-obvious vLLM flag in it.

Ansible copies the catalogue to `/etc/llama-swap/config.yaml`, because the
gateway that reads it is a service and services read their config from `/etc`.
It lands at converge time and the service is reloaded once, deliberately. It is
not watched and not polled; llama-swap's `--watch-config` exists and is not
used.

It lives in `workloads/` rather than inside the role because it is the long
vLLM flag list that directory exists to preserve, and the file carries the
provenance of every non-obvious flag inline.

## What it installs, it runs

Ansible is good at *"make sure X is installed"* and bad at *"keep X running"* —
so the two jobs are split rather than blurred. Ansible installs a unit and
enables it; **systemd** keeps it alive. Nothing is started with a converge-time
`docker compose up`, and nothing depends on `./setup.sh` being re-run to come
back after a reboot.

Four services are managed this way:

| Service | What it is |
|---|---|
| `tailscaled` | the network path to this machine |
| `ollama` | everyday local inference |
| `llama-swap` | the model gateway — see below |
| `hermes-gateway` | the agent's cron ticker and messaging adapters |

This repo used to say *no timers, no daemons, no polling*, with llama-swap as a
single reasoned exception. That framing is gone: with four services under
management it described the code less and less accurately, and a rule you keep
excepting is not a rule. The honest version is the heading — **what this repo
installs, it also runs.**

What survives from the old rule is the part that was actually load-bearing:
**nothing resurrects a workload you stopped on purpose, and nothing holds the
GPU speculatively.**

`workloads/` is now documentation plus one config file. The vLLM container is
started by llama-swap on demand and by nothing else.

### Why llama-swap earns a daemon

**What runs is a router, not a workload.** A small Go process holding
`127.0.0.1:8000`. It owns no GPU, loads no weights, and does nothing until
something asks it for a model. No preload hook is configured, so a rebooted
machine nobody talks to sits at **zero** GPU — more faithful to "runs when I
say so" than the thing it replaced: a vLLM container with
`restart: unless-stopped` that came back at every boot and held ~60 GB waiting
for a request that might never arrive.

**It retired an exception rather than adding one.** vLLM carried that restart
policy because it once crashed mid-request (`CUBLAS_STATUS_INTERNAL_ERROR`) and
stayed dead, while the Hermes gateway carried on accepting messages it had no
model to answer. That fixed the container but not the incident: the request in
flight still failed, and so did every request during the multi-minute reload.
llama-swap notices the engine exit, relaunches on the next request, and **holds
that request until the model is ready**. The caller sees a slow reply instead of
an error.

**It still doesn't poll.** `--watch-config` polls the config file every two
seconds and is deliberately unused. That file is only ever written by
`./setup.sh`, which reloads the service itself.

What this costs: a crash at 03:00 is repaired on the next request, not
proactively. Recovery on demand, not supervision — the right trade for
surviving an overnight run, but a trade.

### Hermes

The `hermes` role installs the CLI with `--non-interactive`, which skips the
setup wizard, and stands up `hermes-gateway` as a user service. The gateway is
**not** conditional on Telegram: it runs the cron ticker for every profile, so
scheduled agent work depends on it whether or not a messaging adapter exists.
`loginctl enable-linger` is what lets it survive logout and return after a
reboot.

Model and tool configuration still happen by hand (`hermes model`,
`hermes tools`); once worth keeping, add `~/.hermes/config.yaml` to the
`dotfiles` role. `~/.hermes/.env` holds credentials and never belongs in git.

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
| Dotfile sources | `roles/dotfiles/files/` and `roles/dotfiles/templates/` |
| Oh My Zsh | `~/.oh-my-zsh` |
| Powerlevel10k | `~/.oh-my-zsh/custom/themes/powerlevel10k` |

Ollama is installed natively rather than in a container specifically so the
model directory is a real, browsable path — and so it talks to the GPU
directly, without a passthrough layer in between.

## Repository structure

```
├── setup.sh                     # the only command
├── ansible.cfg                  # so `ansible-playbook site.yml` just works
├── site.yml                     # the play
├── inventory/
│   ├── hosts.yml                # one host, local connection
│   └── group_vars/all/main.yml  # site-specific values only
├── roles/
│   ├── docker/                  # docker group membership only
│   ├── sudo/                    # passwordless sudo + I/O logging
│   ├── tooling/                 # vim, zsh, git, ripgrep, gh, oh-my-zsh, p10k
│   ├── tailscale/               # client install; joining is the secrets role
│   ├── ollama/                  # native Ollama install + service
│   ├── llama_swap/              # model gateway install + service
│   ├── dotfiles/                # shell + git config, from files
│   ├── hermes/                  # Hermes CLI install (unconfigured)
│   ├── hermes_profiles/         # agent profiles, from files
│   └── secrets/                 # prompts, stores, and applies credentials
├── profiles/                    # Hermes agent profiles: SOUL.md, config, skills
├── workloads/llama-swap/        # model catalogue, deployed to /etc
└── docs/setup.md
```

Every role keeps its own knobs in `defaults/main.yml`. `group_vars` holds only
the handful of values that differ between one person's machine and another's.

The play does **not** run as root. Tasks that need root ask for it themselves,
which is why nothing has to be told who the login user is.

## Secrets

There is no separate command. `./setup.sh` asks for anything it has never asked
about, when there is someone to ask.

Each secret has three states, not two:

| State | What happens next |
|---|---|
| **stored** | applied on every run |
| **declined** | remembered — you are not asked again |
| **never asked** | you are asked, if a human is present |

Declining is a real answer. Press Enter and the marker in
`/etc/dgx-spark/declined` stops the nagging; delete that file to be asked
again.

### Where they live

`/etc/dgx-spark/credstore` — one root-owned file per secret, mode `0600`, in a
`0700` directory. **Deliberately not encrypted:** the same values end up in
plaintext in gh's token store and `~/.hermes/.env` on this same disk, so
encrypting the source while its copies sit unencrypted two directories away
would be ceremony, not security. If the disk needs protecting, that is a
full-disk encryption question.

The store is not in this repo and never should be. Back it up separately — a
git clone plus a restored credstore is what lets `./setup.sh` rebuild this
machine with nobody retyping anything. That recoverability is the whole reason
it exists.

### How each one converges

The rule is not the same for all three, and the difference is the interesting
part:

| Secret | Goes to | Rule |
|---|---|---|
| `github` | gh's token store | `gh auth token` hands it back, so: plain diff |
| `telegram` | `~/.hermes/.env` + gateway | `lineinfile` diffs it; the gateway restarts **only** on a real change |
| `tailscale` | the tailnet join | Nothing hands it back and nothing needs it twice — a joined machine is left alone |

That last row is load-bearing. Tailscale is the only way to reach this machine
remotely, so a converge must never re-authenticate a working node against a
credential that has since expired or been revoked. The join is gated on *not
already being on the tailnet*; the stored value is for the next rebuild.

The Telegram rule matters for a smaller reason that still bites: without the
handler gate, adding an apt package would restart the gateway and drop a live
conversation.

### Notes

The GitHub token needs `repo` and `read:org` (classic). Unlike `gh auth login`'s
browser flow a PAT does not refresh itself — when it expires pushes start
failing, and running `./setup.sh` after deleting the stored file replaces it.

For Tailscale, prefer an **OAuth client secret** over a one-off auth key. Auth
keys expire at 90 days maximum and one-off keys work exactly once, so a stored
auth key rots in place — silently, to be discovered on the day you rebuild. Set
`tailscale_tags` to match the tag the client is scoped to.

## Design principles

- **Nothing resurrects what you stopped, and nothing holds the GPU
  speculatively** — services are managed, workloads are demand-driven
- **Idempotent** — safe to re-run at any point
- **Non-destructive** — never reinstalls or modifies pre-installed system
  software (Docker, NVIDIA Container Toolkit, drivers, CUDA)
- **Machine setup, not workload definition** — this repo describes the
  computer, not what's currently running on it
