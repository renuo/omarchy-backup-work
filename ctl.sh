#!/bin/bash

# What the panel asks of restic, rclone and systemd. `state` prints JSON; the
# other quick commands print nothing unless they fail, and the panel shows
# that text as the error. `init`, `schedule`, `log`, `snapshots` and `browse`
# talk to a person and run in a terminal the panel opens.

set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/backup-work"
CONFIG="$CONFIG_DIR/backup.env"
EXCLUDES="$CONFIG_DIR/excludes.txt"
PASSWORD="$CONFIG_DIR/password"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/backup-work"
SERVICE=backup-work.service
TIMER=backup-work.timer

usage() {
  echo "usage: ctl.sh state | edit config|excludes | password | copy-password | timer on|off | backup | stop | init | schedule | log | snapshots | browse | shell" >&2
  exit 2
}

# The file is systemd's EnvironmentFile, not shell: sourcing it would run
# "--keep-daily 7" as a command. Only KEY=value lines count, quotes optional.
setting() {
  local line value=""
  [[ -f $CONFIG ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*$1=(.*)$ ]] || continue
    value=${BASH_REMATCH[1]}
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
  done <"$CONFIG"
  printf '%s' "$value"
}

# The same environment backup-work.service gets, for restic run by hand.
load_settings() {
  local line key
  [[ -f $CONFIG ]] || {
    echo "No settings yet: $CONFIG"
    exit 1
  }
  export RESTIC_PASSWORD_FILE="$PASSWORD"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    key=${BASH_REMATCH[1]}
    export "$key=$(setting "$key")"
  done <"$CONFIG"
}

remote_of() {
  [[ $1 =~ ^rclone:([^:]+): ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

has_remote() {
  [[ -n $1 ]] && rclone listremotes 2>/dev/null | grep -qxF "$1:"
}

timestamp() {
  [[ -f $1 ]] && read -r _ seconds <"$1" && [[ $seconds =~ ^[0-9]+$ ]] && printf '%s' "$seconds" && return
  printf 0
}

state() {
  local repository remote result="" enabled active next
  repository=$(setting RESTIC_REPOSITORY)
  remote=$(remote_of "$repository")
  [[ -f $STATE_DIR/last-run ]] && read -r result _ <"$STATE_DIR/last-run"
  enabled=$(systemctl --user is-enabled "$TIMER" 2>/dev/null) || true
  active=$(systemctl --user is-active "$SERVICE" 2>/dev/null) || true
  next=$(systemctl --user list-timers --all --output=json "$TIMER" 2>/dev/null | jq -r '.[0].next // 0' 2>/dev/null) || true
  [[ $next =~ ^[0-9]+$ ]] || next=0
  jq -cn \
    --argjson installed "$(command -v restic >/dev/null && echo true || echo false)" \
    --argjson config "$([[ -f $CONFIG ]] && echo true || echo false)" \
    --argjson excludes "$([[ -f $EXCLUDES ]] && echo true || echo false)" \
    --argjson password "$([[ -s $PASSWORD ]] && echo true || echo false)" \
    --arg repository "$repository" \
    --arg paths "$(setting RESTIC_BACKUP_PATHS)" \
    --arg forget "$(setting RESTIC_FORGET_ARGS)" \
    --arg remote "$remote" \
    --argjson remoteReady "$(has_remote "$remote" && echo true || echo false)" \
    --argjson initialized "$([[ -n $repository && -f $STATE_DIR/repository && $(cat "$STATE_DIR/repository") == "$repository" ]] && echo true || echo false)" \
    --argjson timerEnabled "$([[ $enabled == enabled ]] && echo true || echo false)" \
    --argjson running "$([[ $active == activating || $active == active || $active == deactivating ]] && echo true || echo false)" \
    --argjson nextRun "$((next / 1000000))" \
    --arg result "$result" \
    --argjson lastRun "$(timestamp "$STATE_DIR/last-run")" \
    --argjson lastSuccess "$(timestamp "$STATE_DIR/last-success")" \
    '$ARGS.named'
}

from_template() {
  local name=$1 target=$2
  [[ -f $target ]] && return
  mkdir -p "${target%/*}"
  sed "s|@HOME@|$HOME|g" "$TEMPLATE_DIR/$name" >"$target"
}

edit() {
  case ${1:-} in
  config) from_template backup.env "$CONFIG" && omarchy-launch-config-editor "$CONFIG" ;;
  excludes) from_template excludes.txt "$EXCLUDES" && omarchy-launch-config-editor "$EXCLUDES" ;;
  *) usage ;;
  esac
}

# Never replaced: a new password would lock you out of every existing backup.
password() {
  if [[ -s $PASSWORD ]]; then
    echo "There is a password already; replacing it would lock you out of the backups made with it."
    return
  fi
  mkdir -p "$CONFIG_DIR"
  (umask 077 && head -c 32 /dev/urandom | base64 >"$PASSWORD")
}

# --sensitive keeps it out of Omarchy's clipboard history.
copy_password() {
  [[ -s $PASSWORD ]] || {
    echo "No password yet."
    return
  }
  wl-copy --sensitive <"$PASSWORD"
}

timer() {
  local out
  case ${1:-} in
  on) out=$(systemctl --user enable --now "$TIMER" 2>&1) || echo "$out" ;;
  off) out=$(systemctl --user disable --now "$TIMER" 2>&1) || echo "$out" ;;
  *) usage ;;
  esac
}

backup() {
  local out
  out=$(systemctl --user start --no-block "$SERVICE" 2>&1) || echo "$out"
}

stop() {
  local out
  out=$(systemctl --user stop "$SERVICE" 2>&1) || echo "$out"
}

# Connects to a repository that exists already, as on a new laptop, and
# creates one otherwise.
init() {
  local remote
  load_settings
  [[ -s $PASSWORD ]] || {
    echo "Create the password first."
    exit 1
  }
  remote=$(remote_of "$RESTIC_REPOSITORY")
  if [[ -n $remote ]] && ! has_remote "$remote"; then
    echo "rclone has no remote called '$remote'. Set it up in the rclone panel first."
    exit 1
  fi
  echo "Repository: $RESTIC_REPOSITORY"
  echo
  if restic cat config >/dev/null 2>&1; then
    echo "It exists already, and the password opens it."
  else
    restic init
  fi
  mkdir -p "$STATE_DIR"
  printf '%s' "$RESTIC_REPOSITORY" >"$STATE_DIR/repository"
}

schedule() {
  local file="$UNIT_DIR/$TIMER.d/schedule.conf"
  from_template schedule.conf "$file"
  omarchy-launch-editor --inline "$file"
  systemctl --user daemon-reload
  if systemctl --user -q is-enabled "$TIMER"; then
    systemctl --user restart "$TIMER"
    systemctl --user list-timers "$TIMER"
  fi
}

browse() {
  local dir="${XDG_RUNTIME_DIR:?}/backup-work-browse"
  load_settings
  mkdir -p "$dir"
  echo "Backups are at $dir/snapshots while this runs. Copy out what you need, then press Ctrl+C."
  echo
  (sleep 5 && uwsm-app -- nautilus "$dir/snapshots" >/dev/null 2>&1) &
  restic mount "$dir"
}

case ${1:-} in
state) state ;;
edit) edit "${2:-}" ;;
password) password ;;
copy-password) copy_password ;;
timer) timer "${2:-}" ;;
backup) backup ;;
stop) stop ;;
init) init ;;
schedule) schedule ;;
log) journalctl --user --unit "$SERVICE" --lines 200 --follow ;;
snapshots) load_settings && restic snapshots ;;
browse) browse ;;
shell)
  load_settings
  echo "restic is set up for $RESTIC_REPOSITORY. Try: restic snapshots"
  exec "${SHELL:-bash}"
  ;;
*) usage ;;
esac
