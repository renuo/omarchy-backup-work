setup() {
  UNIT="$BATS_TEST_DIRNAME/../systemd/backup-work.service"
  export STATE_DIRECTORY="$BATS_TEST_TMPDIR/state"
  export RESTIC_REPOSITORY="rclone:gdrive:Backups/work"
  mkdir -p "$STATE_DIRECTORY"
}

# Runs ExecStopPost's script after undoing systemd's escaping: $$ is $, %% is %.
stop_post() {
  local script
  script=$(sed -n "s/^ExecStopPost=\/bin\/sh -c '\(.*\)'$/\1/p" "$UNIT" | sed 's/\$\$/$/g; s/%%/%/g')
  [ -n "$script" ]
  SERVICE_RESULT=$1 sh -c "$script"
}

@test "a successful run is kept as the last run and the last success" {
  stop_post success
  read -r result seconds <"$STATE_DIRECTORY/last-run"
  [ "$result" = success ]
  (( seconds > $(date +%s) - 60 ))
  cmp "$STATE_DIRECTORY/last-run" "$STATE_DIRECTORY/last-success"
}

@test "a successful run remembers the repository as initialized" {
  stop_post success
  [ "$(cat "$STATE_DIRECTORY/repository")" = "rclone:gdrive:Backups/work" ]
}

@test "a failed run leaves the last success alone" {
  echo "success 1" >"$STATE_DIRECTORY/last-success"
  stop_post exit-code
  [ "$(cut -d' ' -f1 "$STATE_DIRECTORY/last-run")" = exit-code ]
  [ "$(cat "$STATE_DIRECTORY/last-success")" = "success 1" ]
  [ ! -f "$STATE_DIRECTORY/repository" ]
}

