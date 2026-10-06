# rar2fs-dock

Browse the contents of RAR archives on Windows as if they were already extracted - no
unpacking, no extra disk space.

[rar2fs](https://github.com/hasse69/rar2fs) runs inside a Docker container and reads
your local folders and network shares. The extracted view is served to Windows and
mounted as a normal drive letter (e.g. `K:`).

```
 D:\Downloads ─┐                    ┌──────── Docker ────────┐
 \nas\media  ─┼─► /sources/<name> ─► rar2fs ─► WebDAV :8765 ─┼─► rclone + WinFsp ─► K:\
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
`K:\<name>`.

**Local folder or drive:**

```yaml
volumes:
  - "D:/Downloads:/sources/downloads:ro"
  - "E:/tv:/sources/tv:ro"
```

Use forward slashes in Windows paths. Docker Desktop must be allowed to access that
drive (Settings → Resources → File sharing, if it asks).

**Several folders merged into one:** give them the same name followed by `@` and any
label. Their contents appear together in one folder:

```yaml
volumes:
  - "E:/tv:/sources/tv@e:ro"
  - "F:/tv:/sources/tv@f:ro"     # E:\tv + F:\tv -> K:\tv
```

This works with network shares too (`- nas:/sources/tv@nas:ro`). If the same file or
folder exists in more than one source, the folders' contents are combined, and for a
file, the first source alphabetically by label wins.

**Network share (SMB/CIFS):** uncomment the `nas` examples and fill in your details:

```yaml
    volumes:
      - nas:/sources/nas:ro

volumes:
  nas:
    driver: local
    driver_opts:
      type: cifs
      device: "//192.168.1.50/media"
      o: "username=USER,password=PASS,vers=3.0,ro,uid=0,gid=0"
```

### 2. Start the container

From this folder:

```powershell
docker compose up -d --build
```

Check that it's working by opening <http://localhost:8765> in a browser - you should
see a folder for each source.

### 3. Mount the drive

**Try it once (stays mounted while the window is open):**

```powershell
.\windows\mount.ps1
```

**Mount automatically at every login (recommended):**

```powershell
.\windows\install-autostart.ps1
```

Both accept `-Drive X:` to use a different letter. `K:` is the default.

If PowerShell refuses to run the scripts, run this first:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

That's it - open `K:\` in Explorer.

## Everyday use

| To... | Run |
|---|---|
| Add or remove a source | Edit `docker-compose.yml`, then `docker compose up -d` |
| See container logs | `docker logs rar2fs` |
| Stop everything | `docker compose down` |
| Remove the auto-mount | `.\windows\uninstall-autostart.ps1` |

The container restarts on its own with Docker Desktop. For a fully hands-off setup,
enable Docker Desktop → Settings → General → *Start Docker Desktop when you sign in*.

## Optional: password protection

The server only listens on `localhost`, so other machines can't reach it. To add a
password anyway, set `WEBDAV_USER` / `WEBDAV_PASS` in `docker-compose.yml` and pass the
same values to the scripts:

```powershell
.\windows\install-autostart.ps1 -User josh -Pass changeme
```

## Troubleshooting

- **The drive is empty or shows an error** - the container isn't running yet. Check
  `docker ps`; the drive recovers on its own once the container is up.
- **A newly added folder is empty on the drive** - the drive caches folder listings for
  1 minute. Wait a minute and refresh.
- **A source folder is missing** - check `docker logs rar2fs` for its `rar2fs:` line,
  and make sure the path in `docker-compose.yml` exists.
- **Drive letter already in use** - `mount.ps1` stops with an error; pick another with `-Drive`.
- **Port 8765 already in use** - change the left side of `127.0.0.1:8765:8080` in
  `docker-compose.yml` and pass the new address with `-Url http://localhost:<port>`.

## Why this design

- Windows can't see FUSE mounts made inside Docker Desktop containers, so the view has
  to be served over the network.
- Windows already uses SMB's port 445, so the container can't share it over SMB to
  this machine.
- Windows' built-in WebDAV client limits files to 4 GB and handles large folders
  poorly, so rclone + WinFsp mounts the drive instead. It has no size limit and
  supports seeking within large files.
