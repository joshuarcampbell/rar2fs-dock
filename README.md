# rar2fs-dock

Runs rar2fs in Docker and exposes the unpacked view to Windows as a mapped drive.

Windows can't see FUSE mounts made inside Docker Desktop containers, and port 445
(SMB) is owned by Windows itself, so the view is served over WebDAV on
`localhost:8080` instead.

## Setup

1. Edit `docker-compose.yml` - add a volume under `/sources/<name>` for each local
   folder or network share (CIFS example included).
2. `docker compose up -d --build`
3. One-time Windows prep (admin PowerShell) - WebDAV caps files at 50 MB by default:
   ```powershell
   Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters FileSizeLimitInBytes 0xFFFFFFFF
   Set-Service WebClient -StartupType Automatic; Restart-Service WebClient
   ```
4. Map the drive:
   ```powershell
   net use R: http://localhost:8080/ /persistent:yes
   ```

`R:\downloads\...` now shows the contents of RAR archives as plain files.

## Notes

- WebDAV on Windows has a hard 4 GB per-file limit. Files larger than that inside
  archives won't open via the drive; use rclone/VLC/etc. directly against
  `http://localhost:8080/` instead.
- Adding/removing sources requires `docker compose up -d` to remount.
- Logs: `docker logs rar2fs`
