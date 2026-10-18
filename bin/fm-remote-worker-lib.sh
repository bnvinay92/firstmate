#!/usr/bin/env bash
# shellcheck disable=SC2034 # route and payload results are output globals for sourcing callers.
# fm-remote-worker-lib.sh - the spawning home's view of a remotely placed ship
# or scout worker (docs/remote-workers.md owns the model).
#
# A placed worker's task record in the spawning home carries remote_host= like a
# remote secondmate's, so every reader that only knows "remote" keeps treating
# it as unknown-not-dead, and additionally remote_kind=worker plus
# remote_machine=<id> naming its entry in config/worker-machines
# (bin/fm-worker-machine-lib.sh). This file owns that recognition and the one
# routing decision every remote reader shares: which fm-on.sh route and which
# host-local control script a remote record is driven through.
#
# It also owns reading the spawning machine's current Claude login for a
# remote launch: config/claude-account when this home pins one
# (bin/fm-worker-account-lib.sh owns that pin), otherwise the account this
# process would launch Claude with (CLAUDE_CONFIG_DIR when set, else Claude's
# default). Credentials come from <root>/.credentials.json when present, else
# from the macOS login keychain entry Claude Code itself keeps ("Claude
# Code-credentials", suffixed with the first 8 hex digits of the SHA-256 of the
# config root when CLAUDE_CONFIG_DIR selects one). Carried are the claudeAiOauth
# object, the account's oauthAccount profile, the onboarding and theme state that
# keeps a fresh root from opening first-run screens, and that account's own
# skipDangerousModePermissionPrompt acknowledgement, so a worker launched in the
# bypass permission mode the captain already accepted here is not stopped at
# that prompt there. Nothing else from either file travels. Secrets travel on
# stdin, never in argv or a log.
#
# Requires bin/fm-backend.sh (fm_meta_get) to be sourced first.

FM_REMOTE_ROUTE=()
FM_REMOTE_WORKER_MACHINE=
FM_REMOTE_ACCOUNT_ERROR=

# 0 when <meta> records an individually placed remote worker; sets
# FM_REMOTE_WORKER_MACHINE.
fm_remote_worker_meta() { # <meta>
  FM_REMOTE_WORKER_MACHINE=
  [ -f "$1" ] || return 1
  [ "$(fm_meta_get "$1" remote_kind)" = worker ] || return 1
  FM_REMOTE_WORKER_MACHINE=$(fm_meta_get "$1" remote_machine)
  [ -n "$FM_REMOTE_WORKER_MACHINE" ]
}

# Set FM_REMOTE_ROUTE to the fm-on.sh arguments that reach <id>'s host-local
# control script, ending with that script's name: `--machine <m>
# fm-remote-worker-control.sh` for a placed worker, `<id>
# fm-remote-secondmate-control.sh` for a remote secondmate. Callers append the
# verb and its arguments.
fm_remote_route_for_meta() { # <meta> <id>
  if fm_remote_worker_meta "$1"; then
    FM_REMOTE_ROUTE=(--machine "$FM_REMOTE_WORKER_MACHINE" fm-remote-worker-control.sh)
  else
    FM_REMOTE_ROUTE=("$2" fm-remote-secondmate-control.sh)
  fi
}

# A short placement label for messages: "machine pc" or "host <alias>".
fm_remote_place_label() { # <meta>
  if fm_remote_worker_meta "$1"; then
    printf 'machine %s' "$FM_REMOTE_WORKER_MACHINE"
  else
    printf 'host %s' "$(fm_meta_get "$1" remote_host)"
  fi
}

fm_remote_account_sha256_8() { # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
  else
    printf '%s' "$1" | sha256sum | cut -c1-8
  fi
}

# Print the remote account payload for the claude runner on stdout.
# Returns 1 with FM_REMOTE_ACCOUNT_ERROR when no usable login is found.
fm_remote_worker_claude_payload() { # <config-dir>
  local config=$1 resolved root='' cfg creds='' service settings
  FM_REMOTE_ACCOUNT_ERROR=
  if ! resolved=$(fm_worker_account_resolve claude "$config"); then
    FM_REMOTE_ACCOUNT_ERROR="this home's config/claude-account pin does not resolve"
    return 1
  fi
  if [ -n "$resolved" ]; then
    root=$(printf '%s' "$resolved" | cut -f2)
  else
    root=${CLAUDE_CONFIG_DIR:-}
  fi
  if [ -n "$root" ]; then
    cfg="$root/.claude.json"
  else
    cfg="$HOME/.claude.json"
  fi
  if [ -n "$root" ] && [ -f "$root/.credentials.json" ]; then
    creds=$(cat "$root/.credentials.json" 2>/dev/null || true)
  elif [ -z "$root" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    creds=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null || true)
  fi
  if [ -z "$creds" ] && [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v security >/dev/null 2>&1; then
    service="Claude Code-credentials"
    [ -z "$root" ] || service="$service-$(fm_remote_account_sha256_8 "$root")"
    creds=$(security find-generic-password -a "${USER:-$(id -un)}" -s "$service" -w 2>/dev/null || true)
  fi
  if [ -z "$creds" ]; then
    FM_REMOTE_ACCOUNT_ERROR="no Claude login was found for ${root:-the default Claude account} on this machine; sign in with /login, then retry"
    return 1
  fi
  [ -f "$cfg" ] || {
    FM_REMOTE_ACCOUNT_ERROR="no Claude account profile at $cfg; sign in with /login, then retry"
    return 1
  }
  settings="${root:-$HOME/.claude}/settings.json"
  if ! { printf '%s\n' "$creds"
         jq -c '{oauthAccount, hasCompletedOnboarding, lastOnboardingVersion, theme}' "$cfg"
         jq -c '{skipDangerousModePermissionPrompt: (.skipDangerousModePermissionPrompt == true)}' "$settings" 2>/dev/null \
           || printf '{"skipDangerousModePermissionPrompt":false}\n'
       } \
    | jq -se 'if (.[0].claudeAiOauth | type) == "object" and (.[1].oauthAccount | type) == "object"
              then {claudeAiOauth: .[0].claudeAiOauth,
                    oauthAccount: .[1].oauthAccount,
                    config: (.[1] | del(.oauthAccount) | with_entries(select(.value != null))),
                    settings: .[2]}
              else error("incomplete") end' 2>/dev/null; then
    FM_REMOTE_ACCOUNT_ERROR="the Claude login for ${root:-the default Claude account} is not an OAuth subscription login; sign in with /login, then retry"
    return 1
  fi
}

# Install this machine's current Claude login on <machine> through its
# account verb. Returns the transport's status: 0 installed, 255 completion
# unknown, anything else refused; FM_REMOTE_ACCOUNT_ERROR names a refusal that
# happened here, and the remote leg's own reason goes to stderr.
fm_remote_worker_install_account() { # <bin-dir> <config-dir> <machine>
  local bin=$1 config=$2 machine=$3 payload rc=0
  FM_REMOTE_ACCOUNT_ERROR=
  payload=$(fm_remote_worker_claude_payload "$config") || return 1
  printf '%s\n' "$payload" | "$bin/fm-on.sh" --stdin --machine "$machine" \
    fm-remote-worker-control.sh account claude >/dev/null || rc=$?
  payload=
  return "$rc"
}
