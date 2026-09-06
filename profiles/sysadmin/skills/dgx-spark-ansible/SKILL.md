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

- `setup.sh` — installs Ansible if absent, then runs the playbook against
  localhost. Never prompts. Forwards unknown arguments to `ansible-playbook`.
- `configure.sh` — the only interactive script. Collects secrets and writes
  them straight through to the tool that owns them. Stores nothing itself.
- `ansible/playbook.yml` — role order matters and every non-obvious ordering
  carries a comment explaining what breaks otherwise. Read those before
  reordering anything.
- `ansible/group_vars/all.yml` — machine-specific values and cross-repo paths.
- `workloads/` — things launched by hand, not by Ansible. The one exception is
  `workloads/llama-swap/config.yaml`, which Ansible copies to `/etc`.
- `profiles/` — the Hermes agent profiles, including this one.

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

## Ownership under `become: true`

The playbook runs as root. Ansible's `file` module applies ownership to the
final path component only, so a nested path creates root-owned intermediate
directories. When writing under `{{ target_home }}`, create each level
explicitly with `owner: "{{ target_user }}"`.

## Comment style

Every non-obvious line in this repo records the failure that produced it —
the chezmoi TTY hang, the stale apt index, `ssh-copy-id -f`, the vLLM crash
behind a live bot. Match that. A comment saying *what* the code does is noise;
a comment saying *what broke without it* is why this repo is readable a year
later.

When you add something, you have the request but not the failure story. Ask
for it rather than inventing one, and if there genuinely isn't one, say what
the line is for and why the obvious alternative was rejected.
