#!/usr/bin/env bash
# bootstrap.sh — Single entrypoint for DGX Spark configuration
# Usage: curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
set -euo pipefail

REPO_URL="https://github.com/michaelckearney/dgx-spark.git"
REPO_DIR="${HOME}/dgx-spark"
ANSIBLE_DIR="${REPO_DIR}/ansible"

echo "==> DGX Spark bootstrap starting..."

# --- Clone or update the repository ---
if [ -d "${REPO_DIR}/.git" ]; then
    echo "==> Repository exists at ${REPO_DIR}, pulling latest changes..."
    git -C "${REPO_DIR}" pull --ff-only
else
    echo "==> Cloning repository to ${REPO_DIR}..."
    git clone "${REPO_URL}" "${REPO_DIR}"
fi

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

# --- Run the Ansible playbook ---
echo "==> Running Ansible playbook..."
ansible-playbook \
    --inventory "${ANSIBLE_DIR}/inventory.ini" \
    --ask-become-pass \
    "${ANSIBLE_DIR}/playbook.yml"

echo "==> Bootstrap complete."
