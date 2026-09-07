#!/usr/bin/env bash
# configure.sh — supply the secrets that this repo deliberately cannot contain.
#
#   ./configure.sh              configure whatever is still missing
#   ./configure.sh telegram     re-prompt just this one (rotation)
#   ./configure.sh --list       show what is configured — never values
#   ./configure.sh --help
#
# This script ACQUIRES secrets. It does not apply them.
#
# Each secret is written to the credential store at /etc/dgx-spark/credstore,
# and ./setup.sh is what distributes it to the tool that consumes it. That
# split is the whole point: this script is the only thing in the repo that
# prompts a human, and setup.sh is the only thing that changes the machine.
#
# Why a store at all, when an earlier version of this script wrote each secret
# straight through to its consumer: secrets were the one part of this repo that
# could not be re-converged. Lose gh's token store or ~/.hermes/.env — a
# reimage, a stray rm — and the only recovery was a human retyping. Everything
# else in this repo rebuilds from a git clone and one command. Now secrets do
# too.
#
# The store is plain root-owned files, mode 0600, in a 0700 directory. There is
# deliberately no encryption: the same secrets end up in plaintext in gh's token
# store and ~/.hermes/.env on this same disk, so encrypting the source while its
# copies sit unencrypted two directories away would be ceremony rather than
# security. If the disk itself needs protecting, that is a full-disk encryption
# question, not one this file can answer.
#
# Reads live in ansible/roles/secrets. If the storage ever needs to change —
# age, systemd-creds, a hardware token — vault_write below and that role's
# slurp tasks are the only two places that know how a secret is stored.
#
# Needs sudo to write to /etc. With this repo's passwordless sudo that is
# silent.
set -euo pipefail

# The Hermes command lives here; a non-login shell won't have it on PATH.
export PATH="$HOME/.local/bin:$PATH"

VAULT_DIR="/etc/dgx-spark/credstore"

SECRETS=(github telegram tailscale)

# Hermes' own validation regex, from hermes_cli/setup.py. A token that fails
# this is accepted by the .env writer and then silently disables the Telegram
# adapter at gateway start — an error in the log and nothing else.
#
# Format checks matter more now than they did when this script applied secrets
# itself. It used to store a token and immediately prove it worked; acquisition
# and application are separate steps now, so a malformed value would sit in the
# store looking configured until the next converge failed. These catch the
# common typo at the point where a human can still fix it.
TELEGRAM_TOKEN_RE='^[0-9]+:[A-Za-z0-9_-]{30,}$'

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[33m○\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

# Return codes from the configure_* functions. Declining to supply a secret is
# a legitimate outcome, not a failure — it must not colour the exit status,
# because "I haven't set Telegram up yet" is the normal case for a while.
readonly RC_DONE=0
readonly RC_FAILED=1
readonly RC_SKIPPED=2

# --- the credential store ----------------------------------------------------
# The only two functions in this repo that know how a secret is stored. The
# read side lives in ansible/roles/secrets, which slurps these files as root.

vault_path() { printf '%s/%s' "$VAULT_DIR" "$1"; }

# Existence only. This script never reads a secret back — nothing here needs
# the value, and not reading it means no secret is ever in this process's
# memory longer than the moment between the prompt and the write.
vault_has() { sudo test -f "$(vault_path "$1")"; }

# `umask 077; cat >` inside the sudo'd shell rather than `tee` then `chmod`, so
# the file is never briefly world-readable. The value arrives on stdin, so it
# is never in argv, which is world-readable via ps for the life of the process.
vault_write() {
    local name="$1" path
    path="$(vault_path "$name")"
    sudo install -d -m 0700 -o root -g root "$VAULT_DIR" || return 1
    sudo sh -c 'umask 077; cat > "$1"' _ "$path" || return 1
    sudo chown root:root "$path"
}

is_configured() { vault_has "$1"; }

missing_secrets() {
    local s
    for s in "${SECRETS[@]}"; do
        is_configured "$s" || printf '%s\n' "$s"
    done
}

require_tty() {
    [[ -t 0 ]] && return 0
    err "configure.sh needs an interactive terminal to prompt for secrets."
    # Keep the whole message on one stream so it doesn't interleave.
    say "" >&2
    print_status >&2
    exit 1
}

# --- github ------------------------------------------------------------------

configure_github() {
    cat <<'EOF'

  GitHub personal access token
  ────────────────────────────
  Create one at https://github.com/settings/tokens

  Use a CLASSIC token with BOTH scopes:
      repo        push over HTTPS
      read:org    required by `gh auth login` itself; it refuses without it

  Fine-grained tokens don't advertise scopes the way gh checks for them, so
  they are likely to be rejected. Classic is the reliable choice.

  Note: unlike `gh auth login`'s browser flow, a PAT does not refresh itself.
  When it expires, pushes start failing — re-run `./configure.sh github`.

  Press Enter on its own to skip; run `./configure.sh github` when ready.

EOF
    local token
    read -rsp "  GitHub token (Enter to skip): " token; echo
    if [[ -z "$token" ]]; then
        skip "GitHub skipped — pushing over HTTPS won't work until it's set"
        return "$RC_SKIPPED"
    fi

    # `set -e` is NOT in effect inside this function: main invokes it as
    # `configure_x || rc=$?`, and testing a function's return value disables
    # errexit throughout its body. Every fallible command must therefore be
    # checked explicitly, or a failure sails on to the success message.
    if ! printf '%s' "$token" | vault_write github; then
        unset token
        err "Could not write to the credential store."
        return "$RC_FAILED"
    fi
    unset token
    ok "GitHub token stored"
}

# --- telegram ----------------------------------------------------------------

configure_telegram() {
    cat <<'EOF'

  Hermes Telegram gateway
  ───────────────────────
  Bot token comes from @BotFather      https://t.me/BotFather
  Your numeric user ID from @userinfobot  https://t.me/userinfobot

  Leaving the allowlist blank is safe: Hermes denies unknown senders and
  routes them through DM pairing (`hermes gateway pairing approve`). Blank
  does NOT mean "anyone can use the bot".

  Don't have a bot yet? Press Enter on its own to skip. Nothing else depends
  on this — Hermes works fine from the terminal without it.

EOF
    local token
    while :; do
        read -rsp "  Telegram bot token (Enter to skip): " token; echo
        if [[ -z "$token" ]]; then
            skip "Telegram skipped — the gateway won't be installed"
            return "$RC_SKIPPED"
        fi
        [[ "$token" =~ $TELEGRAM_TOKEN_RE ]] && break
        warn "That doesn't look like a BotFather token (expected <digits>:<30+ chars>)."
        warn "Hermes would store it and then quietly disable Telegram. Try again."
    done

    local ids
    read -rp "  Allowed user IDs (comma-separated, blank for DM pairing): " ids
    ids="${ids//[[:space:]]/}"

    if ! printf '%s' "$token" | vault_write telegram; then
        unset token
        err "Could not write to the credential store."
        return "$RC_FAILED"
    fi
    unset token

    # Stored beside the token rather than in group_vars: it is a list of real
    # people's account IDs, which is not a secret but is not something to
    # commit either. Written even when blank, so clearing the allowlist
    # actually clears it on the next converge.
    if ! printf '%s' "$ids" | vault_write telegram_allowed_users; then
        err "Token stored, but the allowlist could not be written."
        return "$RC_FAILED"
    fi

    ok "Telegram token stored"
    if [[ -n "$ids" ]]; then
        ok "Allowlist stored (${ids})"
    else
        ok "No allowlist — new senders go through DM pairing"
    fi
}

# --- tailscale ---------------------------------------------------------------

configure_tailscale() {
    cat <<'EOF'

  Tailscale — reach this machine from anywhere
  ────────────────────────────────────────────
  Prefer an OAUTH CLIENT SECRET over a one-off auth key:
      https://login.tailscale.com/admin/settings/oauth

  Auth keys expire (90 days maximum) and one-off keys work exactly once, so a
  stored auth key is a credential that rots in place — and it rots silently,
  to be discovered on the day you rebuild this machine and need it. An OAuth
  client secret does not expire and mints keys on demand.

  An OAuth client needs the `auth_keys` scope and a tag, and this machine must
  advertise that tag. Set tailscale_tags in ansible/group_vars/all.yml to match
  the tag on the client.

  A one-off auth key still works if you want to get moving:
      https://login.tailscale.com/admin/settings/keys

  This only puts the machine on your private tailnet. SSH is unchanged — same
  OpenSSH, same keys. Tailscale SSH is deliberately not enabled.

  Your laptop needs the Tailscale client too, signed in to the same account,
  or there's no tailnet to reach this machine over.

  Press Enter on its own to skip.

EOF
    local key
    read -rsp "  Tailscale OAuth client secret or auth key (Enter to skip): " key; echo
    if [[ -z "$key" ]]; then
        skip "Tailscale skipped — the machine won't join your tailnet"
        return "$RC_SKIPPED"
    fi
    # Both forms share the prefix; an OAuth client secret is tskey-client-...
    if [[ "$key" != tskey-* ]]; then
        err "That doesn't look like a Tailscale credential (expected tskey-...)."
        return "$RC_FAILED"
    fi

    if ! printf '%s' "$key" | vault_write tailscale; then
        unset key
        err "Could not write to the credential store."
        return "$RC_FAILED"
    fi
    unset key
    ok "Tailscale credential stored"

    # Worth saying out loud, because it is the one secret whose consumer this
    # repo will not re-apply to a machine that is already working. See the
    # tailscale role: a joined node takes the skip path every time.
    if tailscale status >/dev/null 2>&1; then
        say ""
        say "  This machine is already on the tailnet, so ./setup.sh will not"
        say "  re-join it. The stored credential is for the next rebuild."
    fi
}

# --- reporting ---------------------------------------------------------------

print_status() {
    local s
    say "Secrets:"
    for s in "${SECRETS[@]}"; do
        if is_configured "$s"; then
            printf '  \033[32m✓\033[0m %-10s stored\n' "$s"
        else
            printf '  \033[33m○\033[0m %-10s not stored\n' "$s"
        fi
    done
    say ""
    say "Stored in ${VAULT_DIR}. Run ./setup.sh to apply them."
}

# Quiet form used by setup.sh: prints only when something needs attention.
print_hint() {
    local missing
    # `paste -d` cycles through delimiter characters rather than treating the
    # string as one separator, so join on a comma and space it out afterwards.
    missing="$(missing_secrets | paste -sd, -)"
    [[ -n "$missing" ]] || return 0
    missing="${missing//,/, }"
    say ""
    say "==> Not yet configured: ${missing}"
    say "==> Run ./configure.sh to set up, then ./setup.sh to apply."
}

usage() {
    cat <<'EOF'
configure.sh — supply the secrets this repo cannot contain

USAGE
  ./configure.sh              configure whatever is still missing
  ./configure.sh NAME...      re-prompt for these specifically (rotation)
  ./configure.sh --list       show what is stored (never values)
  ./configure.sh --help

SECRETS
  github      GitHub PAT              -> gh's token store, for pushing over HTTPS
  telegram    Bot token + allowlist   -> ~/.hermes/.env, plus the gateway service
  tailscale   OAuth secret / auth key -> joins this machine to your tailnet

This script only STORES secrets, in /etc/dgx-spark/credstore. `./setup.sh` is
what applies them to the tools above. Rotating a secret therefore takes two
commands: store the new one here, then converge.
EOF
}

# --- main --------------------------------------------------------------------

main() {
    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
        --list)    print_status; exit 0 ;;
        --hint)    print_hint; exit 0 ;;
    esac

    local -a targets=()
    if [[ $# -gt 0 ]]; then
        local arg
        for arg in "$@"; do
            local found=false s
            for s in "${SECRETS[@]}"; do
                [[ "$arg" == "$s" ]] && found=true
            done
            if [[ "$found" != true ]]; then
                err "unknown secret: ${arg}"
                say ""
                usage
                exit 2
            fi
            targets+=("$arg")
        done
    else
        # No arguments: only what is missing.
        mapfile -t targets < <(missing_secrets)
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        say "Everything is stored."
        say ""
        print_status
        exit 0
    fi

    require_tty

    local failed=0 s rc
    local -a skipped=()
    for s in "${targets[@]}"; do
        rc="$RC_DONE"
        "configure_${s}" || rc=$?
        case "$rc" in
            "$RC_SKIPPED") skipped+=("$s") ;;
            "$RC_DONE")    ;;
            *)             failed=1 ;;
        esac
    done

    say ""
    print_status

    # Skipping is not a failure: exit 0 so callers and CI aren't misled by
    # someone simply not having set Telegram up yet.
    if [[ ${#skipped[@]} -gt 0 ]]; then
        local list
        list="$(printf '%s, ' "${skipped[@]}")"
        say ""
        say "Skipped: ${list%, } — run ./configure.sh ${skipped[0]} when ready."
    fi

    if (( failed == 0 && ${#skipped[@]} < ${#targets[@]} )); then
        say ""
        say "==> Run ./setup.sh to apply."
    fi
    exit "$failed"
}

main "$@"
