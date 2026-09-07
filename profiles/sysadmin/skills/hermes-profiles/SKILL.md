---
name: hermes-profiles
description: How Hermes profiles are structured and repo-managed on this machine — the filesystem layout, why skills are referenced rather than copied, and how to add a profile.
metadata:
  hermes:
    tags: [hermes, profiles, skills, dgx-spark]
    category: devops
---

# Repo-managed Hermes profiles

A profile is a fully independent `HERMES_HOME` — its own `config.yaml`,
`.env`, memory, sessions, skills, gateway, cron, and logs. The default profile
is `~/.hermes` itself; named ones live under `~/.hermes/profiles/<name>/`.

On this machine they are materialised from `profiles/<name>/` in the dgx-spark
repo by `ansible/roles/hermes_profiles`.

## Profiles are pure filesystem

`get_profile_dir()` resolves to `_get_profiles_root() / name`, and profile
discovery iterates that directory filtering on a name regex. There is no
registry. A directory with a valid name **is** a profile.

That is why the role declares the directory tree with `file:` and `copy:`
tasks rather than calling `hermes profile create` — which is not idempotent
(it raises `FileExistsError`) and, as a `command:` task, would be invisible
to `--check`.

## What the repo owns, and what it must not touch

| Path | Owner | Notes |
|---|---|---|
| `SOUL.md` | the repo | Overwritten every converge |
| `config.yaml` | the repo | Rendered from `config.yaml.j2` |
| `.env` | shared | Seeded once; repo owns only specific keys, via `lineinfile` |
| `skills/` | **the agent** | Never written by Ansible |
| `memories/`, `sessions/`, `plans/` | the agent | Created empty, then left alone |

## Why skills are referenced, not copied

This is the part that is easy to get wrong.

Three things write to a profile's `skills/` directory: `hermes update` syncs
bundled skills into it, the background review fork writes skills the agent
learns from experience, and the curator consolidates and prunes the ones it
created. Copying repo skills in with `force: true` would delete all of that
on every `./setup.sh`.

Instead, each profile's `config.yaml` sets `skills.external_dirs` to
`profiles/<name>/skills` in the checkout. Hermes treats external dirs as
read-only, `sync_skills()` skips anything an external dir already provides,
and the curator only prunes skills it created itself.

Consequences worth knowing:

- Repo skills are read live from the checkout. Editing one takes effect
  without a converge.
- Hermes silently drops an `external_dirs` path that does not exist. If repo
  skills stop appearing, check the path resolves before looking anywhere else.
- Local skills win on a name collision, so avoid reusing a bundled skill's
  name in the repo.

## The `.env` seed is load-bearing

A profile without its own `.env` silently inherits API keys from the shell
environment. The role seeds one with `force: false` — present from day one,
never clobbering a real credential written later.

## Adding a profile

1. Create `profiles/<name>/` with `SOUL.md`, `config.yaml.j2`, and `skills/`.
2. Add an entry to `hermes_profiles` in `ansible/group_vars/all.yml`.
3. Converge.

The role needs no change — it loops over that list.

## Approvals

`approvals.mode` is `manual | smart | off`, from `_get_approval_mode()` in
`tools/approval.py`. It is undocumented in Hermes' own example config.

Only commands matching the dangerous-pattern set ever reach a prompt; ordinary
commands run without one. `smart` is deliberately unused here — it asks an
auxiliary LLM to assess each flagged command, and that request goes to the same
llama-swap gateway as the real work.

Deny rules match the command string, so they stop a direct invocation and not
a script containing the same command. They are a guardrail, not a boundary.
