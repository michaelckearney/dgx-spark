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

# --- Dry run first so you can see what would change ---
if [[ "${1:-}" == "--check" ]]; then
    echo "==> Dry run (no changes will be made)"
    exec ansible-playbook "${PLAYBOOK}" \
        --check --diff --ask-become-pass \
        --extra-vars "target_user=$(id -un) target_home=${HOME}"
fi

ansible-playbook "${PLAYBOOK}" \
    --ask-become-pass \
    --extra-vars "target_user=$(id -un) target_home=${HOME}"

echo "==> Done."
echo "==> If docker group membership changed, log out and back in."
