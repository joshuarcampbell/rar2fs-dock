#!/bin/sh
# Sets up rar2fs-dock on a Linux machine from start to finish - the Linux counterpart of
# windows\setup.ps1. Use it when the archives are on (or mounted on) this machine and
# it should run the container itself.
#
#   sudo sh linux/setup.sh
#
#   1. checks Docker, Docker Compose and FUSE
#   2. asks which folders to share and writes docker-compose.override.yml
#   3. writes .env with a random password
#   4. builds and starts the container
#   5. offers to open the firewall for other devices
#   6. offers to mount the unpacked folders on this machine too (for Plex, Jellyfin or
#      Emby running here), using install.sh
#
# It never overwrites an existing .env or docker-compose.override.yml (use --force for
# the folder list), so it is safe to run again.
#
# Without questions:
#   sudo sh linux/setup.sh --yes --folder /srv/media/films=films --folder /srv/media/tv=tv \
#        --network --mount-at /mnt/rar2fs
#
# Options:
#   --folder PATH=NAME   a folder to share, and its name on the drive (repeat as needed);
#                        the same name twice merges those folders into one
#   --subfolders         folders sharing a name become name/name-1, name/name-2 instead
#   --network            other devices will connect (default: this machine only)
#   --short-paths        add the short-names view, for Windows PCs that will connect
#   --mount-at DIR       mount the unpacked folders under DIR on this machine
#   --no-mount           don't mount them here
#   --no-start           write the files only; don't start the container
#   --force              replace an existing docker-compose.override.yml
#   --yes                accept the defaults instead of asking
set -e

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
env_file="$repo/.env"
override="$repo/docker-compose.override.yml"
NAME=${RAR2FS_CONTAINER:-rar2fs}        # these two overrides are for testing
PORT=${RAR2FS_PORT:-8765}
CONTAINER_UID=1000                      # the user everything in the container runs as

folders=$(mktemp); trap 'rm -f "$folders"' EXIT
yes=0; network=0; short=0; subfolders=0; force=0; start=1; mount=ask; mount_at=""
while [ $# -gt 0 ]; do
  case "$1" in
    --folder)      printf '%s\n' "$2" >> "$folders"; shift 2 ;;
    --subfolders)  subfolders=1; shift ;;
    --network)     network=1; shift ;;
    --short-paths) short=1; shift ;;
    --mount-at)    mount=yes; mount_at=$2; shift 2 ;;
    --no-mount)    mount=no; shift ;;
    --no-start)    start=0; shift ;;
    --force)       force=1; shift ;;
    --yes|-y)      yes=1; shift ;;
    -h|--help)     sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
stop() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
ask()  {  # question, default
  [ "$yes" = 1 ] && { printf '%s' "$2"; return; }
  printf '   %s%s: ' "$1" "${2:+ [$2]}" >&2; read -r reply
  printf '%s' "${reply:-$2}"
}
ask_yes() {  # question, default (y or n)
  [ "$yes" = 1 ] && { [ "$2" = y ]; return; }
  if [ "$2" = y ]; then hint="Y/n"; else hint="y/N"; fi
  printf '   %s [%s]: ' "$1" "$hint" >&2; read -r reply
  case "${reply:-$2}" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}
safe_name() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9._-][^a-z0-9._-]*/-/g; s/^[-.]*//; s/[-.]*$//'; }
# can the container's user read this folder?
readable() {
  if setpriv --reuid "$CONTAINER_UID" --regid "$CONTAINER_UID" --clear-groups true 2>/dev/null; then
    setpriv --reuid "$CONTAINER_UID" --regid "$CONTAINER_UID" --clear-groups sh -c 'ls "$1" >/dev/null 2>&1' sh "$1"
  else
    return 0        # can't tell on this system; the setup check in the container will say
  fi
}
owner=${SUDO_USER:-}          # files this writes are handed to the person who ran sudo

[ "$(id -u)" = "0" ] || stop "Run this with sudo:  sudo sh linux/setup.sh"

# ---------------------------------------------------------------- 1. what's needed
step "Checking what's needed"
if [ "$start" = 1 ]; then
  command -v docker >/dev/null 2>&1 || stop "Docker is not installed. Install Docker Engine (https://docs.docker.com/engine/install/), then run this again."
  docker version >/dev/null 2>&1 || stop "Docker is installed but not running. Start it (sudo systemctl start docker), then run this again."
  docker compose version >/dev/null 2>&1 || stop "The Docker Compose plugin is missing ('docker compose' doesn't work). Install it (the docker-compose-plugin package from Docker's repository), then run this again."
  note "Docker and Docker Compose are ready."
  if [ ! -e /dev/fuse ]; then
    modprobe fuse 2>/dev/null || true
    [ -e /dev/fuse ] || stop "/dev/fuse is missing and the fuse module wouldn't load. Install FUSE (the fuse3 package), then run this again."
  fi
  note "FUSE is available."
fi
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  note "NOTE: SELinux is enforcing. If the container can't read your folders, add ,z to the end of"
  note "their lines in docker-compose.override.yml (':ro,z'), then: docker compose up -d"
fi

# ---------------------------------------------------------------- 2. folders
write_override=1
if [ -f "$override" ] && [ "$force" = 0 ]; then
  step "Folders"
  note "Keeping your existing docker-compose.override.yml (use --force to replace it)."
  write_override=0
fi
if [ "$write_override" = 1 ]; then
  step "Which folders should appear on the drive?"
  if [ ! -s "$folders" ]; then
    [ "$yes" = 1 ] && stop "With --yes, say which folders to share: --folder /srv/media/films=films"
    note "Type a folder that holds your media, for example /srv/media/films. A NAS share that is"
    note "mounted on this machine works too. Press Enter on an empty line when you have added them all."
    while :; do
      path=$(ask "Folder" "")
      if [ -z "$path" ]; then
        [ -s "$folders" ] && break
        note "Add at least one folder."; continue
      fi
      path=${path%/}; [ -n "$path" ] || path=/
      [ -d "$path" ] || { note "'$path' is not a folder that exists."; continue; }
      name=$(safe_name "$(ask "Name it should have on the drive" "$(safe_name "$(basename "$path")")")")
      [ -n "$name" ] || name=media
      printf '%s=%s\n' "$path" "$name" >> "$folders"
      note "added: $path  ->  $name"
    done
  fi

  # check each one, and tidy the names
  list=$(mktemp)
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    path=${pair%=*}; name=${pair##*=}
    case "$pair" in *=*) ;; *) name=$(basename "$path") ;; esac
    path=${path%/}; [ -n "$path" ] || path=/
    case "$path" in /*) ;; *) stop "'$path' must be a full path, starting with /" ;; esac
    [ -d "$path" ] || stop "'$path' is not a folder that exists."
    case "$path" in *:*|*'"'*) stop "'$path' contains a character (: or \") that Docker's folder list can't take." ;; esac
    name=$(safe_name "$name"); [ -n "$name" ] || name=media
    printf '%s\t%s\n' "$name" "$path" >> "$list"
    if ! readable "$path"; then
      note "NOTE: the container's user (id $CONTAINER_UID) can't read $path, so it will look empty."
      note "      Let everyone read it:        sudo chmod -R o+rX '$path'"
      note "      or only the container:       sudo setfacl -R -m u:$CONTAINER_UID:rX '$path'"
    fi
  done < "$folders"

  # folders that share a name: one merged folder, or side by side?
  shared=$(cut -f1 "$list" | sort | uniq -d | tr '\n' ' ')
  if [ -n "$shared" ] && [ "$subfolders" = 0 ] && [ "$yes" = 0 ]; then
    note ""
    note "These names are used by more than one folder: $shared"
    note "  merge       - their contents appear together in one folder"
    note "  subfolders  - each keeps its own folder inside, e.g. films/films-1, films/films-2"
    case "$(ask "Merge them, or keep them as subfolders? (merge/subfolders)" "merge")" in s*) subfolders=1 ;; esac
  fi

  {
    echo "# Your media folders - written by linux/setup.sh. Docker merges this file with"
    echo "# docker-compose.yml automatically, and it is gitignored. Edit it freely (see"
    echo "# docker-compose.override.example.yml for the formats), then: docker compose up -d"
    echo "services:"
    echo "  rar2fs:"
    echo "    volumes:"
    sort "$list" | awk -F '\t' -v side="$subfolders" '
      { count[$1]++; names[NR] = $1; paths[NR] = $2 }
      END {
        for (i = 1; i <= NR; i++) {
          n = names[i]; seen[n]++
          if (count[n] == 1)  { target = "/sources/" n;                    shown = n }
          else if (side == 1) { target = "/sources/" n "/" n "-" seen[n];  shown = n "/" n "-" seen[n] }
          else                { target = "/sources/" n "@" seen[n];        shown = n " (merged)" }
          printf "      - \"%s:%s:ro\"    # ->  %s\n", paths[i], target, shown
        }
      }'
  } > "$override"
  [ -n "$owner" ] && chown "$owner" "$override" 2>/dev/null || true
  note "Wrote docker-compose.override.yml with $(grep -c . "$list") folder(s)."
  rm -f "$list"
fi

# ---------------------------------------------------------------- 3. settings
step "Settings"
if [ -f "$env_file" ]; then
  note "Keeping your existing .env."
else
  [ "$network" = 1 ] || { ask_yes "Will other devices on your network connect to it (a media server on another machine, a Windows PC)?" n && network=1 || true; }
  [ "$short" = 1 ] || [ "$network" = 0 ] || { ask_yes "Will Windows PCs open the drive? (adds a view with over-long names shortened for them)" n && short=1 || true; }
  password=$(head -c 24 /dev/urandom | base64 | tr -d '+/=\n' | cut -c1-24)
  {
    echo "# Written by linux/setup.sh. See .env.example and the README (\"Settings\") for"
    echo "# everything that can go here. After a change: docker compose up -d"
    echo
    echo "# The login for the drive and the status page"
    echo "WEBDAV_USER=rar2fs"
    echo "WEBDAV_PASS=$password"
    if [ "$short" = 1 ]; then
      echo; echo "# Show shortened folder names where a path would be too long for Windows"; echo "SHORT_PATHS=1"
    fi
    if [ "$network" = 1 ]; then
      addresses=$( { hostname -I 2>/dev/null || hostname -i 2>/dev/null || true; } | tr ' ' '\n' | grep -v '^127\.' | grep -v ':' | grep . | head -4 | tr '\n' ',' | sed 's/,$//')
      host=$(hostname 2>/dev/null || true)
      echo; echo "# Addresses and names other devices use to reach this machine - they go in the HTTPS certificate"
      echo "TLS_HOSTS=${addresses}${addresses:+${host:+,}}${host}"
    else
      echo; echo "# Only this machine can connect. Remove this line to let other devices in (see README)."
      echo "BIND=127.0.0.1"
    fi
  } > "$env_file"
  chmod 600 "$env_file"
  [ -n "$owner" ] && chown "$owner" "$env_file" 2>/dev/null || true
  note "Wrote .env with a random password."
fi
# The container's user keeps the HTTPS certificate in tls/ and reads extra logins from
# config/, so it has to be able to write the one and read the other.
mkdir -p "$repo/tls" "$repo/config"
chown "$CONTAINER_UID:$CONTAINER_UID" "$repo/tls"
chmod a+rX "$repo/config"; chmod a+r "$repo/config"/* 2>/dev/null || true

if [ "$start" = 0 ]; then
  step "Done (files only)"
  note "Start it with: sudo docker compose up -d --build"
  exit 0
fi

# ---------------------------------------------------------------- 4. start
step "Building and starting the container (the first build takes several minutes)"
( cd "$repo" && docker compose up -d --build ) || stop "Docker could not start the container - see the messages above."
note "Waiting for it to report healthy..."
state=""; tries=0
while [ "$tries" -lt 60 ]; do
  state=$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || true)
  [ "$state" = "healthy" ] && break
  sleep 5; tries=$((tries + 1))
done
[ "$state" = "healthy" ] || stop "The container started but isn't healthy yet ($state). Look at: sudo docker logs $NAME"
note "The container is healthy."
docker exec "$NAME" doctor 2>/dev/null | awk -F '\t' '$1 != "ok" { printf "   NOTE: %s - %s\n", $2, $3 }'

val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$env_file" | head -1; }
user=$(val WEBDAV_USER); pass=$(val WEBDAV_PASS)
if [ "$(val TLS)" = "0" ]; then scheme=http; else scheme=https; fi
open_to_network=1; [ "$(val BIND)" = "127.0.0.1" ] && open_to_network=0

# ---------------------------------------------------------------- 5. firewall
if [ "$open_to_network" = 1 ]; then
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    step "Firewall"
    if ask_yes "The ufw firewall is on. Let other devices reach ports 8765-8767?" y; then
      ufw allow 8765:8767/tcp >/dev/null && note "Opened ports 8765-8767."
    else
      note "Left closed. To open them later: sudo ufw allow 8765:8767/tcp"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    step "Firewall"
    if ask_yes "firewalld is on. Let other devices reach ports 8765-8767?" y; then
      firewall-cmd --permanent --add-port=8765-8767/tcp >/dev/null && firewall-cmd --reload >/dev/null && note "Opened ports 8765-8767."
    else
      note "Left closed. To open them later: sudo firewall-cmd --permanent --add-port=8765-8767/tcp && sudo firewall-cmd --reload"
    fi
  fi
fi

# ---------------------------------------------------------------- 6. mount here
mounted_at=""
if [ "$mount" = ask ]; then
  if command -v systemctl >/dev/null 2>&1; then
    step "Using the files on this machine"
    note "The unpacked folders can be mounted here as ordinary folders, for a media server"
    note "running on this machine (or anything else that should read them)."
    if ask_yes "Mount them on this machine?" y; then mount=yes; else mount=no; fi
  else
    mount=no
  fi
fi
if [ "$mount" = yes ]; then
  [ -n "$mount_at" ] || mount_at=$(ask "Mount them under" "/mnt/rar2fs")
  mount_at=${mount_at%/}
  set --
  for name in $(docker exec "$NAME" cut -f1 /tmp/folders.state 2>/dev/null); do
    set -- "$@" --add "$name=$mount_at/$name"
  done
  if [ $# -eq 0 ]; then
    note "The container isn't sharing any folders, so there is nothing to mount."
  elif sh "$here/install.sh" --url "$scheme://localhost:$PORT" --user "$user" --pass "$pass" "$@"; then
    mounted_at=$mount_at
  else
    note "Mounting didn't finish - see above. Try again later with: sudo sh linux/install.sh"
  fi
fi

# ---------------------------------------------------------------- summary
address=$(val TLS_HOSTS | cut -d, -f1); [ -n "$address" ] || address=localhost
step "All set"
[ -n "$mounted_at" ] && note "Your files:     $mounted_at/<folder>      (point your media server's libraries here)"
note "Status page:    $scheme://localhost:$((PORT + 1))/status.html     (health, folders, what is in use)"
note "Login:          $user  /  the WEBDAV_PASS value in .env"
[ "$scheme" = https ] && note "                (a browser will warn about the certificate once - that's expected)"
if [ "$open_to_network" = 1 ]; then
  note "Other devices:  $scheme://$address:$PORT     (see the README, 'Using it from other machines')"
fi
note ""
note "Media server on this machine? In its settings turn OFF 'empty trash automatically after"
note "every scan' first. To have it told about new files at once, see the README, 'Telling your"
note "media server about new files' - its address from inside the container is"
note "http://host.docker.internal:<port>."
note ""
note "Change the folders:   edit docker-compose.override.yml, then: sudo docker compose up -d"
note "Update:               git pull && sudo docker compose up -d --build"
note "If something is wrong: sudo docker exec $NAME doctor --full     and, for the mounts: sudo sh linux/doctor.sh"
