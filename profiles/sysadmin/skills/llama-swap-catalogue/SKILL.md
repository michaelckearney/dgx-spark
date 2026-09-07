---
name: llama-swap-catalogue
description: How the llama-swap model gateway is configured on this machine — the catalogue format, the flags that are load-bearing, and how to add or change a model.
metadata:
  hermes:
    tags: [llama-swap, vllm, models, dgx-spark]
    category: mlops
---

# The llama-swap model gateway

llama-swap is the one daemon this repo runs. It is a router, not a workload:
it holds a port, loads nothing until something asks for a model, and starts
the container for that model on demand.

Every model this agent talks to arrives through it.

## Where things live

| What | Path |
|---|---|
| Catalogue source (edit this) | `workloads/llama-swap/config.yaml` |
| Deployed catalogue | `/etc/llama-swap/config.yaml` |
| Service unit template | `ansible/roles/llama_swap/templates/llama-swap.service.j2` |
| Role | `ansible/roles/llama_swap/` |
| Version + checksum + listen address | `ansible/group_vars/all.yml` |

The role copies the catalogue to `/etc` and reloads the service. It is not
watched and not polled — `--watch-config` exists upstream and is deliberately
unused, because the file is only ever written by `./setup.sh`.

## The endpoint

`127.0.0.1:8000`, loopback only. The endpoint has **no authentication of any
kind** — inference, the `/ui` log stream, and `POST /api/models/unload` are
all open to anything that reaches the port. Loopback is the entire access
control.

Never widen the listen address. To reach the UI from a laptop, forward it:

```bash
ssh -L 8000:127.0.0.1:8000 <host>
```

`/v1/models` is served from the catalogue, so it answers immediately whether
or not a model is loaded. That is why `hermes model` works without starting
anything first.

## Adding or changing a model

The model key is the exact HuggingFace id. It is what `/v1/models` reports,
what gets forwarded upstream, and what Hermes has saved in its config —
renaming the key silently 404s every client.

Three things in a `cmd` are load-bearing and easy to get wrong:

- **`127.0.0.1:` on the `-p` mapping is not optional.** Upstream docs write
  `-p ${PORT}:8000`, which binds every interface including the tailnet, on an
  endpoint with no authentication.
- **`--rm` is not optional.** Without it the second load fails with "name
  already in use".
- **Never `-d`.** llama-swap tracks the model by the child process; a detached
  client exits immediately, which reads as "the model died".

`${PORT}` is the host port. The container always listens on 8000 internally.

## Changing the version

`llama_swap_version` and `llama_swap_sha256` in `group_vars/all.yml` move
together. Get both from the release's checksums file. The install is
version-gated rather than `creates:`-gated, so bumping the version actually
upgrades. Note the tag carries a `v` and the asset filename does not.

## After any change

The role validates the catalogue with `llama-swap --config <file> --validate`
before it moves into place, then flushes handlers and probes `/v1/models`.
A `Type=simple` unit reports success as soon as the process forks, so the
probe is what distinguishes "started" from "actually serving".

If you changed the catalogue, converge and confirm the probe passed. Do not
assume a successful playbook run means the gateway is answering.
