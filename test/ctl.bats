setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../ctl.sh"
  PATH="$BATS_TEST_DIRNAME/fakebin:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state"
  export FAKE_ARGS="$BATS_TEST_TMPDIR/args"
  export FAKE_SYSTEMD="$BATS_TEST_TMPDIR/systemd"
  export FAKE_CLIPBOARD="$BATS_TEST_TMPDIR/clipboard"
  CONFIG="$XDG_CONFIG_HOME/backup-work/backup.env"
  PASSWORD="$XDG_CONFIG_HOME/backup-work/password"
  STATE="$XDG_STATE_HOME/backup-work"
  mkdir -p "$HOME" "$FAKE_SYSTEMD"
  : >"$FAKE_ARGS"
}

settings() {
  mkdir -p "${CONFIG%/*}"
  printf '%s\n' "$@" >"$CONFIG"
}

state_field() {
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  jq -c ".$1" <<<"$output"
}

@test "state of a fresh machine is all empty" {
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$(jq -c 'del(.installed)' <<<"$output")" = '{"config":false,"excludes":false,"password":false,"repository":"","paths":"","forget":"","remote":"","remoteReady":false,"initialized":false,"timerEnabled":false,"running":false,"nextRun":0,"result":"","lastRun":0,"lastSuccess":0}' ]
}

@test "state reads the settings the way systemd does" {
  settings '# RESTIC_REPOSITORY=commented' 'RESTIC_REPOSITORY="rclone:gdrive:Backups/work"' 'RESTIC_BACKUP_PATHS=/home/me/Work /home/me/Notes' 'RESTIC_FORGET_ARGS=--keep-daily 7'
  run bash "$SCRIPT" state
  [ "$(jq -c '[.config, .repository, .paths, .forget, .remote]' <<<"$output")" = '[true,"rclone:gdrive:Backups/work","/home/me/Work /home/me/Notes","--keep-daily 7","gdrive"]' ]
}

@test "state takes the last of repeated settings" {
  settings 'RESTIC_REPOSITORY=/old' 'RESTIC_REPOSITORY=/new'
  [ "$(state_field repository)" = '"/new"' ]
}

@test "state knows whether rclone has the remote" {
  settings 'RESTIC_REPOSITORY=rclone:gdrive:Backups/work'
  [ "$(state_field remoteReady)" = false ]
  FAKE_RCLONE_REMOTES="onedrive gdrive" run bash "$SCRIPT" state
  [ "$(jq -c .remoteReady <<<"$output")" = true ]
}

@test "state has no remote for a repository rclone does not reach" {
  settings 'RESTIC_REPOSITORY=/mnt/usb/restic'
  [ "$(state_field remote)" = '""' ]
}

@test "state counts the repository initialized only while it is the one set up" {
  settings 'RESTIC_REPOSITORY=rclone:gdrive:Backups/work'
  mkdir -p "$STATE"
  printf %s 'rclone:gdrive:Backups/work' >"$STATE/repository"
  [ "$(state_field initialized)" = true ]
  settings 'RESTIC_REPOSITORY=rclone:gdrive:Backups/other'
  [ "$(state_field initialized)" = false ]
}

@test "state reports the last run and the last success separately" {
  mkdir -p "$STATE"
  echo "exit-code 1762600000" >"$STATE/last-run"
  echo "success 1762500000" >"$STATE/last-success"
  run bash "$SCRIPT" state
  [ "$(jq -c '[.result, .lastRun, .lastSuccess]' <<<"$output")" = '["exit-code",1762600000,1762500000]' ]
}

@test "state reads a garbled run file as no run" {
  mkdir -p "$STATE"
  echo "success soon" >"$STATE/last-run"
  [ "$(state_field lastRun)" = 0 ]
}

@test "state asks systemd about the timer and the running backup" {
  echo enabled >"$FAKE_SYSTEMD/backup-work.timer.enabled"
  echo activating >"$FAKE_SYSTEMD/backup-work.service.active"
  echo '[{"next":1762650000123456,"unit":"backup-work.timer"}]' >"$FAKE_SYSTEMD/timers.json"
  run bash "$SCRIPT" state
  [ "$(jq -c '[.timerEnabled, .running, .nextRun]' <<<"$output")" = '[true,true,1762650000]' ]
}

@test "state reads a timer without a next run as 0" {
  echo '[{"next":null}]' >"$FAKE_SYSTEMD/timers.json"
  [ "$(state_field nextRun)" = 0 ]
}

@test "edit config starts from the template with this home filled in" {
  run bash "$SCRIPT" edit config
  [ "$status" -eq 0 ]
  grep -qx "RESTIC_BACKUP_PATHS=$HOME/Work $HOME/Documents $HOME/Pictures" "$CONFIG"
  grep -qx 'RESTIC_REPOSITORY=rclone:gdrive:Backups/work' "$CONFIG"
  grep -qx "omarchy-launch-config-editor $CONFIG" "$FAKE_ARGS"
}

@test "edit config keeps settings that exist" {
  settings 'RESTIC_REPOSITORY=/mine'
  run bash "$SCRIPT" edit config
  [ "$(cat "$CONFIG")" = 'RESTIC_REPOSITORY=/mine' ]
}

@test "edit excludes starts from the template" {
  run bash "$SCRIPT" edit excludes
  cmp "$XDG_CONFIG_HOME/backup-work/excludes.txt" "$BATS_TEST_DIRNAME/../templates/excludes.txt"
}

@test "password creates a long random one only the owner can read" {
  run bash "$SCRIPT" password
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(stat -c %a "$PASSWORD")" = 600 ]
  [ "$(wc -c <"$PASSWORD")" -ge 40 ]
}

@test "password never replaces an existing one" {
  mkdir -p "${PASSWORD%/*}"
  echo old >"$PASSWORD"
  run bash "$SCRIPT" password
  [ "$(cat "$PASSWORD")" = old ]
  [[ $output == *"lock you out"* ]]
}

@test "copy-password hands it to the clipboard as sensitive" {
  mkdir -p "${PASSWORD%/*}"
  echo s3cret >"$PASSWORD"
  run bash "$SCRIPT" copy-password
  [ "$status" -eq 0 ]
  grep -qx 'wl-copy --sensitive' "$FAKE_ARGS"
  [ "$(cat "$FAKE_CLIPBOARD")" = s3cret ]
}

@test "copy-password says so when there is none" {
  run bash "$SCRIPT" copy-password
  [ "$output" = "No password yet." ]
}

@test "timer on enables and starts the timer quietly" {
  run bash "$SCRIPT" timer on
  [ "$output" = "" ]
  grep -qx 'systemctl --user enable --now backup-work.timer' "$FAKE_ARGS"
}

@test "timer off disables and stops it" {
  run bash "$SCRIPT" timer off
  grep -qx 'systemctl --user disable --now backup-work.timer' "$FAKE_ARGS"
}

@test "timer prints systemd's complaint when it fails" {
  FAKE_SYSTEMCTL_FAIL="Unit backup-work.timer does not exist." run bash "$SCRIPT" timer on
  [ "$output" = "Unit backup-work.timer does not exist." ]
}

@test "backup starts the service without waiting for it" {
  run bash "$SCRIPT" backup
  [ "$output" = "" ]
  grep -qx 'systemctl --user start --no-block backup-work.service' "$FAKE_ARGS"
}

@test "stop stops a running backup" {
  run bash "$SCRIPT" stop
  grep -qx 'systemctl --user stop backup-work.service' "$FAKE_ARGS"
}

@test "init creates a repository that does not exist and remembers it" {
  settings 'RESTIC_REPOSITORY=rclone:gdrive:Backups/work' 'RESTIC_FORGET_ARGS=--keep-daily 7'
  bash "$SCRIPT" password
  FAKE_RCLONE_REMOTES=gdrive run bash "$SCRIPT" init
  [ "$status" -eq 0 ]
  grep -qx "restic init | rclone:gdrive:Backups/work | $PASSWORD | --keep-daily 7" "$FAKE_ARGS"
  [ "$(cat "$STATE/repository")" = 'rclone:gdrive:Backups/work' ]
}

@test "init connects to a repository that exists already" {
  settings 'RESTIC_REPOSITORY=/mnt/usb/restic'
  bash "$SCRIPT" password
  FAKE_RESTIC_EXISTS=1 run bash "$SCRIPT" init
  [ "$status" -eq 0 ]
  [[ $output == *"exists already"* ]]
  ! grep -q 'restic init' "$FAKE_ARGS"
  [ "$(cat "$STATE/repository")" = /mnt/usb/restic ]
}

@test "init wants the password first" {
  settings 'RESTIC_REPOSITORY=/mnt/usb/restic'
  run bash "$SCRIPT" init
  [ "$status" -eq 1 ]
  ! grep -q '^restic' "$FAKE_ARGS"
}

@test "init sends you to the rclone plugin when the remote is missing" {
  settings 'RESTIC_REPOSITORY=rclone:gdrive:Backups/work'
  bash "$SCRIPT" password
  run bash "$SCRIPT" init
  [ "$status" -eq 1 ]
  [[ $output == *"rclone panel"* ]]
  [ ! -f "$STATE/repository" ]
}

@test "init needs settings" {
  run bash "$SCRIPT" init
  [ "$status" -eq 1 ]
  [[ $output == "No settings yet"* ]]
}

@test "schedule edits a drop-in from the template and restarts an enabled timer" {
  echo enabled >"$FAKE_SYSTEMD/backup-work.timer.enabled"
  run bash "$SCRIPT" schedule
  [ "$status" -eq 0 ]
  local file="$XDG_CONFIG_HOME/systemd/user/backup-work.timer.d/schedule.conf"
  cmp "$file" "$BATS_TEST_DIRNAME/../templates/schedule.conf"
  grep -qx "omarchy-launch-editor --inline $file" "$FAKE_ARGS"
  grep -qx 'systemctl --user daemon-reload' "$FAKE_ARGS"
  grep -qx 'systemctl --user restart backup-work.timer' "$FAKE_ARGS"
}

@test "schedule leaves a disabled timer off" {
  run bash "$SCRIPT" schedule
  [ "$status" -eq 0 ]
  ! grep -q restart "$FAKE_ARGS"
}

@test "snapshots runs restic with the backup's settings" {
  settings 'RESTIC_REPOSITORY=/mnt/usb/restic'
  run bash "$SCRIPT" snapshots
  grep -qx "restic snapshots | /mnt/usb/restic | $PASSWORD | " "$FAKE_ARGS"
}

@test "shell opens your shell with the backup's settings" {
  settings 'RESTIC_REPOSITORY=/mnt/usb/restic' 'RESTIC_FORGET_ARGS=--keep-daily 7 --keep-weekly 8'
  SHELL=env run bash "$SCRIPT" shell
  [ "$status" -eq 0 ]
  grep -qx 'RESTIC_REPOSITORY=/mnt/usb/restic' <<<"$output"
  grep -qx 'RESTIC_FORGET_ARGS=--keep-daily 7 --keep-weekly 8' <<<"$output"
  grep -qx "RESTIC_PASSWORD_FILE=$PASSWORD" <<<"$output"
}

@test "an unknown command prints usage" {
  run bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  [[ $output == usage:* ]]
}
