#!/usr/bin/env bash
# setup.sh — set this machine up, and keep it that way.
#
#   git clone https://github.com/michaelckearney/dgx-spark.git
#   cd dgx-spark && ./setup.sh
#
# Run it again any time; every step is idempotent. There is no second command:
# if something still needs a value from you, this asks for it, and if nobody is
# at the keyboard it does everything it can and tells you what is left.
#
#   ./setup.sh            configure the machine
#   ./setup.sh --check    dry run, changes nothing
#
# Anything else is passed straight through to ansible-playbook.
#
# This script deliberately does almost nothing. It exists for the two jobs
# Ansible cannot do for itself: install Ansible, and know whether a human is
# present. Everything else lives in site.yml and roles/.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "==> Installing Ansible..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq software-properties-common
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt-get install -y -qq ansible
fi

# Whether to prompt is a question about the terminal, so bash answers it and
# Ansible is simply told. `pause` degrades safely without a tty on its own —
# it warns and returns empty — but it warns once per prompt, and this is what
# keeps an agent's output clean.
[[ -t 0 ]] && INTERACTIVE=true || INTERACTIVE=false

exec ansible-playbook site.yml -e "interactive=${INTERACTIVE}" "$@"
