#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# fm-worker-machine-lib.sh - the single owner of the worker-machine registry:
# which other machines this home may place an individual ship or scout worker
# on (bin/fm-spawn.sh --machine), and how each one is reached.
#
# Declaration: config/worker-machines in the spawning home. One machine per
# line, whitespace-separated:
#   <machine-id> host=<ssh-alias> root=<remote-code-root> home=<worker-host-home> [prefer=<tag>[,<tag>...]]
# <machine-id> and <ssh-alias> use only A-Z a-z 0-9 . _ - and must not start
# with '-'. root= is the remote Firstmate clone that supplies tracked scripts
# (the same code root a remote secondmate route names), and home= is the
# separate, non-overlapping absolute path of the worker-host home on that
# machine: an ordinary FM_HOME directory that holds the project clones, Treehouse
# pools, and host-local task records of the workers placed there. It is not a
# Firstmate checkout and runs no firstmate agent. prefer= is optional intake
# guidance only - free-form tags such as android,jvm naming the work the captain
# prefers to place on that machine; nothing here acts on it automatically.
# Blank lines and lines starting with '#' are ignored. An unknown key, a missing
# required key, a duplicate machine id, or an unsafe value makes the whole
# declaration unreadable, so a caller refuses rather than guessing which machine
# was meant.
#
# No side effects on source.

FM_WORKER_MACHINE_ID=
FM_WORKER_MACHINE_HOST=
FM_WORKER_MACHINE_ROOT=
FM_WORKER_MACHINE_HOME=
FM_WORKER_MACHINE_PREFER=
FM_WORKER_MACHINE_ERROR=
FM_WORKER_MACHINE_IDS=

fm_worker_machine_safe_name() { # <value>
  case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

fm_worker_machine_safe_path() { # <value>
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *[[:space:][:cntrl:]]*) return 1 ;; esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  case "$1" in *'//'*) return 1 ;; esac
  return 0
}

# Parse one non-comment declaration line into FM_WORKER_MACHINE_*.
# Returns 1 with FM_WORKER_MACHINE_ERROR when the line is malformed.
fm_worker_machine_parse_line() { # <line>
  local line=$1 token key value id host='' root='' home='' prefer=''
  local -a tokens
  FM_WORKER_MACHINE_ERROR=
  read -r -a tokens <<<"$line"
  id=${tokens[0]:-}
  fm_worker_machine_safe_name "$id" || {
    FM_WORKER_MACHINE_ERROR="invalid machine id '$id'"
    return 1
  }
  for token in "${tokens[@]:1}"; do
    case "$token" in *=*) ;; *)
      FM_WORKER_MACHINE_ERROR="machine $id: '$token' is not a key=value field"
      return 1
      ;;
    esac
    key=${token%%=*}
    value=${token#*=}
    case "$key" in
      host) [ -z "$host" ] || { FM_WORKER_MACHINE_ERROR="machine $id: host= given twice"; return 1; }; host=$value ;;
      root) [ -z "$root" ] || { FM_WORKER_MACHINE_ERROR="machine $id: root= given twice"; return 1; }; root=$value ;;
      home) [ -z "$home" ] || { FM_WORKER_MACHINE_ERROR="machine $id: home= given twice"; return 1; }; home=$value ;;
      prefer) [ -z "$prefer" ] || { FM_WORKER_MACHINE_ERROR="machine $id: prefer= given twice"; return 1; }; prefer=$value ;;
      *) FM_WORKER_MACHINE_ERROR="machine $id: unknown key '$key'"; return 1 ;;
    esac
  done
  fm_worker_machine_safe_name "$host" || { FM_WORKER_MACHINE_ERROR="machine $id: host= must be a safe SSH alias"; return 1; }
  fm_worker_machine_safe_path "$root" || { FM_WORKER_MACHINE_ERROR="machine $id: root= must be a safe absolute path"; return 1; }
  fm_worker_machine_safe_path "$home" || { FM_WORKER_MACHINE_ERROR="machine $id: home= must be a safe absolute path"; return 1; }
  case "$root/" in "$home"/*) FM_WORKER_MACHINE_ERROR="machine $id: root= and home= must not overlap"; return 1 ;; esac
  case "$home/" in "$root"/*) FM_WORKER_MACHINE_ERROR="machine $id: root= and home= must not overlap"; return 1 ;; esac
  case "$prefer" in *[!A-Za-z0-9._,-]*) FM_WORKER_MACHINE_ERROR="machine $id: prefer= takes comma-separated tags"; return 1 ;; esac
  FM_WORKER_MACHINE_ID=$id
  FM_WORKER_MACHINE_HOST=$host
  FM_WORKER_MACHINE_ROOT=$root
  FM_WORKER_MACHINE_HOME=$home
  FM_WORKER_MACHINE_PREFER=$prefer
  return 0
}

# Resolve one machine from <config-dir>/worker-machines. The whole declaration
# is validated first, so a malformed line elsewhere still refuses.
# Returns 0 with FM_WORKER_MACHINE_* set, 1 with FM_WORKER_MACHINE_ERROR when
# the declaration is absent, unreadable, malformed, or names no such machine.
fm_worker_machine_resolve() { # <config-dir> <machine-id>
  local file="$1/worker-machines" want=$2 line found=0 seen='|'
  local host='' root='' home='' prefer=''
  FM_WORKER_MACHINE_ERROR=
  FM_WORKER_MACHINE_IDS=
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    FM_WORKER_MACHINE_ERROR="no worker machine is registered: $file does not exist (docs/configuration.md \"Worker machines\")"
    return 1
  fi
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    FM_WORKER_MACHINE_ERROR="$file is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    if ! fm_worker_machine_parse_line "$line"; then
      FM_WORKER_MACHINE_ERROR="$file: $FM_WORKER_MACHINE_ERROR"
      return 1
    fi
    case "$seen" in *"|$FM_WORKER_MACHINE_ID|"*)
      FM_WORKER_MACHINE_ERROR="$file: machine $FM_WORKER_MACHINE_ID is declared twice"
      return 1
      ;;
    esac
    seen="$seen$FM_WORKER_MACHINE_ID|"
    FM_WORKER_MACHINE_IDS="${FM_WORKER_MACHINE_IDS:+$FM_WORKER_MACHINE_IDS }$FM_WORKER_MACHINE_ID"
    if [ "$FM_WORKER_MACHINE_ID" = "$want" ]; then
      found=1
      host=$FM_WORKER_MACHINE_HOST
      root=$FM_WORKER_MACHINE_ROOT
      home=$FM_WORKER_MACHINE_HOME
      prefer=$FM_WORKER_MACHINE_PREFER
    fi
  done < "$file"
  if [ "$found" -ne 1 ]; then
    FM_WORKER_MACHINE_ERROR="machine '$want' is not registered in $file (registered: ${FM_WORKER_MACHINE_IDS:-none})"
    return 1
  fi
  FM_WORKER_MACHINE_ID=$want
  FM_WORKER_MACHINE_HOST=$host
  FM_WORKER_MACHINE_ROOT=$root
  FM_WORKER_MACHINE_HOME=$home
  FM_WORKER_MACHINE_PREFER=$prefer
  return 0
}
