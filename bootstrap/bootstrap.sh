#!/usr/bin/env bash
# bootstrap.sh — Single entrypoint for DGX Spark configuration
# Usage: curl -fsSL https://raw.githubusercontent.com/michaelckearney/dgx-spark/main/bootstrap/bootstrap.sh | bash
set -euo pipefail

REPO_URL="https://github.com/michaelckearney/dgx-spark.git"
PLAYBOOK="ansible/playbook.yml"

echo "==> DGX Spark bootstrap starting..."

# --- Install Ansible if not present ---
if ! command -v ansible-pull &>/dev/null; then
    echo "==> Ansible not found, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq software-properties-common
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt-get install -y -qq ansible
else
    echo "==> Ansible is already installed."
fi

# --- Run ansible-pull to clone repo and apply playbook ---
echo "==> Running ansible-pull..."
sudo ansible-pull \
    --url "${REPO_URL}" \
    --checkout main \
    --directory /opt/dgx-spark \
    --extra-vars "target_user=$(whoami) target_home=${HOME}" \
    "${PLAYBOOK}"

echo "==> Bootstrap complete."
echo "==> A systemd timer is now active and will auto-reconcile every minute."
echo "==> Check status: systemctl status dgx-spark-reconcile.timer"
