#!/usr/bin/env bash
# configure.sh — supply the secrets that this repo deliberately cannot contain.
#
#   ./configure.sh              configure whatever is still missing
#   ./configure.sh telegram     re-prompt just this one (rotation)
#   ./configure.sh --list       show what is configured — never values
#   ./configure.sh --help
#
# This script stores nothing. Each secret is written straight through to the
# tool that owns it — gh's own token store, and Hermes' ~/.hermes/.env (0600).
# That means no secret lives in two places, there is no copy to drift out of
# sync, and there is no third store for this repo to secure. "Is it configured?"
# is answered by asking the real consumer, not by reading a manifest of our own.
#
# Needs no sudo. Safe to re-run.
set -euo pipefail

# The Hermes command lives here; a non-login shell won't have it on PATH.
export PATH="$HOME/.local/bin:$PATH"

SECRETS=(github telegram)

# Hermes' own validation regex, from hermes_cli/setup.py. A token that fails
# this is accepted by the .env writer and then silently disables the Telegram
# adapter at gateway start — an error in the log and nothing else.
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

# --- status probes -----------------------------------------------------------
# Deliberately ask the consuming tool rather than tracking state ourselves.

hermes_env_path() { hermes config env-path 2>/dev/null; }

is_configured_github() { gh auth status >/dev/null 2>&1; }

is_configured_telegram() {
    local env_path
    env_path="$(hermes_env_path)" || return 1
    [[ -n "$env_path" && -f "$env_path" ]] || return 1
    # Accept both `KEY=` and `export KEY=` forms, and require a non-empty value.
    grep -qE '^(export[[:space:]]+)?TELEGRAM_BOT_TOKEN=.' "$env_path"
}

is_configured() { "is_configured_$1"; }

missing_secrets() {
    local s
    for s in "${SECRETS[@]}"; do
        is_configured "$s" || printf '%s\n' "$s"
    done
}

# --- .env editing ------------------------------------------------------------
# Replace a key in Hermes' .env in place, preserving mode 0600 and every other
# key. The temp file is created in the same directory so `mv` is an atomic
# rename rather than a copy. An empty value removes the key entirely, so
# clearing an allowlist actually clears it.
set_env_key() {
    local key="$1" value="$2" env_path tmp
    env_path="$(hermes_env_path)"
    if [[ -z "$env_path" ]]; then
        err "could not determine Hermes .env path"
        return 1
    fi
    if [[ ! -f "$env_path" ]]; then
        : > "$env_path"
        chmod 600 "$env_path"
    fi
    # Checked step by step: callers test this function's return value, which
    # disables errexit inside it. A half-written .env would be worse than a
    # clean failure, so bail (removing the temp file) on any problem.
    tmp="$(mktemp "${env_path}.XXXXXX")" || return 1
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    # grep exits 1 when it matches nothing, which is normal for a first write.
    grep -vE "^(export[[:space:]]+)?${key}=" "$env_path" > "$tmp" || true
    if [[ -n "$value" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv "$tmp" "$env_path" || { rm -f "$tmp"; return 1; }
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    err "$1 is not installed — run ./setup.sh first"
    return 1
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
    require_cmd gh || return 1
    cat <<'EOF'

  GitHub personal access token
  ────────────────────────────
  Create one at https://github.com/settings/tokens

  Use a CLASSIC token with BOTH scopes:
      repo        push over HTTPS
      read:org    required by `gh auth login` itself; it refuses without it

  Fine-grained tokens don't advertise scopes the way gh checks for them, so
  they are likely to be rejected here. Classic is the reliable choice.

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
    local rc=0
    printf '%s' "$token" | gh auth login --with-token || rc=$?
    unset token

    # Trust the outcome, not the exit status: re-run the same probe that
    # `--list` uses, so "configured" always means the consumer agrees.
    if (( rc != 0 )) || ! is_configured_github; then
        err "GitHub authentication failed — nothing was stored."
        err "A classic token needs BOTH 'repo' and 'read:org' scopes."
        err "Check the scopes at https://github.com/settings/tokens and retry:"
        err "    ./configure.sh github"
        return "$RC_FAILED"
    fi
    ok "GitHub authenticated (credential helper already wired by chezmoi)"
}

# --- telegram ----------------------------------------------------------------

configure_telegram() {
    require_cmd hermes || return 1
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

    # As in configure_github: errexit is disabled inside this function, so
    # every fallible step is checked by hand.
    # Token via `hermes config set` — a key ending in _TOKEN is routed to .env.
    local rc=0
    hermes config set TELEGRAM_BOT_TOKEN "$token" >/dev/null || rc=$?
    unset token
    if (( rc != 0 )) || ! is_configured_telegram; then
        err "Storing the bot token failed — nothing was written."
        err "Retry with: ./configure.sh telegram"
        return "$RC_FAILED"
    fi

    # The allowlist must NOT go through `hermes config set TELEGRAM_ALLOWED_USERS`:
    # that key has no dot, isn't in the API-key list, and doesn't end in _TOKEN or
    # _SECRET, so it lands in config.yaml as a top-level key that nothing reads.
    # Writing .env directly is the canonical route — env wins over YAML in every
    # bridge, and it keeps the token and its allowlist in one file.
    if ! set_env_key TELEGRAM_ALLOWED_USERS "$ids"; then
        err "Could not write the allowlist to Hermes' .env."
        err "The bot token IS stored; fix the file and retry."
        return "$RC_FAILED"
    fi

    if [[ -n "$ids" ]]; then
        ok "Allowlist set (${ids})"
    else
        ok "No allowlist — new senders go through DM pairing"
    fi

    say ""
    say "  Installing the gateway service..."
    if ! hermes gateway install --start-now --start-on-login; then
        err "Gateway install failed."
        err "Your token and allowlist ARE saved — don't re-enter them. Retry with:"
        err "    hermes gateway install --start-now --start-on-login"
        return "$RC_FAILED"
    fi
    ok "Telegram gateway installed and started"
}

# --- output ------------------------------------------------------------------

print_status() {
    local s
    say "Secrets:"
    for s in "${SECRETS[@]}"; do
        if is_configured "$s"; then
            printf '  \033[32m✓\033[0m %-10s configured\n' "$s"
        else
            printf '  \033[33m○\033[0m %-10s not configured\n' "$s"
        fi
    done
    say ""
    say "Nothing is stored by this repo — each secret lives in the tool that uses it."
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
    say "==> Run ./configure.sh to set up."
}

usage() {
    cat <<'EOF'
configure.sh — supply the secrets this repo cannot contain

USAGE
  ./configure.sh              configure whatever is still missing
  ./configure.sh NAME...      re-prompt for these specifically (rotation)
  ./configure.sh --list       show what is configured (never values)
  ./configure.sh --help

SECRETS
  github      GitHub PAT  -> gh's token store, for pushing over HTTPS
  telegram    Bot token   -> ~/.hermes/.env, plus the gateway service

Nothing is stored by this repo. Each secret is written straight through to the
tool that owns it, so there is never a second copy to drift or to secure.
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
        say "Everything is configured."
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
    exit "$failed"
}

main "$@"
