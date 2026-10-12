#!/bin/sh
# Checks the rar2fs-dock mounts on this Linux machine and says, in plain words, what is
# wrong and how to fix it. Nothing is changed.
#
#   sudo sh doctor.sh
#
# It looks at: rclone and FUSE, the saved server address and login, whether the server
# answers and its certificate still matches, every mount (enabled, running, really
# mounted, not empty) and - if Plex runs here - Plex's trash setting and whether its
# libraries use the mounts.
# Exit code: 0 if no problems were found, 1 if there were.
#
# (The Windows PC that runs the container has its own: .\rar2fs.ps1 doctor.)
CONF_DIR=${RAR2FS_CONF_DIR:-/etc/rar2fs}                 # the overrides are for testing
UNIT=${RAR2FS_UNIT:-/etc/systemd/system/rar2fs@.service}
here=$(cd "$(dirname "$0")" && pwd)
problems=0; checks=0

ok()   { printf '  ok       %s - %s\n' "$1" "$2"; }
warn() { printf '  CHECK    %s\n           %s\n' "$1" "$2"; checks=$((checks + 1)); }
bad()  { printf '  PROBLEM  %s\n           %s\n' "$1" "$2"; problems=$((problems + 1)); }
finish() {
  echo
  if [ "$problems" -eq 0 ] && [ "$checks" -eq 0 ]; then echo "Everything looks right."
  else echo "$problems problem(s), $checks thing(s) to check."; fi
  [ "$problems" -eq 0 ]; exit $?
}

echo "rar2fs-dock mount check"
echo
[ "$(id -u)" = "0" ] || { bad "Not run as root" "The saved login can only be read by root. Run: sudo sh doctor.sh"; finish; }

# ---- what's needed ----
if command -v rclone >/dev/null; then ok "rclone" "$(rclone version 2>/dev/null | head -1)"
else bad "rclone" "It isn't installed. Run: sudo sh install.sh  (or install rclone with your package manager)"; finish; fi
if command -v fusermount3 >/dev/null || command -v fusermount >/dev/null; then ok "FUSE" "installed"
else bad "FUSE" "fusermount is missing. Install the fuse3 package."; fi

# ---- the mount service ----
if [ ! -f "$UNIT" ]; then
  bad "Mount service" "$UNIT is missing. Run: sudo sh install.sh"
else
  grep -q -- '--allow-other' "$UNIT" || bad "Mount service" "$UNIT has lost --allow-other, so only root can read the mounts and Plex sees nothing. Run: sudo sh install.sh"
  if [ -f "$here/rar2fs@.service" ] && ! cmp -s "$here/rar2fs@.service" "$UNIT"; then
    warn "Mount service" "$UNIT differs from the copy next to this script. If you didn't change it on purpose, run: sudo sh install.sh"
  else
    ok "Mount service" "installed"
  fi
fi

# ---- server address and login ----
if [ ! -f "$CONF_DIR/common.conf" ]; then
  bad "Server settings" "$CONF_DIR/common.conf is missing. Run: sudo sh install.sh"
  finish
fi
mode=$(stat -c %a "$CONF_DIR/common.conf" 2>/dev/null)
case "$mode" in *00) ;; *) warn "Server settings" "$CONF_DIR/common.conf can be read by other users (mode $mode), and it holds the password. Run: sudo chmod 600 $CONF_DIR/common.conf" ;; esac
val() { sed -n "s/^$1=//p" "$CONF_DIR/common.conf" | head -1; }
url=$(val RCLONE_WEBDAV_URL); url=${url%/}
user=$(val RCLONE_WEBDAV_USER); ca=$(val RCLONE_CA_CERT)
if [ -z "$url" ] || [ -z "$user" ] || [ -z "$(val RCLONE_WEBDAV_PASS)" ]; then
  bad "Server settings" "common.conf must set RCLONE_WEBDAV_URL, RCLONE_WEBDAV_USER and RCLONE_WEBDAV_PASS. Run: sudo sh install.sh --url <address>"
  finish
fi
ok "Server settings" "$url, as $user"
server() { ( set -a; . "$CONF_DIR/common.conf"; set +a; rclone "$@" ); }

# ---- does the server answer? ----
reachable=1
if command -v curl >/dev/null; then
  code=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "$url/" 2>/dev/null)
  case "$code" in
    401|200|207) ok "Server" "answers at $url" ;;
    429) warn "Server" "It answers, but is refusing new logins for a while because several wrong passwords were tried. Fix the password, wait a minute, then restart the mounts." ;;
    000) reachable=0
         bad "Server" "Nothing answers at $url. Is the Windows PC on, with Docker Desktop running? Is its firewall rule there (ports 8765-8767), and is this the right address?" ;;
    *)   warn "Server" "It answered with code $code, not the 401 a healthy server gives." ;;
  esac
fi

# ---- the certificate ----
case "$url" in
  https://*)
    hostport=${url#https://}; hostport=${hostport%%/*}
    case "$hostport" in *:*) ;; *) hostport="$hostport:443" ;; esac
    if [ -z "$ca" ] || [ ! -f "$ca" ]; then
      bad "Certificate" "common.conf has no RCLONE_CA_CERT, or that file is missing. Run: sudo sh install.sh --url $url"
    elif [ "$reachable" = 1 ] && command -v openssl >/dev/null; then
      saved=$(openssl x509 -in "$ca" -noout -fingerprint -sha256 2>/dev/null)
      live=$(openssl s_client -connect "$hostport" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
      if [ -n "$live" ] && [ "$saved" != "$live" ]; then
        bad "Certificate" "The server has a new certificate since this machine was set up (it is recreated when TLS_HOSTS changes). Fetch it with: sudo sh install.sh --url $url"
      elif command -v curl >/dev/null && ! curl -s -m 8 --cacert "$ca" -o /dev/null "$url/" 2>/dev/null; then
        bad "Certificate" "It doesn't cover the address ${hostport%:*}. On the Windows PC, add that address to TLS_HOSTS in .env, run docker compose up -d, then here: sudo sh install.sh --url $url"
      else
        ok "Certificate" "matches the server"
      fi
    fi ;;
esac

# ---- the login ----
logged_in=0
if [ "$reachable" = 1 ]; then
  err=$(mktemp)
  if server lsd --contimeout 10s --timeout 30s --retries 1 :webdav: >/dev/null 2>"$err"; then
    logged_in=1; ok "Login" "accepted"
  elif grep -qi '401\|unauthori' "$err"; then
    bad "Login" "The server turned down the user name or password. Run: sudo sh install.sh --url $url   and give the login from the Windows PC's .env"
  else
    bad "Login" "Listing the server failed: $(tail -1 "$err")"
  fi
  rm -f "$err"
fi

# ---- every mount ----
found=0
for f in "$CONF_DIR"/mounts/*.conf; do
  [ -f "$f" ] || continue
  found=1; name=$(basename "$f" .conf)
  remote=$(sed -n 's/^REMOTE=//p' "$f"); mp=$(sed -n 's/^MOUNTPOINT=//p' "$f")
  what="$mp  <-  $remote"
  if [ -z "$remote" ] || [ -z "$mp" ]; then bad "Mount $name" "$f must set REMOTE and MOUNTPOINT."; continue; fi
  fine=1
  if [ "$logged_in" = 1 ] && ! server lsf --max-depth 1 --contimeout 10s --retries 1 ":webdav:$remote" >/dev/null 2>&1; then
    fine=0; bad "$what" "The server has no folder '$remote' (any more). Fix REMOTE in $f, or remove the mount: sudo systemctl disable --now rar2fs@$name"
  fi
  systemctl is-enabled --quiet "rar2fs@$name" 2>/dev/null || { fine=0; warn "$what" "It won't come back after a reboot. Run: sudo systemctl enable rar2fs@$name"; }
  if ! systemctl is-active --quiet "rar2fs@$name" 2>/dev/null; then
    fine=0; bad "$what" "The mount isn't running. Start it with: sudo systemctl start rar2fs@$name   and see why with: journalctl -u rar2fs@$name -e"
  elif [ "$(findmnt -n -o FSTYPE "$mp" 2>/dev/null)" != "fuse.rclone" ]; then
    fine=0; bad "$what" "The service runs, but $mp is not the rar2fs mount: $(findmnt -n -o SOURCE,FSTYPE "$mp" 2>/dev/null || echo nothing) is mounted there."
  elif [ -z "$(ls -A "$mp" 2>/dev/null | head -1)" ]; then
    fine=0; warn "$what" "It is mounted but empty. Check that '$remote' has anything in it on the Windows drive."
  fi
  if grep -v '^[[:space:]]*#' /etc/fstab 2>/dev/null | awk -v m="$mp" '$2 == m { found = 1 } END { exit !found }'; then
    fine=0; warn "$what" "/etc/fstab also mounts something at $mp, and the two will fight over it at boot. Put a # in front of that line."
  fi
  [ "$fine" = 1 ] && ok "$what" "mounted"
done
[ "$found" = 1 ] || warn "Mounts" "None are set up yet. Run: sudo sh install.sh"

# ---- Plex, if it runs here ----
prefs="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
if [ -f "$prefs" ] && command -v curl >/dev/null; then
  token=$(grep -o 'PlexOnlineToken="[^"]*"' "$prefs" | cut -d'"' -f2)
  plex() { printf 'header = "X-Plex-Token: %s"\n' "$token" | curl -s -m 8 -K - "http://127.0.0.1:32400$1" 2>/dev/null; }
  sections=$(plex /library/sections)
  if [ -n "$token" ] && [ -n "$sections" ]; then
    trash=$(plex '/:/prefs' | tr '>' '\n' | grep 'id="autoEmptyTrash"' | grep -o ' value="[^"]*"' | cut -d'"' -f2)
    case "$trash" in
      1|true) bad "Plex" "'Empty trash automatically after every scan' is ON. If the Windows PC is off during a scan, Plex would delete those items and their watch history. Turn it off in Settings > Library." ;;
      0|false) ok "Plex" "automatic trash emptying is off" ;;
    esac
    paths=$(printf '%s' "$sections" | grep -o ' path="[^"]*"' | cut -d'"' -f2)
    for f in "$CONF_DIR"/mounts/*.conf; do
      [ -f "$f" ] || continue
      mp=$(sed -n 's/^MOUNTPOINT=//p' "$f"); mp=${mp%/}
      used=0
      for p in $paths; do
        case "${p%/}/" in "$mp"/*) used=1 ;; esac
        case "$mp/" in "${p%/}"/*) used=1 ;; esac
      done
      [ "$used" = 1 ] || warn "Plex" "No Plex library uses $mp. Add it in Plex: Manage Library > Edit > Add folders."
    done
  fi
fi
finish
