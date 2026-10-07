# rar2fs-dock

Browse the contents of RAR archives on Windows as if they were already extracted - no
unpacking, no extra disk space.

[rar2fs](https://github.com/hasse69/rar2fs) runs inside a Docker container and reads
your local folders and network shares. The extracted view is served to Windows and
mounted as a normal drive letter (e.g. `Y:`).

```
 D:\Downloads ─┐                    ┌──────── Docker ────────┐
 \nas\media  ─┼─► /sources/<name> ─► rar2fs ─► WebDAV :8765 ─┼─► rclone + WinFsp ─► Y:\
               │                    └────────────────────────┘
```

## What you need

| Tool | Install |
|---|---|
| Docker Desktop | <https://www.docker.com/products/docker-desktop/> |
| WinFsp (Windows FUSE driver) | `winget install WinFsp.WinFsp` |
| rclone | `winget install Rclone.Rclone` |

After installing rclone, open a **new** PowerShell window so it's on your PATH.

## Setup

### 1. Choose your source folders

Edit `docker-compose.yml`. Every volume mounted at `/sources/<name>` shows up as
`Y:\<name>`.

**Local folder or drive:**

```yaml
volumes:
  - "D:/Downloads:/sources/downloads:ro"
  - "E:/tv:/sources/tv:ro"
```

Use forward slashes in Windows paths. Docker Desktop must be allowed to access that
drive (Settings → Resources → File sharing, if it asks).

**Several folders as subfolders of one:** mount them one level deeper:

```yaml
volumes:
  - "I:/x264:/sources/films/films-1:ro"        # -> Y:\films\films-1
  - "F:/Movies 2:/sources/films/films-2:ro"    # -> Y:\films\films-2
```

**Several folders merged into one:** give them the same name followed by `@` and any
label. Their contents appear together in one folder:

```yaml
volumes:
  - "E:/tv:/sources/tv@e:ro"
  - "F:/tv:/sources/tv@f:ro"     # E:\tv + F:\tv -> Y:\tv
```

This works with network shares too (`- nas:/sources/tv@nas:ro`). If the same file or
folder exists in more than one source, the folders' contents are combined, and for a
file, the first source alphabetically by label wins.

**Network share (SMB/CIFS):** add one entry per NAS folder at the bottom of
`docker-compose.yml` (at the left margin, not inside `services:`), then mount it like
any other source - it can go anywhere, including inside a subfolder group:

```yaml
    volumes:
      - nas-tv:/sources/tv/tv-3:ro          # -> Y:\tv\tv-3

volumes:
  nas-tv:
    driver_opts:
      <<: *nas-options
      device: "//nas.example.com/share/TV"  # point straight at the folder you want
```

`*nas-options` (defined just above `volumes:`) holds the shared settings; the login
comes from `NAS_USER` / `NAS_PASS` in `.env`. After changing a share's `device`, run
`docker compose down` then `docker compose up -d` - Docker keeps a volume's old
settings until it's recreated.

### 2. Set a password

Copy `.env.example` to `.env` and change `WEBDAV_PASS`. The container won't start
without it. `.env` is gitignored, so the password never gets committed.

### 3. Start the container

From this folder:

```powershell
docker compose up -d --build
```

Check that it's working by opening <http://localhost:8765> in a browser and logging in
with the user and password from `.env` - you should see a folder for each source.

### 4. Mount the drive

**Try it once (stays mounted while the window is open):**

```powershell
.\windows\mount.ps1
```

**Mount automatically at every login (recommended):**

```powershell
.\windows\install-autostart.ps1
```

Both accept `-Drive X:` to use a different letter. `Y:` is the default. They log in
with the user and password from `.env` automatically.

If PowerShell refuses to run the scripts, run this first:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

That's it - open `Y:\` in Explorer.

## Using it from other machines

The server is reachable from your network at `http://<this-PC's-IP>:8765`, using the
login in `.env`. To use it, allow port 8765 through Windows Firewall (admin
PowerShell, once):

```powershell
New-NetFirewallRule -DisplayName "rar2fs-dock WebDAV" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow -Profile Private
```

- **Plex (or anything else) on Linux:** see [Plex on Linux](#plex-on-linux) below.
- **Another Windows PC:** copy the `windows` folder over, install WinFsp and rclone,
  and run `.\windows\mount.ps1 -Url http://<this-PC's-IP>:8765 -User <user> -Pass <password>`.
- **Mac:** Finder → Go → Connect to Server → `http://<this-PC's-IP>:8765`.
- **Media players** (Kodi, VLC, Infuse): add a WebDAV source with the same address and
  login.

## Plex on Linux

Plex can't read RAR archives. This guide mounts the rar2fs-dock server's folders on
your Linux Plex server, so Plex sees the files inside the archives as normal video
and audio files.

```
Windows PC                         Linux Plex server
rar2fs ─► WebDAV :8765  ─network─►  rclone mount ─► /mnt/media/tv    ─► Plex
                                    rclone mount ─► /mnt/media/films ─► Plex
```

Each folder from the server is mounted at a path you choose, so you can keep the
paths your Plex libraries already use.

### Before you start

You'll need:

- rar2fs-dock running on the Windows PC (see [Setup](#setup) above), with
  a password set in `.env`.
- The Windows PC's IP address. Run `ipconfig` on it and look for the IPv4 address,
  e.g. `192.168.1.63`.
- A Linux server with Plex and systemd, and `sudo` access. The commands below are for
  Debian/Ubuntu; on other distros, install `rclone` and `fuse3` with your package
  manager.

**In Plex, turn off automatic trash emptying first:** Settings → Library → *Empty
trash automatically after every scan*. If the Windows PC is off or restarting while
Plex scans, Plex sees empty folders. With this setting on, it would remove those items
and their watch history.

### 1. Open the server to your network (Windows PC)

In `docker-compose.yml`, the port line must be `"8765:8080"`, not
`"127.0.0.1:8765:8080"`. Then allow the port through Windows Firewall from an
**admin** PowerShell:

```powershell
New-NetFirewallRule -DisplayName "rar2fs-dock WebDAV" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow -Profile Private
```

Test from the Linux server. It should print `401`, which means it reached the server
and was asked for a password:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<windows-pc-ip>:8765/
```

If it hangs or says `000`, the firewall rule isn't working or the IP is wrong.

### 2. Install rclone (Linux server)

```bash
sudo apt install rclone fuse3
```

### 3. Install the mount service

Copy this repo's `linux/` folder to the server (or clone the repo there), then:

```bash
cd linux
sudo mkdir -p /etc/rar2fs/mounts
sudo cp rar2fs@.service /etc/systemd/system/
sudo systemctl daemon-reload
```

`rar2fs@.service` is a template. One copy runs per folder you mount, each reading its
own small config file.

### 4. Add the server's address and login

Create `/etc/rar2fs/common.conf`:

```bash
sudo cp common.conf.example /etc/rar2fs/common.conf
sudo chmod 600 /etc/rar2fs/common.conf
sudo nano /etc/rar2fs/common.conf
```

Fill it in with the Windows PC's IP and the `WEBDAV_USER` / `WEBDAV_PASS` from its
`.env` file:

```ini
RCLONE_WEBDAV_URL=http://192.168.1.63:8765
RCLONE_WEBDAV_USER=rar2fs
RCLONE_WEBDAV_PASS=<see below>
```

rclone needs the password in its own "obscured" form. Generate it with:

```bash
rclone obscure 'your-password-here'
```

and paste the output as `RCLONE_WEBDAV_PASS`. (Obscured isn't encrypted - it just
keeps the password from being readable at a glance. That's why the file is
`chmod 600`.)

### 5. Choose where each folder goes

Create one file per folder in `/etc/rar2fs/mounts/`. The file name (without `.conf`)
is the mount's name.

- `REMOTE` is the folder on the server - the same name you see in the Windows drive,
  e.g. `tv` or `films/films-1`.
- `MOUNTPOINT` is where it appears on this server.

For example:

```bash
printf 'REMOTE=tv\nMOUNTPOINT=/mnt/media/tv\n'       | sudo tee /etc/rar2fs/mounts/tv.conf
printf 'REMOTE=films\nMOUNTPOINT=/mnt/media/films\n' | sudo tee /etc/rar2fs/mounts/films.conf
```

To see which folders the server has:

```bash
sudo bash -c 'set -a; . /etc/rar2fs/common.conf; rclone lsd :webdav:'
```

The mount point must be an empty folder (it's created if it doesn't exist).

#### Replacing an existing SMB/NFS mount

If Plex already reads these files from a network share, you can mount rar2fs at the
same path so Plex's library settings don't change. Remove the old mount first:

```bash
sudo umount /mnt/media/tv
sudo nano /etc/fstab        # put a # in front of that share's line
```

Otherwise both will try to use the same folder at boot.

### 6. Start the mounts

```bash
sudo systemctl enable --now rar2fs@tv rar2fs@films
```

`enable` makes them start at every boot. A mount only starts once the Windows PC's
server answers, and keeps retrying until it does, so Plex never sees an empty folder
just because the PC was slower to boot.

Check them:

```bash
findmnt -t fuse.rclone        # each mount should be listed
ls /mnt/media/tv | head
```

Folders that held RAR sets should now show the video file (e.g. `.mkv`) instead of
`.rar` / `.r00` files.

### 7. Point Plex at the folders

- **New paths:** edit the library in Plex (*Manage Library → Edit → Add folders*) and
  add the mount points.
- **Same paths as before:** nothing to change.

Then scan the library. The first scan takes longer than on a normal share, because
Plex reads inside every archive.

Files that Plex already knew keep their metadata and watch history. Video that was
inside RARs is new to Plex, so it's added as new items.

### Everyday use on Linux

| To... | Run on the Linux server |
|---|---|
| See a mount's status | `systemctl status rar2fs@tv` |
| See its logs | `journalctl -u rar2fs@tv -e` |
| Pick up changes right away | `sudo systemctl restart rar2fs@tv` |
| Add a folder | Add a `.conf` file, then `sudo systemctl enable --now rar2fs@<name>` |
| Remove a folder | `sudo systemctl disable --now rar2fs@<name>`, then delete its `.conf` |

**New or changed folders take up to a minute to show up.** The mounts cache folder
listings for a minute. Restart the mount to see changes immediately. To change the
cache time, edit `--dir-cache-time` in `/etc/systemd/system/rar2fs@.service` and run
`sudo systemctl daemon-reload`.

**The Windows PC must stay on.** Docker Desktop only starts after someone logs in to
Windows, so set the PC to log in automatically, or keep it logged in.

### Troubleshooting on Linux

| Problem | Fix |
|---|---|
| `systemctl status` shows `401` or `Unauthorized` | Wrong user/password in `common.conf`. The password must be the `rclone obscure` output, not the plain password. |
| `connection refused` or timeouts | The Windows PC is off, the container isn't running (`docker ps` on Windows), or the firewall rule is missing. Re-run the `curl` test from step 1. |
| `directory is not empty` | Something is already in the mount point, often an old share that's still mounted. Check with `findmnt <path>`, unmount it, then restart the mount. |
| Plex can't see the files | Make sure the service file still has `--allow-other`. Without it, only root can read the mount. |
| Old folder layout still showing | Cached listing - `sudo systemctl restart rar2fs@<name>`. |
| Items marked *unavailable* in Plex | The Windows PC was off during a scan. Once it's back, scan again and they return - as long as trash emptying is off. |

## Everyday use

| To... | Run |
|---|---|
| Add or remove a source | Edit `docker-compose.yml`, then `docker compose up -d` |
| See container logs | `docker logs rar2fs` |
| Stop everything | `docker compose down` |
| Remove the auto-mount | `.\windows\uninstall-autostart.ps1` |

The container restarts on its own with Docker Desktop. For a fully hands-off setup,
enable Docker Desktop → Settings → General → *Start Docker Desktop when you sign in*.

## Extras

### Health report

Lists problems in your source folders: empty folders, RAR sets with parts missing,
RAR parts with no main `.rar`, and folders whose archives couldn't be opened (broken,
incomplete or password-protected). It only reads; nothing is changed.

```powershell
docker exec rar2fs health-report              # everything (can take a while)
docker exec rar2fs health-report tv/tv-1      # one folder
```

A set that is only missing its *last* parts can't be spotted from file names, so it
won't be listed.

### Health check

Docker checks every minute that each folder is still mounted and the server answers.
`docker ps` shows `(healthy)` or `(unhealthy)` next to the container. If it's
unhealthy, `docker compose restart` usually fixes it; `docker inspect rar2fs
--format '{{json .State.Health.Log}}'` shows which check failed.

### Archives inside archives (subtitles)

Scene releases often pack subtitles as a RAR inside a RAR
(`Subs/x.subs.rar` → `x.idx` + `x.rar` → `x.sub`). With `NESTED_RAR: "1"` (the default)
both levels are opened, so `Subs/` shows the `.idx` and `.sub` files. It costs roughly
15% of read speed; set it to `"0"` in `docker-compose.yml` to turn it off.

### Hiding clutter

`HIDE` in `docker-compose.yml` is a `;`-separated list of files and folders to leave
out of the drive. By default it hides `.sfv` files, `Sample` and `Proof` folders,
Windows/Mac thumbnail files and NAS recycle bins. Names match in any folder and ignore
upper/lower case; `Sample/**` means "a folder called Sample and everything in it".
Set `HIDE: ""` to show everything.

### More logins

The login in `.env` always works. To give another person or device its own login:

```powershell
.\windows\add-user.ps1 -Name plex -Pass 'some-password'
```

Logins are stored (hashed) in `config\users.htpasswd`, which is gitignored. To revoke
one, delete its line and run `docker compose restart`.

### Telling Plex about new files straight away

Plex can't detect changes on a network mount by itself, so new files normally wait for
its next scheduled scan. Set these in `.env` and the container will watch your source
folders and ask Plex to scan just the folder that changed:

```ini
PLEX_URL=http://192.168.1.50:32400
PLEX_TOKEN=xxxxxxxxxxxxxxxxxxxx
PLEX_PATH_MAP=tv=/mnt/media/tv;films=/mnt/media/films
```

- `PLEX_TOKEN`: in Plex Web, open any item → **⋯** → *Get Info* → *View XML*. The
  token is the `X-Plex-Token=...` value at the end of the address bar.
- `PLEX_PATH_MAP`: where each folder is mounted on the Plex server, as
  `<folder on the drive>=<path on the Plex server>`.

It checks once a minute and waits until a folder has stopped changing, so a new
download reaches Plex about 2-3 minutes after it finishes. `docker logs rar2fs` shows
a `plex-refresh:` line for every scan it requests. Leave `PLEX_TOKEN` empty to turn
this off.

## Keeping it to this PC only

If no other device needs it, change the port line in `docker-compose.yml` to
`"127.0.0.1:8765:8080"` and run `docker compose up -d`. Other machines then can't
connect at all. A password in `.env` is still required.

## Troubleshooting

- **The drive is empty or shows an error** - the container isn't running yet. Check
  `docker ps`; the drive recovers on its own once the container is up.
- **A newly added folder is empty on the drive** - the drive caches folder listings for
  1 minute. Wait a minute and refresh.
- **"Sorry, there was a problem mounting the file" when opening an ISO** - Windows'
  built-in ISO mounting only works on local disks and normal Windows shares, not on
  this drive. Use [WinCDEmu](https://wincdemu.sysprogs.org/) (free) instead: right-click
  the ISO → *Select drive letter & mount*. 7-Zip and WinRAR can also open ISOs directly.
- **A source folder is missing** - check `docker logs rar2fs` for its `rar2fs:` line,
  and make sure the path in `docker-compose.yml` exists.
- **Drive letter already in use** - `mount.ps1` stops with an error; pick another with `-Drive`.
- **Port 8765 already in use** - change the left side of `8765:8080` in
  `docker-compose.yml` and pass the new address with `-Url http://localhost:<port>`.

## Security

- **Your drives are read-only, and stay that way.** FUSE requires the container to have
  the `SYS_ADMIN` capability, which would normally let root inside it remount `:ro`
  folders as writable. To prevent that, nothing in the container runs as root:
  rar2fs, mergerfs and rclone run as an unprivileged user with no capabilities. Only
  the small setuid `fusermount` helpers use `SYS_ADMIN`, and only to create the mounts.
- **Password required.** The server is open to your local network, so it always
  needs the login from `.env`. Compose refuses to start without one. It uses plain
  HTTP, so don't expose port 8765 to the internet; for access away from home, use a
  VPN such as Tailscale. To shut out other machines entirely, see *Keeping it to this
  PC only*.
- **Pinned downloads.** The unrar and rar2fs source downloads are checked against
  SHA-256 hashes in the `Dockerfile`. Update the hash whenever you change a version.
- **Keep it updated.** rar2fs uses unrar to read archives, and unrar has had security
  bugs before. Rebuild now and then with `docker compose build --pull` and
  `docker compose up -d`, and bump `UNRAR_VERSION` when rarlab releases a new version.

## Why this design

- Windows can't see FUSE mounts made inside Docker Desktop containers, so the view has
  to be served over the network.
- Windows already uses SMB's port 445, so the container can't share it over SMB to
  this machine.
- Windows' built-in WebDAV client limits files to 4 GB and handles large folders
  poorly, so rclone + WinFsp mounts the drive instead. It has no size limit and
  supports seeking within large files.
