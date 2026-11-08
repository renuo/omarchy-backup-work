# restic — Omarchy plugin

Encrypted backups with [restic](https://restic.net), set up and watched from the Omarchy bar.

| Icon | Meaning |
|---|---|
| Backup | The last scheduled backup worked |
| Spinning arrows | A backup is running |
| Alert, urgent colour | The last backup failed, or none worked for three days |
| Dimmed | Not set up yet, or the schedule is off |

Hover for the time of the last backup. Click for the panel, right-click to refresh.

## Install

```bash
bin/install
```

This installs restic, copies `restic-backup.service` and `restic-backup.timer` to `~/.config/systemd/user/`, copies the plugin to `~/.config/omarchy/plugins/renuo.restic/` and puts it in the bar.

## Set up

The panel lists the steps and ticks off what is done:

1. **What and where.** *Edit* opens `~/.config/restic/backup.env` in your editor, started from [a commented template](templates/backup.env): the repository, the folders to back up, extra `restic backup` options and the snapshots to keep. These are restic's own environment variables, which systemd hands to the service as they are. *Excludes* opens `~/.config/restic/excludes.txt`.
2. **Storage login.** A repository `rclone:<remote>:<path>` goes through a remote of the [rclone plugin](https://github.com/renuo/omarchy-rclone), with that remote's login. Google Drive's OAuth client and token are therefore set up once, in the rclone panel, and serve both the mount and the backup. If the remote is missing, the button opens the rclone panel.
3. **Password.** *Create* writes a random one to `~/.config/restic/password`, readable only by you. It encrypts every backup, and nothing can be restored without it, so *Copy* it into your password manager. The copy skips Omarchy's clipboard history. An existing password is never replaced.
4. **Repository.** *Set up* creates the repository. If it exists already, for example when this is a new laptop, it only checks that the password opens it.
5. **Schedule.** The switch at the top enables the timer, which runs daily and catches up after the laptop was off. *Change* opens a drop-in for the timer in your editor.

## Back up and restore

*Back up now* starts `restic-backup.service`, which runs `restic backup` and then `restic forget --prune` with your retention. A failed run is tried again every 15 minutes, four runs at most, since a laptop often wakes without network. *Log* follows its journal, and *Snapshots* lists what is stored.

*Browse and restore* mounts the repository and opens its snapshots in Nautilus. Copy out what you need, then press Ctrl+C in the terminal.

*restic shell* opens a terminal with the settings loaded, for any other restic command. To restore a whole folder in place, without touching files that exist:

```bash
restic restore latest:$HOME/Work --target ~/Work --overwrite never
```

Restoring to `/` fails, since restic would try to change the owner of /home.

## Files

| Path | What |
|---|---|
| `~/.config/restic/backup.env` | Settings, as `RESTIC_*` variables |
| `~/.config/restic/excludes.txt` | What to leave out |
| `~/.config/restic/password` | The repository password; keep a copy elsewhere |
| `~/.config/systemd/user/restic-backup.timer.d/schedule.conf` | Your schedule, if you changed it |
| `~/.local/state/restic-backup/` | Outcome of the last run, for the panel |

The first three belong in your dotfiles, except the password.

## Remove

```bash
systemctl --user disable --now restic-backup.timer
omarchy plugin remove renuo.restic
rm ~/.config/systemd/user/restic-backup.{service,timer}
```

The repository and `~/.config/restic` stay.

## Development

```bash
bin/setup   # checks the tools bin/check needs
bin/check   # validates the manifest and the units, runs the tests
bin/install # installs into the shell, which hot-reloads it
```
