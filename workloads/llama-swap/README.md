# llama-swap — the model gateway

One OpenAI-compatible endpoint on `http://localhost:8000/v1` that starts the
right vLLM container on demand. Ask for a model by name; if it isn't running,
the gateway starts it and holds your request until it's ready.

This is [the one daemon](../../README.md#the-one-daemon) — the deliberate
exception to this repo's no-daemons rule. It is installed and started by
`ansible/roles/llama_swap`, not by hand.

| | |
|---|---|
| Gateway | `127.0.0.1:8000` — llama-swap, systemd, enabled at boot |
| Model containers | `127.0.0.1:5800+` — one at a time, started on demand |
| Catalogue | this directory's `config.yaml` → `/etc/llama-swap/config.yaml` |
| Binary | `/usr/local/bin/llama-swap` |
| Unit | `/etc/systemd/system/llama-swap.service` |

Nothing is loaded at boot. A rebooted machine nobody talks to holds **zero**
GPU — `docker ps` is empty and `/v1/models` still answers with the full
catalogue.

## Before you edit a `cmd`

**`cmd` is not run through a shell.** Each line is comment-stripped, then the
whole block is shlex-split into argv and exec'd directly. No pipes, no
redirects, no globbing, and **no `$VAR` expansion**. The only substitutions
are llama-swap's own: `${PORT}`, `${MODEL_ID}`, `${PID}` (in `cmdStop` only),
macros, and `${env.NAME}`.

The trap this sets is expensive and silent. A bare `${HOME}` in a `-v` mount
is passed to Docker as the literal seven characters `${HOME}`. Docker creates
a directory with that name, bind-mounts it, the container finds an empty
cache, and vLLM re-downloads **21.85 GiB**. It looks like a network problem.

`${env.HOME}` looks like the fix and is worse: the service runs as the
`llama-swap` user, so it resolves to `/var/lib/llama-swap` — a *valid* path
Docker will happily create, with the same 21.85 GiB result.

The fix is `${env.HF_CACHE}`, set in the systemd unit from
`llama_swap_hf_cache` in `ansible/group_vars/all.yml`. An unset `${env.*}` is
a hard config-load error, so a missing `Environment=` line fails loudly
instead of mounting the wrong directory.

Use `/usr/bin/docker`, absolute. A systemd service gets a minimal `PATH` and
there is no shell here to resolve a bare `docker`.

## Adding a model

1. **Pull the weights first.** Cold starts are not the gateway's job — 21.85
   GiB takes up to 45 minutes and `healthCheckTimeout` is deliberately not
   sized for it. Run the container by hand once, or `hf download`, then add
   it here so llama-swap only ever does warm starts.

2. **Copy the existing entry** and change the model id, the `--name`, and the
   vLLM flags. Four things must stay:

   - `-p 127.0.0.1:${PORT}:8000` — **keep the `127.0.0.1:`**. llama-swap's
     own docs write `-p ${PORT}:8000`, which binds every interface including
     the tailnet, on an endpoint with no authentication.
   - `--rm` — without it the second load fails with `name already in use`.
   - `cmdStop: /usr/bin/docker stop -t 30 <name>` — without it llama-swap
     kills the local docker client and the container keeps running with the
     GPU held.
   - **No `-d`.** llama-swap tracks the model by its child process. A
     detached client exits immediately, which reads as "the model died".

3. **`--name` cannot be `${MODEL_ID}`.** llama-swap's docs use that pattern
   and it does not survive a HuggingFace id: `nvidia/Qwen3.6-35B-A3B-NVFP4`
   contains a `/`, which is illegal in a Docker container name. Use a literal
   name — you want one anyway, so `docker logs vllm-qwen3-35b` is something
   you can type.

4. **The key is the public model name.** It is what `/v1/models` reports and
   what Hermes has saved. Renaming it silently 404s Hermes.

5. **Validate, then apply:**

   ```bash
   HF_CACHE="$HOME/.cache/huggingface/hub" \
     llama-swap --config workloads/llama-swap/config.yaml --validate
   ```

   ```bash
   ./setup.sh
   ```

   The Ansible role validates again before moving the file into place, so a
   broken catalogue never reaches a running service. A config-only change
   gets `SIGHUP`, which leaves an already-loaded model running.

## Ports move when you add a model

`${PORT}` is allocated densely from `startPort` (5800) in **sorted model-ID
order**, to models whose `cmd` uses it. Adding a model whose ID sorts earlier
shifts every later model down by one.

Never hardcode a port. Read it:

```bash
docker ps --format '{{.Names}}\t{{.Ports}}'
```

## Timeouts

The rule is that **the innermost timeout fires first**, so a failure produces
a specific error at the layer that knows what went wrong instead of an
ambiguous one at the layer that doesn't.

| Layer | Setting | Where | Value |
|---|---|---|---|
| Container stop | `docker stop -t` | `cmdStop` in `config.yaml` | 30s |
| Gateway unload | `unloadTimeout` | `config.yaml` | 60s |
| systemd stop | `TimeoutStopSec` | the unit | 180s |
| Model load | `healthCheckTimeout` | `config.yaml` | 1800s |
| Hermes request | `timeout_seconds` | `~/.hermes/config.yaml` | 2100s |
| Hermes stall | `stale_timeout_seconds` | `~/.hermes/config.yaml` | 300s |

Two of these are load-bearing for different reasons.

**`unloadTimeout` must exceed `docker stop -t`, and `TimeoutStopSec` must
exceed `unloadTimeout`.** Docker has to win the race, because Docker knows how
to clean up and a SIGKILL does not — it kills the docker CLI and orphans the
container, leaving ~60 GB of unified memory held by a process nothing points
at, with no error anywhere. systemd's default `TimeoutStopSec` of 90s is close
enough to the boundary to be a coin flip, which is why the unit sets it.

**`healthCheckTimeout` is what makes a crash survivable.** Hermes retries
transport errors, but its budget is roughly 45–60 seconds — an order of
magnitude short of a vLLM reload. The design does not rely on it. It relies on
llama-swap *holding* the retried request for the whole reload, so Hermes never
enters retry at all and sees one slow reply instead of a failed run.

Which means the one thing that must not happen is llama-swap returning early.
Two ways it can, both avoided in `config.yaml`: `healthCheckTimeout` expiring,
and `concurrencyLimit` shedding with a 429. Leave `concurrencyLimit` at its
default — it sits above `--max-num-seqs=8`, so vLLM queues instead.

**Better than any of these numbers:** warm the model deliberately with one
`curl` before an overnight run. Then the multi-minute wait happens once, in
the foreground, where you can watch it.

## Operating it

```bash
systemctl status llama-swap
journalctl -u llama-swap -f
curl -sS http://localhost:8000/v1/models      # catalogue — works with nothing loaded
docker ps                                     # what is actually resident
```

| Endpoint | |
|---|---|
| `/v1/models` | the catalogue, whether or not anything is running |
| `/v1/chat/completions` | inference; loads the model if needed |
| `/ui` | web UI with a live log stream |
| `/metrics` | Prometheus |
| `POST /api/models/unload` | free the GPU now |

**All of that is unauthenticated.** Loopback binding is the entire access
control — the same posture the vLLM container had, but now it also exposes
the log stream and an unload button. Reach the UI from a laptop over SSH,
never by widening the listen address:

```bash
ssh -L 8000:127.0.0.1:8000 <user>@<host>
```

Confirm the binding after any change to the unit:

```bash
ss -ltnp | grep 8000        # must be 127.0.0.1:8000, not *:8000
```

## Troubleshooting

**A model won't load.** `journalctl -u llama-swap -n 50`, then
`docker logs vllm-qwen3-35b` while it's still up. The gateway's own `/health`
reports the *gateway*, not the model — it says nothing about whether a load
succeeded.

**A container is left running after a stop.** The silent failure mode: ~60 GB
held with nothing pointing at it. Happens when a SIGKILL beat `docker stop`,
which means the timeout ladder above is wrong.

```bash
docker ps -a | grep vllm-
docker rm -f vllm-qwen3-35b
```

**vLLM fails on memory even within capacity.** Check Ollama first — it runs
natively as a systemd service and competes for the same unified memory, and
the gateway's one-model-at-a-time rule only covers *its own* models.

```bash
ollama ps
```

Then the known unified-memory quirk, per [`../vllm/README.md`](../vllm/README.md):

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```

**Port 8000 is already in use at startup.** Something else has it — most
likely a hand-started vLLM container from before the gateway existed.
`ss -ltnp | grep 8000`, then stop it.

## Running vLLM without the gateway

For debugging the model rather than the gateway, see
[`../vllm/README.md`](../vllm/README.md), which has the standalone
`docker run` one-liner. It binds 5800, so it does not collide with the
gateway — but it does collide with a gateway-started container of the same
name, so unload first.
