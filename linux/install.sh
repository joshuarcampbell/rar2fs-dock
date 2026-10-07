#!/bin/sh
# Sets up rar2fs-dock mounts on a Linux machine (e.g. a Plex server).
#
#   sudo ./install.sh
#
# It asks for the server's address and login, shows the folders the server has, and
# lets you choose where each one is mounted. Run it again any time to add more.
# It never edits /etc/fstab and never mounts over a folder that is in use.
#
# Without prompts (for scripts):
#   sudo ./install.sh --url http://192.168.1.63:8765 --user rar2fs --pass 'secret' \
#        --add tv=/mnt/media/tv --add films=/mnt/media/films
set -e

CONF_DIR=/etc/rar2fs
UNIT=/etc/systemd/system/rar2fs@.service
here=$(cd "$(dirname "$0")" && pwd)

url=""; user=""; pass=""; adds=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url)  url=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --pass) pass=$2; shift 2 ;;
    --add)  adds="$adds
$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask()  { printf '%s' "$1" >&2; read -r reply; printf '%s' "$reply"; }

[ "$(id -u)" = "0" ] || fail "run this with sudo"
[ -f "$here/rar2fs@.service" ] || fail "rar2fs@.service must be in the same folder as this script"
command -v systemctl >/dev/null || fail "this needs systemd (systemctl not found)"

# ---- rclone + FUSE ----
have_fuse=0; { command -v fusermount3 >/dev/null || command -v fusermount >/dev/null; } && have_fuse=1
if ! command -v rclone >/dev/null || [ "$have_fuse" = 0 ]; then
  if command -v apt-get >/dev/null; then
    say "Installing rclone and fuse3..."
    apt-get update -qq && apt-get install -y -qq rclone fuse3 >/dev/null
  else
    fail "install rclone and fuse3 with your package manager, then run this again"
  fi
fi

mkdir -p "$CONF_DIR/mounts"
cp "$here/rar2fs@.service" "$UNIT"
systemctl daemon-reload

# ---- server address and login ----
if [ -f "$CONF_DIR/common.conf" ] && [ -z "$url" ]; then
  say "Using the server settings already in $CONF_DIR/common.conf"
else
  [ -n "$url" ]  || url=$(ask "Server address (e.g. http://192.168.1.63:8765): ")
  [ -n "$user" ] || user=$(ask "User name: ")
  if [ -z "$pass" ]; then
    printf 'Password: ' >&2; stty -echo 2>/dev/null || true; read -r pass; stty echo 2>/dev/null || true; printf '\n' >&2
  fi
  url=${url%/}
  ca_line=""
  case "$url" in
    https://*)
      hostport=${url#https://}; hostport=${hostport%%/*}
      case "$hostport" in *:*) ;; *) hostport="$hostport:443" ;; esac
      command -v openssl >/dev/null || fail "https needs openssl installed"
      openssl s_client -connect "$hostport" </dev/null 2>/dev/null | openssl x509 -outform PEM > "$CONF_DIR/cert.pem.new" \
        || fail "could not read the server's certificate from $hostport"
      say "The server's certificate fingerprint is:"
      say "  $(openssl x509 -in "$CONF_DIR/cert.pem.new" -noout -fingerprint -sha256 | sed 's/.*=//')"
      say "Compare it with the 'tls:' line in 'docker logs rar2fs' on the server."
      if [ -z "$adds" ]; then
        case "$(ask "Trust this certificate? [y/N] ")" in y|Y|yes) ;; *) rm -f "$CONF_DIR/cert.pem.new"; fail "certificate not trusted - nothing changed" ;; esac
      fi
      mv "$CONF_DIR/cert.pem.new" "$CONF_DIR/cert.pem"
      ca_line="RCLONE_CA_CERT=$CONF_DIR/cert.pem"
      ;;
  esac
  umask 077
  {
    echo "RCLONE_WEBDAV_URL=$url"
    echo "RCLONE_WEBDAV_USER=$user"
    echo "RCLONE_WEBDAV_PASS=$(printf '%s' "$pass" | rclone obscure -)"
    [ -n "$ca_line" ] && echo "$ca_line"
  } > "$CONF_DIR/common.conf"
  chmod 600 "$CONF_DIR/common.conf"
fi

# rclone with the server settings loaded
server() { ( set -a; . "$CONF_DIR/common.conf"; set +a; rclone "$@" ); }

say "Connecting to the server..."
err=$(mktemp)
folders=$(server lsf --dirs-only --contimeout 10s --timeout 30s --retries 1 :webdav: 2>"$err") \
  || fail "could not connect: $(tail -1 "$err")
Check the address, the login, and that port 8765 is allowed through the server's firewall."
say "Folders on the server:"
printf '%s\n' "$folders" | sed 's|/$||; s/^/  /'

# ---- one mount ----
add_mount() {  # remote, mountpoint
  remote=${1%/}; mp=${2%/}
  [ -n "$remote" ] && [ -n "$mp" ] || { say "  skipped: need both a folder and a path"; return 1; }
  case "$mp" in /*) ;; *) say "  skipped: $mp is not an absolute path"; return 1 ;; esac
  name=$(printf '%s' "$remote" | tr '/ ' '--' | tr -cd 'A-Za-z0-9._-')

  server lsf --max-depth 1 --contimeout 10s --retries 1 ":webdav:$remote" >/dev/null 2>&1 \
    || { say "  skipped: the server has no folder '$remote'"; return 1; }

  if systemctl is-active --quiet "rar2fs@$name" 2>/dev/null; then
    systemctl stop "rar2fs@$name"
  elif findmnt -n "$mp" >/dev/null 2>&1; then
    say "  skipped: $mp already has something mounted on it:"
    say "    $(findmnt -n -o SOURCE,FSTYPE "$mp")"
    say "    Unmount it first (sudo umount $mp). If it is in /etc/fstab, put a # in front"
    say "    of its line so it doesn't come back at boot. Then run this again."
    return 1
  fi
  if [ -d "$mp" ] && [ -n "$(ls -A "$mp" 2>/dev/null)" ]; then
    say "  skipped: $mp is not empty. Choose an empty folder (or one that doesn't exist yet)."
    return 1
  fi

  printf 'REMOTE=%s\nMOUNTPOINT=%s\n' "$remote" "$mp" > "$CONF_DIR/mounts/$name.conf"
  systemctl enable --now "rar2fs@$name" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "rar2fs@$name"; then
    say "  OK: $remote -> $mp   (service: rar2fs@$name)"
  else
    say "  FAILED to start rar2fs@$name - see: journalctl -u rar2fs@$name -e"
    return 1
  fi
}

# ---- choose mounts ----
if [ -n "$adds" ]; then
  printf '%s\n' "$adds" | while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    add_mount "${pair%%=*}" "${pair#*=}" || true
  done
else
  say ""
  say "Add a mount: type a folder from the list (sub-folders work too, e.g. tv/tv-1),"
  say "then the path it should appear at. Leave the folder empty to finish."
  while :; do
    remote=$(ask "Folder on the server: ")
    [ -n "$remote" ] || break
    mp=$(ask "Mount it at (e.g. /mnt/media/$remote): ")
    add_mount "$remote" "$mp" || true
  done
fi

say ""
say "Mounts now set up:"
found=0
for f in "$CONF_DIR"/mounts/*.conf; do
  [ -f "$f" ] || continue
  found=1; n=$(basename "$f" .conf)
  say "  $(sed -n 's/^MOUNTPOINT=//p' "$f")  <-  $(sed -n 's/^REMOTE=//p' "$f")   [$(systemctl is-active "rar2fs@$n" 2>/dev/null || true)]"
done
[ "$found" = 1 ] || say "  (none)"
say ""
say "For Plex: turn OFF Settings > Library > 'Empty trash automatically after every scan',"
say "then add these paths to your libraries and scan."
