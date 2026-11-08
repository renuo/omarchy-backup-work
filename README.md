# Work backup — Omarchy plugin

The **work** level of a Renuo laptop's backup: your own folders, `~/Work`, `~/Documents` and `~/Pictures`, encrypted with [restic](https://restic.net) to your Renuo Google Drive every hour.

## Three levels

Each level has its own place and its own pace. Renuo keeps the machine and the work on the office NAS and in Google Drive, each with a plugin; the config is your own dotfiles repository.

| Level | Plugin | Keeps | Where | When | Brings back |
|---|---|---|---|---|---|
| **Machine** | [renuo.backup-machine](https://github.com/renuo/omarchy-backup-machine) | The whole system: `/` and `/home` | Office NAS | Once a day at the office | This laptop as it was, after a broken disk or a bad update |
| **Config** | none: the dotfiles are yours | The dotfiles chezmoi manages: Omarchy tweaks, shell, editor, packages | Your dotfiles repository | When you commit and push | Your setup, on a new laptop |
| **Work** | [renuo.backup-work](https://github.com/renuo/omarchy-backup-work) (this one) | `~/Work`, `~/Documents`, `~/Pictures` | Your Renuo Google Drive | Every hour | Your files, on any laptop |

What lives in Google Drive already, like documents shared with colleagues, needs none of them.

The work level is for what exists only on this laptop: code that is not pushed yet, notes, screenshots, photos. It runs wherever the laptop has internet, so it is never more than an hour behind, and a new laptop gets the files back without the old one.

| Icon | Meaning |
|---|---|
| Backup | The last backup worked |
| Spinning arrows | A backup is running |
| Alert, urgent colour | The last backup failed, or none worked for three days |
| Dimmed | Not set up yet, or the hourly backups are off |

Hover for the time of the last backup. Click for the panel, right-click to refresh.

## Install

```bash
bin/install
```

This installs restic, copies `backup-work.service` and `backup-work.timer` to `~/.config/systemd/user/`, copies the plugin to `~/.config/omarchy/plugins/renuo.backup-work/` and puts it in the bar.

## Set up

The panel lists the steps and ticks off what is done:

1. **What and where.** *Edit* opens `~/.config/backup-work/backup.env` in your editor, started from [a commented template](templates/backup.env). `RESTIC_BACKUP_PATHS` lists the folders, `~/Work ~/Documents ~/Pictures` unless you change it; each must exist. The other lines are the repository, extra `restic backup` options and the snapshots to keep. They are restic's own environment variables, which systemd hands to the service as they are. *Excludes* opens `~/.config/backup-work/excludes.txt`.
2. **Google Drive login.** The repository `rclone:gdrive:Backups/work` goes through the `gdrive` remote of the [rclone plugin](https://github.com/renuo/omarchy-rclone), with its login. Renuo's Google Cloud OAuth client and your token are set up once, in the rclone panel, and serve both the mount and the backup. If the remote is missing, the button opens the rclone panel.
3. **Encryption password.** *Create* writes a random one to `~/.config/backup-work/password`, readable only by you. It encrypts every backup, and nothing can be restored without it, so *Copy* it into 1Password, **Employee** vault. The copy skips Omarchy's clipboard history. An existing password is never replaced.
4. **Repository.** *Set up* creates the repository. If it exists already, for example when this is a new laptop, it only checks that the password opens it.
5. **Hourly backups.** The switch at the top enables the timer, which runs every hour at a random minute and catches up after the laptop was off. *Change* opens a drop-in for the timer in your editor.

## Back up and restore

*Back up now* starts `backup-work.service`. It runs `restic backup`, then `restic forget` with your retention: a day of hours, two weeks of days, two months of weeks, a year of months. Once a day it also prunes, which frees the space on Google Drive. A failed run is tried again every 15 minutes, four runs at most, since a laptop often wakes without network. *Log* follows its journal, and *Snapshots* lists what is stored.

*Browse and restore* mounts the repository and opens its snapshots in Nautilus. Copy out what you need, then press Ctrl+C in the terminal.

*restic shell* opens a terminal with the settings loaded, for any other restic command. To restore a whole folder in place, without touching files that exist:

```bash
restic restore latest:$HOME/Work --target ~/Work --overwrite never
```

On a **new laptop**, restore the config level first: the dotfiles bring `backup.env` and the excludes along. Then set up the rclone `gdrive` remote, enter the password from 1Password into `~/.config/backup-work/password`, *Set up* the repository, and restore each folder as above.

Restoring to `/` fails, since restic would try to change the owner of /home.

## Files

| Path | What |
|---|---|
| `~/.config/backup-work/backup.env` | Settings, as `RESTIC_*` variables |
| `~/.config/backup-work/excludes.txt` | What to leave out |
| `~/.config/backup-work/password` | The encryption password; keep a copy in 1Password |
| `~/.config/systemd/user/backup-work.timer.d/schedule.conf` | Your schedule, if you changed it |
| `~/.local/state/backup-work/` | Outcome of the last run, for the panel |

The first two belong in your dotfiles, the password does not.

## Remove

```bash
systemctl --user disable --now backup-work.timer
omarchy plugin remove renuo.backup-work
rm ~/.config/systemd/user/backup-work.{service,timer}
```

The repository and `~/.config/backup-work` stay.

## Development

```bash
bin/setup   # checks the tools bin/check needs
bin/check   # validates the manifest and the units, runs the tests
bin/install # installs into the shell, which hot-reloads it
```
