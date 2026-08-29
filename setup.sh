#!/usr/bin/env bash
# setup.sh — apply this repo's configuration to the machine you're sitting at.
#
# Run it by hand, from a clone of this repo, whenever you want to sync.
# Nothing in this repo runs on its own.
#
#   git clone https://github.com/michaelckearney/dgx-spark.git
#   cd dgx-spark && ./setup.sh
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${REPO_ROOT}/ansible/playbook.yml"

echo "==> Applying DGX Spark configuration from ${REPO_ROOT}"

# --- Install Ansible if not present ---
if ! command -v ansible-playbook &>/dev/null; then
    echo "==> Ansible not found, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq software-properties-common
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt-get install -y -qq ansible
else
    echo "==> Ansible is already installed."
fi

# --- Argument handling ---
# --check is consumed here; everything else is forwarded verbatim to
# ansible-playbook, which is what makes the documented override work:
#   ./setup.sh --extra-vars "git_user_name='Ada Lovelace'"
CHECK_FLAGS=()
PASSTHROUGH=()
for arg in "$@"; do
    if [[ "$arg" == "--check" ]]; then
        CHECK_FLAGS=(--check --diff)
    else
        PASSTHROUGH+=("$arg")
    fi
done

if [[ ${#CHECK_FLAGS[@]} -gt 0 ]]; then
    echo "==> Dry run (no changes will be made)"
fi

# The ${arr[@]+"${arr[@]}"} form is required: under `set -u`, expanding an
# empty array with "${arr[@]}" is an unbound-variable error on older bash.
ansible-playbook "${PLAYBOOK}" \
    ${CHECK_FLAGS[@]+"${CHECK_FLAGS[@]}"} \
    --ask-become-pass \
    --extra-vars "target_user=$(id -un) target_home=${HOME}" \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}

echo "==> Done."
echo "==> If docker group membership changed, log out and back in."

# Report any secrets still needed. Delegated to configure.sh so the probes live
# in exactly one place; --hint prints nothing when everything is configured.
# Never prompts, so setup.sh stays safe to run unattended.
if [[ ${#CHECK_FLAGS[@]} -eq 0 && -x "${REPO_ROOT}/configure.sh" ]]; then
    "${REPO_ROOT}/configure.sh" --hint || true
fi
