---
name: dgx-spark-ansible
description: Conventions for editing Ansible roles in the dgx-spark repo — idempotency, check-mode gating, ordering, and the comment style the repo expects.
metadata:
  hermes:
    tags: [ansible, dgx-spark, infrastructure]
    category: devops
---

# Editing Ansible in the dgx-spark repo

This repo describes one machine. `./setup.sh` must be able to rebuild it from
nothing, so anything you change on the machine has to be represented here.

## The shape of the repo

- `setup.sh` — the only command. Installs Ansible if absent, decides whether a
  human is present, and runs `site.yml`. It contains no other logic, and new
  logic does not belong in it.
- `ansible.cfg` — inventory path, roles path, output format. Present so that a
  bare `ansible-playbook site.yml` works from a clone with no flags.
- `site.yml` — the play, at the repo root. Role order matters and every
  non-obvious ordering carries a comment explaining what breaks otherwise.
  Read those before reordering anything.
- `inventory/hosts.yml` — one host, `connection: local`.
- `inventory/group_vars/all/main.yml` — site-specific values only (git
  identity, tailnet tags). Everything else belongs in the owning role's
  `defaults/main.yml`.
- `roles/<name>/` — `defaults/`, `tasks/`, `handlers/`, `templates/`.
- `workloads/` — things launched by hand, not by Ansible. The one exception is
  `workloads/llama-swap/config.yaml`, which Ansible copies to `/etc`.
- `profiles/` — the Hermes agent profiles, including this one.

There is no `configure.sh`. Secrets are prompted for by the `secrets` role
when a human is present, and applied from `/etc/dgx-spark/credstore` whether
or not one is. You will normally run with no human present, which means every
prompt is skipped and the run still succeeds.

## Rules that are not negotiable

**Idempotent.** Every task must be safe to run repeatedly. Use `creates:`,
`state: present`, version gates, or a `stat`/`command` probe registered and
tested. Never write a task whose second run does something different from
its first.

**Check-mode safe.** `shell:` and `command:` modules do not execute under
`--check`. A block that depends on something such a task installs must be
gated, or a dry run against a fresh machine fails on the missing thing. The
`ollama` and `llama_swap` roles both show the pattern:

```yaml
- name: Check whether X is installed
  ansible.builtin.command: which x
  register: x_check
  changed_when: false
  failed_when: false
  check_mode: false          # read-only probe; safe during --check

- name: Configure X
  when: x_check.rc == 0 or not ansible_check_mode
  block:
    ...
```

**Non-destructive.** Never reinstall or modify pre-installed system software —
Docker, the NVIDIA Container Toolkit, drivers, CUDA. Verify their presence;
do not manage them.

**Validate anything that can lock you out.** The `sudo` role runs
`visudo -cf` via `validate:` before the file moves into place; the
`llama_swap` role does the same with `--validate` on its config. A broken
sudoers file or gateway config on a machine reached over SSH is not
recoverable remotely.

## Adding an apt package

This is the common task. It is one edit:

```yaml
- name: Install baseline shell tooling packages
  ansible.builtin.apt:
    name:
      - vim
      - zsh
      # ... add here
    state: present
    update_cache: true
    cache_valid_time: 3600
```

`update_cache` is already set and load-bearing — nothing else in the repo
refreshes the apt index, and a stale index gives 404s on withdrawn versions.

Do not add a package by running `apt install` and then editing the file to
match. Edit first, converge, then verify.

## Privilege

The play does **not** escalate. It runs as the login user, and individual
tasks that need root carry `become: true` themselves.

So when you add a task, ask what it touches. Anything under `/etc`, `/usr`,
`/var`, apt, or systemd needs `become: true`. Anything under the user's own
home needs nothing, and `ansible_facts['user_id']` and `ansible_facts['env']['HOME']` are already
correct without being passed in.

Do not add `become` at the play level to make one task work. That inversion is
what an earlier version of this repo did, and it forced every user-level task
to undo it.

## Comment style

Every non-obvious line in this repo records the failure that produced it —
the chezmoi TTY hang, the stale apt index, `ssh-copy-id -f`, the vLLM crash
behind a live bot. Match that. A comment saying *what* the code does is noise;
a comment saying *what broke without it* is why this repo is readable a year
later.

When you add something, you have the request but not the failure story. Ask
for it rather than inventing one, and if there genuinely isn't one, say what
the line is for and why the obvious alternative was rejected.

## Why the loop is ordered the way it is

Your SOUL.md gives the sequence; this is why deviating from it is costly.

**Verify before you commit.** A commit that lands before verification produces
a repository describing a state the machine is not in. That is worse than
untracked drift, not better: drift is a known unknown, but a playbook that
lies is believed. Ansible reporting that a task ran is not the same as the
thing existing — `changed: [spark]` on an apt task tells you apt was invoked,
not that the binary is on PATH.

**Read the `--check` diff rather than skimming it.** Check mode is where a
mistake is still free. It is also weaker than it looks: `shell:` and `command:`
modules do not execute under `--check`, so a clean dry run against a machine
missing a dependency proves less than you would like.

**Leave failures dirty.** If apply or verify fails, stop with the working tree
as it is. A half-repaired run with extra tasks invented to patch it is much
harder to understand than the original failure.

## Commit messages

This repo's distinguishing quality is that every non-obvious line records the
failure that produced it — the chezmoi TTY hang, the stale apt index,
`ssh-copy-id -f`, the vLLM crash behind a live bot. That archaeology is why it
is readable a year later.

You arrive with the request but not the failure story. Ask for it. Write down
who asked, what needed this, and what broke or was missing without it. A commit
that says only "add ripgrep-all" makes the repository thinner.

Match the voice of the existing history: a comment saying *what* the code does
is noise; a comment saying *what broke without it* is the point.

## Why the out-of-bounds list is what it is

Each entry has a specific failure behind it, not a general caution:

- **`profiles/`** — your own configuration lives here, including your approval
  mode. You must not be the one who widens your own permissions.
- **`roles/tailscale/`** — the only remote access path to this machine. An
  unconditional `tailscale up` against a working node re-authenticates it, so a
  credential that has since expired turns a routine converge into a lockout.
- **`~/.ssh/` and sshd** — same reason. Note the Spark ships `~/.ssh` as `0775`
  and sshd's `StrictModes` rejects keys from a group-writable directory, which
  presents as a rejected key rather than a permissions problem.
- **`chezmoi/`** — chezmoi applies with `--force`, so an edit here silently
  overwrites live dotfiles on the next converge.
- **Secrets** — you never need to read one to change how this machine is set
  up. If a change appears to need one, it is a human's to make.
