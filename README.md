# rar2fs-dock

Browse the contents of RAR archives on Windows as if they were already extracted - no
unpacking, no extra disk space.

[rar2fs](https://github.com/hasse69/rar2fs) runs inside a Docker container and reads
your local folders and network shares. The extracted view is served to Windows and
mounted as a normal drive letter (e.g. `Y:`). Other machines on your network - a Linux
Plex server, for instance - can mount the same view.

```
 D:\Downloads ─┐                    ┌──────── Docker ────────┐
 \\nas\media ─┼─► /sources/<name> ─► rar2fs ─► WebDAV :8765 ─┼─► rclone + WinFsp ─► Y:\
               │                    └────────────────────────┘
```

**Contents:** [What you need](#what-you-need) · [Setup](#setup) ·
[Other machines](#using-it-from-other-machines) ·
[Plex on this PC](#plex-on-the-same-windows-pc) ·
[Plex on another Windows PC](#plex-on-another-windows-pc) · [Plex on Linux](#plex-on-linux) ·
[Everyday use](#everyday-use) · [Extras](#extras) · [Settings](#settings) ·
[This PC only](#keeping-it-to-this-pc-only) · [Troubleshooting](#troubleshooting) ·
[Security](#security) · [Why this design](#why-this-design)

## What you need

| Tool | Install |
|---|---|
| Docker Desktop | <https://www.docker.com/products/docker-desktop/> |
| WinFsp (Windows FUSE driver) | `winget install WinFsp.WinFsp` |
| rclone | `winget install Rclone.Rclone` |

After installing rclone, open a **new** PowerShell window so it's on your PATH.

## Setup

### Quick way: the setup wizard

Install Docker Desktop and start it, then open PowerShell in this folder and run:

```powershell
.\windows\setup.ps1
```

It does the rest:

1. Installs WinFsp and rclone if they're missing.
2. Asks which folders hold your media and what each should be called on the drive.
   Folders on a NAS drive letter work too - it sets those up as network shares and
   asks for the NAS login.
3. Asks whether other devices will connect, and whether to shorten over-long folder
   names.
4. Writes `.env` (with a random password) and `docker-compose.override.yml` (your
   folders).
5. Builds and starts the container. The first build takes several minutes.
6. Mounts the drive and makes it come back at every login.

It's safe to run again: it never overwrites an existing `.env`, and keeps your folder
list unless you add `-Force`. Everything can also be given up front, with no
questions:

```powershell
.\windows\setup.ps1 -Yes -Folder "D:\Movies=movies","E:\TV=tv" -Drive R:
```

If PowerShell refuses to run the script, run this first:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

The numbered steps below do the same thing by hand, and explain each part.

### 1. Choose your source folders

Your folders go in a file of your own, `docker-compose.override.yml`. Docker merges
it with `docker-compose.yml` automatically, and it's gitignored, so pulling updates
never touches it. Copy `docker-compose.override.example.yml` to that name and edit
it. Every volume mounted at `/sources/<name>` shows up as `Y:\<name>`.

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
  - "D:/Movies:/sources/films/films-1:ro"    # -> Y:\films\films-1
  - "E:/Movies:/sources/films/films-2:ro"    # -> Y:\films\films-2
```

**Several folders merged into one:** give them the same name followed by `@` and any
label. Their contents appear together in one folder:

```yaml
volumes:
  - "E:/tv:/sources/tv@e:ro"
  - "F:/tv:/sources/tv@f:ro"     # E:\tv + F:\tv -> Y:\tv
```

This works with network shares too (`- nas-tv:/sources/tv@nas:ro`). If the same file or
folder exists in more than one source, the folders' contents are combined, and for a
file, the first source alphabetically by label wins.

**Network share (SMB/CIFS):** Docker can't see drive letters that Windows has mapped
to a NAS, so a share is connected by its network address instead. In
`docker-compose.override.yml`:

1. At the bottom, remove the `#` from the `x-nas-options` lines and from the
   `volumes:` block under them, and set `device` to the folder you want. One entry
   per NAS folder:
   ```yaml
   x-nas-options: &nas-options
     type: cifs
     o: "username=${NAS_USER:?set NAS_USER in .env},password=${NAS_PASS:?set NAS_PASS in .env},vers=3.0,iocharset=utf8,ro,uid=1000,gid=1000"

   volumes:
     nas-tv:
       driver_opts:
         <<: *nas-options
         device: "//nas.example.com/share/TV"  # point straight at the folder you want
   ```
   These start at the left margin, not indented under `services:`.
2. Mount it with your other folders, like any other source. It can go anywhere,
   including inside a subfolder group:
   ```yaml
         - nas-tv:/sources/tv/tv-3:ro          # -> Y:\tv\tv-3
   ```

The login comes from `NAS_USER` / `NAS_PASS` in `.env`. After changing a share's
`device`, run `docker compose down` then `docker compose up -d` - Docker keeps a
volume's old settings until it's recreated.

### 2. Set a password

Copy `.env.example` to `.env` and change `WEBDAV_PASS`. The container won't start
without it. `.env` is gitignored, so the password never gets committed.

**Long folder or file names?** If any of your paths come close to Windows' 260-character
limit - release folders nested inside each other get there quickly - also add this
line to `.env`:

```ini
SHORT_PATHS=1
```

The drive then shows shortened folder names where needed, so every file can be
opened. See [Short names for Windows](#short-names-for-windows) for how it works.

### 3. Start the container

From this folder:

```powershell
docker compose up -d --build
```

Check that it's working by opening <https://localhost:8765> in a browser and logging in
with the user and password from `.env` - you should see a folder for each source. The
browser will warn that the certificate isn't trusted. That's expected: the container
made the certificate itself (see [HTTPS](#https)). Choose *Advanced* → *Proceed*.

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

The drive letter only appears once the container is answering. After a restart Windows
logs in before Docker is ready, and this way programs that start at login - Plex, for
one - never find an empty drive. If the drive doesn't appear, run `.\windows\mount.ps1`
in a window to see what it's waiting for.

If PowerShell refuses to run the scripts, run this first:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

That's it - open `Y:\` in Explorer.

## Using it from other machines

Two machines are involved here:

- **The server PC** has the archives and runs the container. Everything in
  [Setup](#setup) happens there.
- **The other machine** has no Docker and no archives. It connects to the server PC
  over your network and shows the same unpacked folders.

```
        SERVER PC (192.168.1.10)                         OTHER MACHINE
 archives ─► Docker container ─► port 8765  ◄── network ──  rclone ─► Y:\
```

Do [the server PC part](#on-the-server-pc-once) once, then follow the part for the
kind of machine you're connecting.

### On the server PC (once)

**1. Find the server PC's address.** In PowerShell run `ipconfig` and note the *IPv4
Address* of your network adapter, for example `192.168.1.10`. The examples below use
that one - put yours in its place. If your router lets you reserve an address for a
device, do that for this PC, so the address never changes.

**2. Make sure the container accepts other devices.** Open `.env`. If it has a line
`BIND=127.0.0.1`, delete it - the setup wizard adds that line when you answer that only
this PC should connect.

**3. Put the address in the certificate.** Other devices check that the certificate
matches the address they connect to. Still in `.env`, list every address or name they
will use, separated by commas:

```ini
TLS_HOSTS=192.168.1.10
```

**4. Apply both changes:**

```powershell
docker compose up -d
```

**5. Allow the ports through Windows Firewall.** In a PowerShell window opened with
*Run as administrator*:

```powershell
New-NetFirewallRule -DisplayName "rar2fs-dock" -Direction Inbound -Protocol TCP -LocalPort 8765-8767 -Action Allow -Profile Private
```

8765 is the drive, 8766 the status page and 8767 the
[short-names view](#short-names-for-windows). The rule only applies while Windows
treats your network as *Private* (Settings → Network & Internet → your connection →
*Network profile*).

**6. Check it from the other machine.** In a browser there, open
`https://192.168.1.10:8766/status.html`. Accept the certificate warning and log in with
the user and password from the server PC's `.env`. If the status page appears, the
network side is done. If it doesn't, see
[When the other machine can't connect](#when-the-other-machine-cant-connect).

### Connecting another Windows PC

If that PC runs Plex, `.\windows\connect-plex.ps1` on the server PC does these steps
for you - see [Plex on another Windows PC](#plex-on-another-windows-pc). By hand:

On the other PC. It doesn't need Docker or a copy of your archives.

**1. Install WinFsp and rclone,** then open a **new** PowerShell window:

```powershell
winget install WinFsp.WinFsp
winget install Rclone.Rclone
```

**2. Make a folder for the scripts,** for example `C:\rar2fs-dock`, and copy two
things into it from the server PC (a USB stick or a shared folder will do):

| Copy from the server PC | To the other PC |
|---|---|
| the whole `windows` folder | `C:\rar2fs-dock\windows\` |
| `tls\cert.pem` (only this file - never `key.pem`) | `C:\rar2fs-dock\tls\cert.pem` |

**3. Save the login.** Create `C:\rar2fs-dock\.env` in Notepad with these two lines,
using a login the server accepts - the one from the server PC's `.env`, or better a
separate one made for this PC (see [More logins](#more-logins)):

```ini
WEBDAV_USER=yourname
WEBDAV_PASS=yourpassword
```

Don't copy the server PC's whole `.env`; these two lines are all this PC needs.

**4. Try it.** The address is the server PC's, not `localhost`:

```powershell
cd C:\rar2fs-dock
.\windows\mount.ps1 -Url https://192.168.1.10:8765
```

`Y:` appears in Explorer with the same folders as on the server PC. It stays while the
window is open; close the window to disconnect. Add `-Drive X:` for another letter.

**5. Make it permanent.** Once that works, close the window and run:

```powershell
.\windows\install-autostart.ps1 -Url https://192.168.1.10:8765
```

The drive now comes back at every login. Remove it with
`.\windows\uninstall-autostart.ps1`.

Things to know:

- **Long names:** if the server PC has `SHORT_PATHS=1`, use port `8767` in the address
  instead of `8765` to get the view with shortened names.
- **The server PC has to be on,** with Docker Desktop running. While it's off, the drive
  letter waits and appears by itself once the server answers again.
- **If the certificate on the server PC is ever recreated** (after changing
  `TLS_HOSTS`, for example), copy the new `tls\cert.pem` over again.
- **The tray icon, `doctor.ps1`, `update.ps1` and the backup scripts are for the
  server PC only.** On the other PC you only need `mount.ps1`, `install-autostart.ps1`
  and `uninstall-autostart.ps1`.
- **If PowerShell refuses to run the scripts,** run this first:
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

### Connecting Linux, a Mac or a media player

- **Plex (or anything else) on Linux:** see [Plex on Linux](#plex-on-linux) below.
- **Mac, and media players** (Kodi, VLC, Infuse): add a WebDAV source at
  `https://192.168.1.10:8765` with the same login. Many of these refuse a
  self-signed certificate or make it awkward to accept one. If yours does, either
  install `tls\cert.pem` as a trusted certificate on that device, or turn HTTPS off
  (see [HTTPS](#https)).

### When the other machine can't connect

| What you see | What it means and what to do |
|---|---|
| The status page doesn't open in the browser at all (it times out) | The other machine can't reach the server PC. Check the address with `ipconfig` on the server PC, that `.env` there has no `BIND=127.0.0.1`, that the firewall rule exists and the network is *Private*, and that both machines are on the same network (a guest Wi-Fi is usually kept apart). |
| The status page opens, but `mount.ps1` keeps saying *Waiting for the rar2fs container to answer* with a `certificate` error | The address you used isn't in the certificate, or `tls\cert.pem` on the other PC is an old copy. Add the address to `TLS_HOSTS` on the server PC, run `docker compose up -d`, and copy `tls\cert.pem` over again. |
| *The server ... rejected the login* | The user or password in the other PC's `.env` isn't one the server accepts. Compare it with the server PC's `.env`, or with the login you made for this PC. |
| *rclone not found* | Open a new PowerShell window after installing rclone. |
| *Y: is already in use* | Pick another letter: add `-Drive X:`. |
| It worked, then stopped after a change on the server PC | Changing `TLS`, `TLS_HOSTS` or `SHORT_PATHS` there changes the address or the certificate. Copy the new `tls\cert.pem`, then run `uninstall-autostart.ps1` and `install-autostart.ps1` again with the right address. |

On the server PC, `.\windows\doctor.ps1` checks the container side for you (see
[Setup check](#setup-check)).

## Plex on the same Windows PC

If Plex Media Server runs on the PC that runs rar2fs-dock, it can read the drive
directly. No firewall rule is needed for that, and you can limit the server to this PC
(see [Keeping it to this PC only](#keeping-it-to-this-pc-only)).

1. **Finish [Setup](#setup)** so the drive (e.g. `Y:`) mounts at login. If your
   folder or file names are long, set `SHORT_PATHS=1` in `.env` first, so no path
   goes over Windows' 260-character limit.
2. **In Plex, turn off automatic trash emptying:** Settings → Library → *Empty trash
   automatically after every scan*. After a restart, Plex can start before Docker
   has the drive ready. With this setting on, a scan in that gap would remove your
   items and their watch history; with it off, they're only marked unavailable until
   the drive is back.
3. **Add the drive's folders to your libraries:** *Manage Library → Edit → Add
   folders*, e.g. `Y:\movies`. If the drive isn't listed in the folder browser, type
   the path in.
4. **Scan the library.** The first scan is slower than on a normal disk, because Plex
   reads inside every archive.

Things to know:

- **Plex must run as the same Windows user** that mounts the drive - the normal
  installation does. If you've set Plex up to run as a Windows service under another
  account, it won't see the drive letter.
- **Docker Desktop has to be running.** Turn on Docker Desktop → Settings → General →
  *Start Docker Desktop when you sign in*. The drive letter only appears once the
  container is answering, so Plex never scans an empty drive at start-up.
- **New files appear at Plex's next scan.** Plex can't detect changes on this drive
  by itself. Either use *Scan Library Files* / Settings → Library → *Scan my library
  periodically*, or let the container tell Plex the moment something changes - see
  [Telling Plex about new files straight away](#telling-plex-about-new-files-straight-away).
- **Video inside RARs is new to Plex.** Files Plex already knew keep their metadata;
  video it couldn't read before is added as new items.

## Plex on another Windows PC

If Plex runs on a different Windows PC than the one with the container, one script on
the server PC does nearly all of it. The setup wizard offers to run it at the end, or
run it yourself any time:

```powershell
.\windows\connect-plex.ps1
```

It asks for the Plex PC's IP address or name, then:

1. **Opens this PC to your network:** removes `BIND=127.0.0.1` from `.env` if it's
   there, adds this PC's address to `TLS_HOSTS`, and adds the Windows Firewall rule
   (Windows asks for permission once).
2. **Makes a login just for the Plex PC,** called `plex`, with a random password.
3. **Gets a Plex token:** it shows a four-character code that you enter at
   <https://plex.tv/link> while signed in to your Plex account. With the token it turns
   off Plex's *Empty trash automatically after every scan* and writes `PLEX_URL`,
   `PLEX_TOKEN` and `PLEX_PATH_MAP` to `.env`, so Plex is told about new files
   [straight away](#telling-plex-about-new-files-straight-away). You can paste a token
   instead, or skip this part.
4. **Restarts the container** once with the new settings.
5. **Copies a ready-made folder to the Plex PC** and tells you where it put it. The
   folder holds the mount scripts, the certificate, the login and a `Setup.cmd`.

**What's left for you, on the Plex PC:**

1. Log in as the Windows user Plex runs as and open the folder the script named
   (normally `C:\rar2fs-dock`).
2. Double-click `Setup.cmd`. It installs WinFsp and rclone if they're missing, mounts
   the drive as `Y:` and brings it back at every login.
3. In Plex, add the drive's folders to your libraries (*Manage Library → Edit → Add
   folders*). The script and `READ-ME.txt` in the folder list them, e.g. `Y:\films`.

That last part can't be done from the server PC: Windows doesn't let one PC install
things on another.

**About the copy.** The script first tries the Plex PC's own `C:` drive over the
network. Windows often refuses that on home PCs, so it then offers three ways on:

- sign in with an administrator account of the Plex PC
- copy to a shared folder on the Plex PC instead - on that PC, right-click any folder →
  *Properties → Sharing → Share*, and allow changes
- skip the copy: the folder is left in your Documents as `rar2fs-dock-plex`, to carry
  over yourself. It holds a password, so delete that copy afterwards.

Options: `-PlexHost 192.168.1.20` skips the question, `-Drive P:` uses another letter
on the Plex PC, `-CopyTo \\192.168.1.20\Shared` names the shared folder up front,
`-NoPlex` sets up the drive only, and `-DryRun` shows what it would do without changing
anything. Running it again is safe; it makes a new password for the `plex` login and a
fresh folder each time.

The "things to know" under [Plex on the same Windows PC](#plex-on-the-same-windows-pc)
apply here too, and
[When the other machine can't connect](#when-the-other-machine-cant-connect) covers
the network side.

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
  e.g. `192.168.1.10`. Put it in `.env` as `TLS_HOSTS` (see
  [Using it from other machines](#using-it-from-other-machines)), so the certificate
  covers it.
- A Linux server with Plex and systemd, and `sudo` access. The commands below are for
  Debian/Ubuntu; on other distros, install `rclone` and `fuse3` with your package
  manager.

**In Plex, turn off automatic trash emptying first:** Settings → Library → *Empty
trash automatically after every scan*. If the Windows PC is off or restarting while
Plex scans, Plex sees empty folders. With this setting on, it would remove those items
and their watch history.

### Quick way: the installer

Copy this repo's `linux/` folder to the server (or clone the repo there), do
[step 1](#1-open-the-server-to-your-network-windows-pc) on the Windows PC, then run:

```bash
cd linux
sudo sh install.sh
```

It installs rclone if needed and asks for the server's address
(`https://<windows-pc-ip>:8765`) and login. It then downloads the server's certificate
and shows its fingerprint, which you compare with the `tls:` line in
`docker logs rar2fs` on the Windows PC. After that it lists the folders the server
has and asks where each one should be mounted. It won't mount
over a folder that's in use - it tells you what to unmount first - and it never edits
`/etc/fstab`. Run it again any time to add more folders. Then skip to
[step 7](#7-point-plex-at-the-folders).

The steps below do the same thing by hand.

### 1. Open the server to your network (Windows PC)

Make sure `.env` has no `BIND=127.0.0.1` line - the setup wizard adds one if you said
no other devices would connect. Then allow the ports through Windows Firewall from an
**admin** PowerShell (8765 is the drive, 8766 the status page, 8767 the short-names view):

```powershell
New-NetFirewallRule -DisplayName "rar2fs-dock" -Direction Inbound -Protocol TCP -LocalPort 8765-8767 -Action Allow -Profile Private
```

Test from the Linux server. It should print `401`, which means it reached the server
and was asked for a password (`-k` skips the certificate check for this one test):

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://<windows-pc-ip>:8765/
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
RCLONE_WEBDAV_URL=https://192.168.1.10:8765
RCLONE_WEBDAV_USER=rar2fs
RCLONE_WEBDAV_PASS=<see below>
RCLONE_CA_CERT=/etc/rar2fs/cert.pem
```

`cert.pem` is the server's certificate: copy `tls\cert.pem` from the Windows PC to
`/etc/rar2fs/cert.pem`. (The installer fetches it for you.)

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

(`linux/mounts/` in this repo has these two files as examples you can copy instead.)

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
| `x509: certificate ...` errors | The server's certificate doesn't match. Either this PC's address isn't in `TLS_HOSTS` on the Windows PC, or the certificate changed since `/etc/rar2fs/cert.pem` was copied. Fix `TLS_HOSTS` if needed, then run the installer again with `--url https://<windows-pc-ip>:8765` to fetch the current one. |
| `429 Too Many Requests` | Several wrong passwords were tried in a row, so new logins are refused for a short while. Fix the password in `common.conf`, wait a minute, restart the mount. |
| Plex can't see the files | Make sure the service file still has `--allow-other`. Without it, only root can read the mount. |
| Old folder layout still showing | Cached listing - `sudo systemctl restart rar2fs@<name>`. |
| Items marked *unavailable* in Plex | The Windows PC was off during a scan. Once it's back, scan again and they return - as long as trash emptying is off. |

## Everyday use

| To... | Run |
|---|---|
| Add or remove a source | Edit `docker-compose.override.yml`, then `docker compose up -d` |
| Change a setting | Edit `.env` or `docker-compose.yml` (see [Settings](#settings)), then `docker compose up -d` |
| See what it's doing | Open <https://localhost:8766/status.html> |
| Check your folders for problems | The **Run health report** button on that page |
| See container logs | `docker logs rar2fs` |
| Stop everything | `docker compose down` |
| Remove the auto-mount | `.\windows\uninstall-autostart.ps1` |
| Change the drive letter | `.\windows\uninstall-autostart.ps1`, then `.\windows\install-autostart.ps1 -Drive X:` |
| Find something, see what's new, spot duplicates | The [status page](#the-library-search-recently-added-duplicates-sizes) |
| Add a folder without a restart | `.\windows\add-folder.ps1 -Path E:\Concerts` - see [Adding folders without a restart](#adding-folders-without-a-restart) |
| Update to a newer version | `.\windows\update.ps1` - see [Updating](#updating) |
| Find out why something isn't working | `.\windows\doctor.ps1` - see [Setup check](#setup-check) |
| Save your setup, or move it to another PC | `.\windows\backup.ps1` - see [Backup and restore](#backup-and-restore) |
| See at a glance whether it's healthy | The [tray icon](#tray-icon) |

The container answers on three ports, all with the same logins:

| Port | What | Address on this PC |
|---|---|---|
| 8765 | The drive | <https://localhost:8765> |
| 8766 | The status page | <https://localhost:8766/status.html> |
| 8767 | The drive with [shortened names](#short-names-for-windows), when `SHORT_PATHS=1` | <https://localhost:8767> |

From another device, use this PC's address in place of `localhost`. With `TLS=0` the
addresses start with `http://`.

The container restarts on its own with Docker Desktop. For a fully hands-off setup,
enable Docker Desktop → Settings → General → *Start Docker Desktop when you sign in*.

## Extras

### Status page

<https://localhost:8766/status.html> (or `https://<this-PC's-IP>:8766/status.html` from
another device), with the same login as the drive. Your browser will warn about the
self-signed certificate the first time; accept it once. It shows each folder, where it
comes from and whether it's mounted or has stopped, the unrar/rar2fs versions and
whether newer ones exist, the last health report, recent events (restarts, Plex scans,
alerts) and the current settings.

The page is live: while you have it open it updates itself every few seconds, without
reloading, so a folder that stops or a report that finishes shows up straight away. A
red bar appears at the top if the container stops answering. When nobody is looking the
container only rebuilds the page once a minute, so a forgotten tab costs nothing - a tab
in the background pauses too.

The **Run health report** button starts a [health report](#health-report) without
opening a terminal. Choose *Everything* or a single folder first - one folder is much
quicker. The page shows *running* while it works and updates by itself when the result
is in. Only one report runs at a time.

### Setup check

When something isn't right - a folder is missing from the drive, a network share is
empty, the container won't start - run:

```powershell
.\windows\doctor.ps1
```

It changes nothing. It reads `.env` and the compose files, looks at every folder and
network share they name, asks the container what it sees, and prints one line per
check: `ok`, `CHECK` (worth a look) or `PROBLEM`, with what to do about it. Among the
things it catches:

- a Windows folder that doesn't exist or is misspelled (Docker quietly creates it, empty)
- a drive letter that Windows mapped to a NAS, which Docker can't see
- a network share that is defined at the bottom of the file but that no line under the
  service's `volumes:` uses, so it never appears on the drive
- a network share entry with no `device:`, or one Docker can't reach
- a network share whose address or login you changed after Docker first connected it -
  Docker keeps using the old one until the volume is removed, and the check gives you
  the exact commands
- folders you added to the file but haven't applied yet with `docker compose up -d`
- source folders that are empty or unreadable from inside the container
- an HTTPS certificate that is about to run out, the example password still in use,
  and Plex refresh settings that don't match your folders or that Plex turns down

The checks the container can do by itself also run all the time and show on the status
page under **Setup check**, in `status.json` (`setup_problems`, `setup_check`) and as
the `rar2fs_dock_setup_problems` metric.

### Automatic restart

If the [health check](#health-check) fails three times in a row, the container
restarts itself, which remounts everything. If that happens three times within an hour
it stops trying, so a problem a restart can't fix (an unplugged drive, say) doesn't
turn into a restart loop. Set `AUTO_RESTART: "0"` in `docker-compose.yml` to turn it
off.

The status page is looked after separately: if it stops answering, only its own small
server is restarted, so the drive carries on undisturbed.

### Notifications

The container can message you when something needs attention, so you don't have to
check the status page. You get a message when:

- the container goes unhealthy, restarts itself, recovers, or gives up restarting
- the status page had to be restarted
- a newer unrar or rar2fs release is out (checked daily)
- the scheduled health report finds **new** problems (every `HEALTH_REPORT_DAYS` days,
  7 by default; problems it has already told you about aren't repeated)

Pick one of the services below, put its address in `.env` as `NOTIFY_URL`, and run
`docker compose up -d`. Without `NOTIFY_URL`, the same events still appear on the
status page.

**ntfy - notifications on your phone (simplest)**

1. Install the free **ntfy** app (iOS or Android). No account is needed.
2. In the app, tap **+** and subscribe to a topic name you make up. Make it long and
   random, e.g. `rar2fs-8f3k2x9q7` - anyone who knows the name can read the messages.
3. In `.env`:
   ```ini
   NOTIFY_URL=https://ntfy.sh/rar2fs-8f3k2x9q7
   ```

You can also read the messages in a browser at `https://ntfy.sh/<your-topic>`.

**Discord - messages in a channel**

1. In a server you manage, open the channel's settings → *Integrations* → *Webhooks* →
   *New Webhook* → *Copy Webhook URL*.
2. In `.env`:
   ```ini
   NOTIFY_URL=https://discord.com/api/webhooks/...
   ```

**Slack - messages in a channel**

1. Create an *Incoming Webhook* for the channel (Slack → *Apps* → *Incoming Webhooks*)
   and copy its URL.
2. In `.env`:
   ```ini
   NOTIFY_URL=https://hooks.slack.com/services/...
   ```

**Test it**

After `docker compose up -d`, send yourself a message:

```powershell
docker exec rar2fs notify "Test" "Hello from rar2fs-dock"
```

If the address is wrong or unreachable, the command prints
`notify: could not deliver to NOTIFY_URL`.

### The library: search, recently added, duplicates, sizes

The status page also knows what is on the drive.

- **Search.** The box at the top finds anything by name across every folder and drive,
  and tells you which folder it's in. It looks at the top two levels of each folder
  (a film or show, and the seasons or albums inside it).
- **Recently added.** The newest items, wherever they landed. The newest 20 are also
  an RSS feed at `https://<pc>:8766/recent.xml`, for a feed reader.
- **Duplicates.** Two lists: items with the *same name in more than one place* (the
  same release on two drives), and *different releases of the same title* (a 720p and
  a 1080p of one film, or one episode twice). The full list is linked from the page
  as `duplicates.txt`. In a merged folder it also finds copies that the merged view
  hides. Parts of one set (Disc1, Disc2) aren't counted as duplicates.
- **Sizes.** Press **Scan sizes** to measure everything: the total, the size of each
  folder, how much is in RAR archives, the largest items, and how much space the
  duplicates take. It also shows what unpacking everything would cost in disk space -
  which is what this project saves you.

The index of names is rebuilt every 10 minutes and takes a few seconds. The size scan
reads the size of every file, so it takes minutes on a large library (about five for
nine terabytes in 140,000 files, in testing); it runs when you press the button and
after each scheduled health report. Nothing here changes any file.

### Adding folders without a restart

Changing the folder list in `docker-compose.override.yml` restarts the container,
which pauses the drive - and Plex - for a minute. To add a folder while it keeps
running:

```powershell
.\windows\add-folder.ps1 -Path E:\Concerts            # -> Y:\concerts
.\windows\add-folder.ps1 -Path E:\More-TV -Name tv    # joins the existing tv folder
.\windows\add-folder.ps1 -Remove concerts
.\windows\add-folder.ps1 -List
```

Docker can't attach a new Windows folder to a container that is already running, so
this works through whole drives. Once a drive is visible to the container (read-only,
at `/drives/<letter>`), any folder on it can be added or removed in seconds, and the
other folders aren't touched. The first time you add a folder from a drive, the script
offers to make that drive visible; that needs one restart, and none after it.

Two things to know. Making a drive visible lets the container read all of it, although
only the folders you add are ever served. And folders on a NAS can't be added this way;
they go in `docker-compose.override.yml` as network shares.

Folders added like this are listed in `config\folders.conf`, one per line
(`concerts = /drives/e/Concerts`). You can edit that file by hand and then run
`docker exec rar2fs mount-folders reload`.

### Tray icon

A coloured dot next to the clock shows the state at a glance: green for healthy, red
for unhealthy, amber while starting, grey when the container isn't answering (Docker
Desktop not running, usually). A notification pops up when the state changes.

```powershell
.\windows\install-tray.ps1       # start it now and at every login
.\windows\uninstall-tray.ps1
```

Right-click it for: the current state, *Open status page*, *Open drive*, *Remount
drive* and *Restart container*. Double-click opens the status page. The setup wizard
offers to install it. Windows may tuck new icons behind the **^** arrow; drag it out
next to the clock to keep it in view.

### Updating

```powershell
.\windows\update.ps1
```

One command: it pulls the latest version, rebuilds and restarts the container, waits
until it's healthy, remounts the drive if that's needed, and tells you if other
devices need anything (new files for a Linux machine, or a new certificate).

If you're coming from a version that kept your folders in `docker-compose.yml`, it
first moves them into `docker-compose.override.yml` - your network shares too - so
the update can't overwrite them. Your old file is kept as
`docker-compose.yml.before-update`.

### Backup and restore

```powershell
.\windows\backup.ps1                        # a zip in your Documents folder
.\windows\backup.ps1 -To D:\Backups
.\windows\restore.ps1 -File <the zip>
```

The backup holds everything that is yours: `.env`, your folder list, extra logins,
folders added without a restart, and the HTTPS certificate. It contains passwords and
a private key, so keep it somewhere private.

To move to another PC: clone the repo there, run `restore.ps1`, then
`.\windows\setup.ps1`, which keeps the restored files and does the rest. Because the
certificate comes along, other devices keep working without being set up again -
provided the new PC has the same address.

### Dashboards and monitoring

The status page's information is also available in forms other programs can read, on
the same port and with the same login:

| Address | What | For |
|---|---|---|
| `https://<pc>:8766/status.json` | Everything on the status page, as JSON | Homepage, Home Assistant, Uptime Kuma, any dashboard with a JSON widget |
| `https://<pc>:8766/metrics` | The numbers, in Prometheus format | Prometheus and Grafana |

**Logging in.** Both accept the usual user name and password. For apps that can't send
those, set a token in `.env` and add it to the address:

```ini
STATUS_TOKEN=pick-a-long-random-string
```

`https://<pc>:8766/status.json?token=pick-a-long-random-string`

The token can only read those two addresses and the RSS feed (`/recent.xml`).

**The certificate.** With HTTPS on, the app has to accept the container's self-signed
certificate. Most have a switch for it ("ignore TLS errors", `verify_ssl: false`), or
can be given `tls\cert.pem` to trust.

**A heartbeat, for when the whole PC is down.** Everything above stops answering if
this PC is off or Docker isn't running, and nothing inside the container can tell you
that. A heartbeat turns it around: the container pings an outside service every minute
while it's healthy, and that service alerts you when the pings stop.

```ini
HEARTBEAT_URL=https://uptime.example.com/api/push/abc123?status=up&msg=OK
```

- **Uptime Kuma:** add a monitor of type *Push*, set its heartbeat interval to 60
  seconds, and copy the push URL it shows.
- **Healthchecks.io:** create a check with a 1-minute period and copy its ping URL
  (`https://hc-ping.com/...`).

With either of those, an unhealthy container also reports "down" straight away, with
the reason. Any other URL is simply fetched once a minute while healthy.

**Examples.** Replace the address and token with your own.

*Homepage* (`services.yaml`) - up to four fields:

```yaml
- rar2fs-dock:
    href: https://192.168.1.10:8766/status.html
    widget:
      type: customapi
      url: https://192.168.1.10:8766/status.json?token=YOUR_TOKEN
      refreshInterval: 60000
      mappings:
        - field: health
          label: Status
        - field: folders_mounted
          label: Folders up
        - field: updates_available
          label: Updates
        - field: report_problems
          label: Problems
```

Homepage checks certificates; give it the container's by setting
`NODE_EXTRA_CA_CERTS` to a copy of `cert.pem` in Homepage's own container.

*Uptime Kuma* - besides the push monitor above, an *HTTP(s) - Keyword* monitor on
`https://192.168.1.10:8766/status.json?token=YOUR_TOKEN` with the keyword
`"healthy": true` and *Ignore TLS/SSL errors* switched on.

*Prometheus* (`prometheus.yml`):

```yaml
scrape_configs:
  - job_name: rar2fs-dock
    scheme: https
    metrics_path: /metrics
    params:
      token: [YOUR_TOKEN]
    tls_config:
      ca_file: /etc/prometheus/rar2fs-cert.pem   # a copy of tls\cert.pem
    static_configs:
      - targets: ["192.168.1.10:8766"]
```

*Home Assistant* (`configuration.yaml`):

```yaml
sensor:
  - platform: rest
    name: rar2fs-dock
    resource: https://192.168.1.10:8766/status.json?token=YOUR_TOKEN
    value_template: "{{ value_json.health }}"
    json_attributes:
      - folders_mounted
      - folders_total
      - updates_available
      - report_problems
    verify_ssl: false
    scan_interval: 60
```

Fields in `status.json`: `health` (`healthy`, `unhealthy` or `starting`), `healthy`
(true/false), `detail` (which check failed), `folders_total`, `folders_mounted`,
`updates_available`, `report_problems`, `restarts_last_hour`, `library_items`,
`library_bytes`, `duplicates`, and the full lists under
`folders`, `versions`, `report`, `settings` and `events`.

### Updates for unrar and rar2fs

unrar is the part that reads untrusted archives, so it's the one worth keeping
current. When the status page (or a notification) says a newer version is out:

1. In the `Dockerfile`, change `UNRAR_VERSION` (or `RAR2FS_VERSION`) at the top.
2. Update the matching `..._SHA256` line. Get the new value with:
   ```powershell
   curl.exe -sL https://www.rarlab.com/rar/unrarsrc-<version>.tar.gz | docker run --rm -i debian:bookworm-slim sha256sum
   ```
3. `docker compose up -d --build`

The build fails if the hash doesn't match the download, so a typo can't slip through.

### HTTPS

The drive and the status page use HTTPS by default, so the password and your file
names can't be read by other devices on the network.

- **The certificate is made by the container** the first time it starts, and kept in
  `tls\` (gitignored). Its fingerprint is printed at every start - see
  `docker logs rar2fs`.
- **It's self-signed,** so nothing trusts it automatically. The scripts in this repo
  handle that: the Windows scripts trust `tls\cert.pem`, and the Linux installer
  downloads it and shows you the fingerprint to compare. Browsers show a warning you
  accept once.
- **`TLS_HOSTS` in `.env` lists the addresses in the certificate.** It always covers
  `localhost`. Add this PC's IP address or name for other devices
  (`TLS_HOSTS=192.168.1.10,mypc.lan`). Changing it creates a new certificate, and
  other devices then need the new `cert.pem`.
- **To use your own certificate,** put it in `tls\cert.pem` and `tls\key.pem`.

**Turning it off.** Some players and devices can't work with a self-signed
certificate. For plain HTTP, put this in `.env` and run `docker compose up -d`:

```ini
TLS=0
```

Addresses then start with `http://`. Re-run `.\windows\uninstall-autostart.ps1` and
`.\windows\install-autostart.ps1` on this PC, and the Linux installer with the `http://`
address on Linux machines. On a home network you trust this is a reasonable choice;
anywhere else, keep HTTPS on.

**Upgrading from a version where HTTPS was off by default:** every device has to
switch at the same time. Set `TLS_HOSTS`, run `docker compose up -d`, then:

1. **This PC:** `.\windows\uninstall-autostart.ps1` then `.\windows\install-autostart.ps1`.
2. **Linux machines:** `sudo sh install.sh --url https://<this-PC's-IP>:8765 --user
   <user> --pass '<password>'`, then `sudo systemctl restart 'rar2fs@*'`.
3. **Other Windows PCs:** copy the new `tls\cert.pem` over and use the `https://`
   address.

To put that off, set `TLS=0` for now.

### Short names for Windows

Many Windows programs fail on paths longer than 260 characters ("path too long", "file
not found", or the file simply won't open). Release folders nested inside each other
get there quickly. Turn this on and the container offers a second view of the same
files, on port 8767, in which no path is too long:

```ini
SHORT_PATHS=1
```

Put that in `.env`, then run `docker compose up -d`.

- **Only names that need it change.** A path that already fits is shown exactly as it
  is. Nothing on disk is renamed.
- **Folders are shortened, not files.** The file name is what players and Plex go by,
  so it stays whole. The folder it sits in gives up the room instead:

  ```
  before  ...Sailing.League.2026\Northern.Lakes.Sailing.League.2026.Round.3.Pine.Harbor.Highlights.1080p.WEB.H264-GRP\<file>
  after   ...Sailing.League.2026\Round.3.Pine.Harbor.Highlights.1080p~aa37\<file, unchanged>
  ```

  The part of a folder's name that just repeats its parent folder goes first, then the
  end is cut. The 4-character tag after `~` keeps every name unique.
- **A file is only shortened as a last resort,** when its folders can't make enough
  room - typically a very long name several folders deep. It keeps its extension, and
  files that belong together (`movie.mkv`, `movie.srt`, `movie.nfo`) keep matching names.
- **The normal view on port 8765 is unchanged.** Keep using it for anything on Linux
  or Mac: they have no such limit.

**Using it:**

- **This PC:** once `SHORT_PATHS=1` is in `.env`, the mount scripts use the short view
  by themselves. Run `.\windows\uninstall-autostart.ps1` and then
  `.\windows\install-autostart.ps1` to switch the drive over. Add `-Original` to keep the
  full names on this PC.
- **Other Windows PCs:** use port 8767 in the address, e.g.
  `.\windows\mount.ps1 -Url https://<this-PC's-IP>:8767 -User <user> -Pass <password>`.
  It uses the same certificate, login and guess-throttling as the normal drive.

The limit is `MAX_PATH` in `docker-compose.yml`: 230 characters, counted from the
drive's root, which leaves room for the drive letter or a network name in front.
Lower it if programs still complain. Reading through this view is as fast as the normal one.

### Health report

Lists problems in your source folders: empty folders, RAR sets with parts missing,
RAR parts with no main `.rar`, and folders whose archives couldn't be opened (broken,
incomplete or password-protected). It only reads; nothing is changed.

```powershell
docker exec rar2fs health-report              # everything (can take a while)
docker exec rar2fs health-report tv/tv-1      # one folder
```

You can also start it from the **Run health report** button on the
[status page](#status-page).

A full report also runs by itself every `HEALTH_REPORT_DAYS` days (7 by default; `"0"`
in `docker-compose.yml` turns that off), starting about an hour after the container is
first created. A full report you start yourself counts, so the schedule runs from the
most recent one. The latest result is on the status page, and new problems found by a
scheduled report are sent as a notification if you've set that up.

A set that is only missing its *last* parts can't be spotted from file names, so it
won't be listed.

### Health check

Every minute the container checks that every mount it made still answers - each
folder, each layer underneath it, and the short-names view if that's on - and that the
drive's server responds. `docker ps` shows `(healthy)` or `(unhealthy)` next to it,
and the status page shows which check failed and marks that folder *stopped*. See
[Automatic restart](#automatic-restart) for what happens next.

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

**Plex on Linux** (another machine):

```ini
PLEX_URL=http://192.168.1.20:32400
PLEX_TOKEN=xxxxxxxxxxxxxxxxxxxx
PLEX_PATH_MAP=tv=/mnt/media/tv;films=/mnt/media/films
```

**Plex on this Windows PC** (`Y:` being the rar2fs drive):

```ini
PLEX_URL=http://host.docker.internal:32400
PLEX_TOKEN=xxxxxxxxxxxxxxxxxxxx
PLEX_PATH_MAP=tv=Y:\tv;films=Y:\films
```

Then run `docker compose up -d`.

- `PLEX_URL`: where Plex answers. `host.docker.internal` is how the container reaches
  the PC it runs on; don't use `localhost` here.
- `PLEX_TOKEN`: in Plex Web, open any item → **⋯** → *Get Info* → *View XML*. The
  token is the `X-Plex-Token=...` value at the end of the address bar.
- `PLEX_PATH_MAP`: where each folder is mounted on the Plex server, as
  `<folder on the drive>=<path on the Plex server>`, separated by `;`. Use the same
  paths your Plex libraries use. **Don't put quotes around it** - inside quotes, `\t`
  in `Y:\tv` is read as a tab. `Y:/tv` works too.
- **With `SHORT_PATHS=1`,** Plex on Windows sees shortened folder names, and the
  container asks for those automatically. If you mounted the drive with `-Original`,
  add `PLEX_SHORT_NAMES=0` to `.env` so it asks for the full names instead.

It checks once a minute and waits until a folder has stopped changing, so a new
download reaches Plex about 2-3 minutes after it finishes. `docker logs rar2fs` shows
a `plex-refresh:` line for every scan it requests. Leave `PLEX_TOKEN` empty to turn
this off.

## Settings

Settings live in two files. After changing either, run `docker compose up -d`.

**In `.env`** - yours alone, never committed. Copy `.env.example` to start.

| Setting | What it does | Default |
|---|---|---|
| `WEBDAV_USER`, `WEBDAV_PASS` | The login for the drive and the status page. Required. | - |
| `TLS_HOSTS` | Addresses or names other devices use to reach this PC, for the [HTTPS](#https) certificate | this PC only |
| `TLS` | `0` turns [HTTPS](#https) off | `1` (on) |
| `SHORT_PATHS` | `1` turns on the [short-names view](#short-names-for-windows) | `0` (off) |
| `BIND` | `127.0.0.1` lets [only this PC](#keeping-it-to-this-pc-only) connect | all of your network |
| `NOTIFY_URL` | Where to send [notifications](#notifications) | none |
| `HEARTBEAT_URL` | A URL to ping every minute while healthy - see [Dashboards and monitoring](#dashboards-and-monitoring) | none |
| `STATUS_TOKEN` | A read-only token for `status.json` and `/metrics` | none |
| `PLEX_URL`, `PLEX_TOKEN`, `PLEX_PATH_MAP` | [Tell Plex about new files](#telling-plex-about-new-files-straight-away) | off |
| `PLEX_SHORT_NAMES` | Whether Plex reads the short-names view: `auto`, `1` or `0` | `auto` |
| `NAS_USER`, `NAS_PASS` | Login for network shares, if you use any | - |
| `APPARMOR_PROFILE` | Linux hosts only - see [Security](#security) | `unconfined` |

**In `docker-compose.yml`**, under `environment:`

| Setting | What it does | Default |
|---|---|---|
| `HIDE` | Files and folders to [leave out of the drive](#hiding-clutter) | `.sfv`, samples, recycle bins... |
| `NESTED_RAR` | Open [archives inside archives](#archives-inside-archives-subtitles) | `"1"` (on) |
| `MAX_PATH` | Longest path in the short-names view | `"230"` |
| `AUTO_RESTART` | [Restart](#automatic-restart) after three failed health checks | `"1"` (on) |
| `HEALTH_REPORT_DAYS` | Days between scheduled [health reports](#health-report); `"0"` = never | `"7"` |
| `LOGIN_GUESS_LIMIT` | Wrong logins allowed in 10 seconds before new logins are refused for a while | `"5"` |
| `PLEX_POLL_SECONDS`, `PLEX_SETTLE_SECONDS`, `PLEX_WATCH_DEPTH` | Fine-tuning for the Plex refresh: how often to look, how long to wait after the last change, how many folder levels to watch | `"60"`, `"90"`, `"4"` |
| `RAR2FS_OPTS` | Options passed to rar2fs. The defaults speed up large multi-part sets and pre-read archives at start-up. | `--seek-length=1 -o warmup` |

Your folders go in `docker-compose.override.yml` - see
[Setup, step 1](#1-choose-your-source-folders).

## Keeping it to this PC only

If no other device needs it, put this in `.env` and run `docker compose up -d`:

```ini
BIND=127.0.0.1
```

Other machines can't connect at all after that, and no firewall rule is needed. A
password in `.env` is still required. The setup wizard sets this for you unless you
say other devices will connect.

## Troubleshooting

Start with `.\windows\doctor.ps1` - see [Setup check](#setup-check). It finds most of
the mistakes below by itself and says how to fix them.

- **The drive letter doesn't appear after logging in** - it waits for the container.
  Check that Docker Desktop is running (`docker ps`). Running
  `.\windows\mount.ps1` in a window shows what it's waiting for.
- **The drive is empty or shows an error** - the container stopped after the drive was
  mounted. Check `docker ps`; the drive recovers on its own once the container is up.
- **A newly added folder is empty on the drive** - the drive caches folder listings for
  1 minute. Wait a minute and refresh.
- **"Sorry, there was a problem mounting the file" when opening an ISO** - Windows'
  built-in ISO mounting only works on local disks and normal Windows shares, not on
  this drive. Use [WinCDEmu](https://wincdemu.sysprogs.org/) (free) instead: right-click
  the ISO → *Select drive letter & mount*. 7-Zip and WinRAR can also open ISOs directly.
- **"Path too long", or a file with a long name won't open** - see
  [Short names for Windows](#short-names-for-windows).
- **A source folder is missing** - check `docker logs rar2fs` for its `rar2fs:` line,
  and make sure the path in `docker-compose.override.yml` exists. If the status page shows the
  folder as *stopped*, the container will restart itself within a few minutes to bring
  it back; `docker compose restart` does it straight away.
- **The drive stopped working after changing `TLS`, `TLS_HOSTS` or `SHORT_PATHS`** -
  the login task remembers how it was set up. Run
  `.\windows\uninstall-autostart.ps1` and then `.\windows\install-autostart.ps1` so it
  picks up the new setting.
- **The browser warns that the connection isn't private** - expected: the container
  made its own certificate. Choose *Advanced* → *Proceed*. A new warning appears
  whenever the certificate is recreated, for example after changing `TLS_HOSTS`.
- **Another device says the certificate is invalid or doesn't match** - the address it
  connects to isn't in the certificate. Add it to `TLS_HOSTS` in `.env`, run
  `docker compose up -d`, and give that device the new `tls\cert.pem`.
- **"429 Too Many Requests"** - several wrong passwords were tried in a short time, so
  logins that haven't worked before are refused for a while. Devices already
  connected aren't affected. Check the password and try again after a minute.
- **The status page times out or won't load** - make sure the address starts with
  `https://` (or `http://` if you set `TLS=0`) and ends in `/status.html`. If it
  stops answering, the container restarts it by itself within a couple of minutes.
- **Drive letter already in use** - `mount.ps1` stops with an error; pick another with `-Drive`.
- **Port 8765 already in use** - change the left side of `8765:8080` in
  `docker-compose.yml` and pass the new address with `-Url https://localhost:<port>`.

## Security

- **Your drives are read-only, and stay that way.** FUSE requires the container to have
  the `SYS_ADMIN` capability, which would normally let root inside it remount `:ro`
  folders as writable. To prevent that, nothing in the container runs as root:
  rar2fs, mergerfs and rclone run as an unprivileged user with no capabilities. Only
  the small setuid `fusermount` helpers use `SYS_ADMIN`, and only to create the mounts.
  Every other program in the image that could raise its own privileges (`su`,
  `passwd`, `mount` and so on) has that ability removed.
- **Password required.** The server is open to your local network, so it always
  needs the login from `.env`. Compose refuses to start without one. Traffic is
  encrypted with [HTTPS](#https) unless you turn that off. Either way, don't expose
  the ports to the internet - for access away from home, use a VPN such as Tailscale.
  To shut out other machines entirely, see
  [Keeping it to this PC only](#keeping-it-to-this-pc-only).
- **The status page uses the same logins** as the drive, on port 8766. It shows your
  folder names and source paths, so it's password-protected too. Wrong passwords are
  slowed to about two guesses a second, its one action (starting a health report) is
  only accepted from the page itself, and it can't be embedded in another site.
- **The status token is read-only.** If you set `STATUS_TOKEN`, it can fetch
  `status.json` and `/metrics` and nothing else: not the page, not the report, and
  it can't start anything. It travels in the address, so treat it like a password and
  keep HTTPS on.
- **Password guessing is slowed down** on the drive as well. A login that has worked
  is remembered and always let through. After more than five wrong logins in ten
  seconds, logins that haven't worked before are refused for a while, so devices
  already connected never notice and nobody can be locked out. Still use a long,
  random password: `change-me` in `.env.example` is only a placeholder.
- **AppArmor (Linux hosts).** Docker's default AppArmor profile blocks the FUSE mounts
  this container needs, so it runs with AppArmor "unconfined". If you run it on a
  Linux host that uses AppArmor, you can load the narrower profile in
  `linux/apparmor/rar2fs-dock` instead - it allows FUSE mounts and nothing else that
  Docker's default profile forbids:
  ```bash
  sudo cp linux/apparmor/rar2fs-dock /etc/apparmor.d/rar2fs-dock
  sudo apparmor_parser -r /etc/apparmor.d/rar2fs-dock
  echo 'APPARMOR_PROFILE=rar2fs-dock' >> .env
  docker compose up -d
  ```
  That profile has **not been tested on a real AppArmor host yet**; if the container
  then fails to mount its folders, remove the line from `.env` to go back. Docker
  Desktop on Windows and Mac doesn't use AppArmor at all, so there is nothing to do
  there.
- **Pinned downloads.** The unrar and rar2fs source downloads are checked against
  SHA-256 hashes in the `Dockerfile`. Update the hash whenever you change a version.
- **Keep it updated.** rar2fs uses unrar to read archives, and unrar has had security
  bugs before. The container checks daily for newer releases and tells you on the
  status page (and by notification, if set up); see
  [Updates for unrar and rar2fs](#updates-for-unrar-and-rar2fs). Rebuilding now and
  then with `docker compose build --pull` also picks up Debian's own fixes.

## Why this design

- Windows can't see FUSE mounts made inside Docker Desktop containers, so the view has
  to be served over the network.
- Windows already uses SMB's port 445, so the container can't share it over SMB to
  this machine.
- Windows' built-in WebDAV client limits files to 4 GB and handles large folders
  poorly, so rclone + WinFsp mounts the drive instead. It has no size limit and
  supports seeking within large files.
- rclone serves the files but can't slow down password guessing, so a small HAProxy
  sits in front of it. It also handles HTTPS for the drive.
- The source folders are stacked in layers inside the container (merge → unpack →
  unpack again for archives inside archives → optionally shorten names). Each layer is
  a separate small program, which is why the health check looks at every one.
