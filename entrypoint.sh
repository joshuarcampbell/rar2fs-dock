#!/bin/sh
# Mounts every folder under /sources through rar2fs at /view/<name>,
# then serves /view read-only over WebDAV.
#
# Sources named <name>@<anything> are merged (via mergerfs) into a single
# /view/<name>, e.g. /sources/tv@e + /sources/tv@f -> /view/tv.
set -e

mounted=""

cleanup() {
  for m in $mounted; do fusermount -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

names=$(for src in /sources/*/; do [ -d "$src" ] && basename "$src" | cut -d@ -f1; done | sort -u)

for name in $names; do
  members=""
  for src in "/sources/$name" /sources/"$name"@*; do
    [ -d "$src" ] && members="${members:+$members:}$src"
  done

  if [ "$members" = "/sources/$name" ]; then
    src="/sources/$name"
  else
    src="/merged/$name"
    mkdir -p "$src"
    echo "mergerfs: $members -> $src"
    mergerfs -o allow_other,ro,category.search=ff,cache.files=off "$members" "$src"
    mounted="$src $mounted"
  fi

  # NESTED_RAR=1 runs rar2fs twice, so archives inside archives are opened too
  # (e.g. scene subtitles: Subs/x.rar -> x.idx + x.rar -> x.sub)
  if [ "${NESTED_RAR:-1}" = "1" ]; then
    mkdir -p "/pass1/$name"
    rar2fs -o allow_other,ro $RAR2FS_OPTS "$src" "/pass1/$name"
    mounted="/pass1/$name $mounted"
    src="/pass1/$name"
  fi

  target="/view/$name"
  mkdir -p "$target"
  echo "rar2fs: $src -> $target"
  rar2fs -o allow_other,ro $RAR2FS_OPTS "$src" "$target"
  mounted="$target $mounted"
done

[ -n "$mounted" ] || echo "WARNING: nothing found under /sources - add volumes in docker-compose.yml"

# ---- logins: the main one from .env, plus any in config/users.htpasswd ----
HTPASSWD=/tmp/htpasswd
: > "$HTPASSWD"; chmod 600 "$HTPASSWD"
if [ -n "$WEBDAV_USER" ]; then
  printf '%s' "$WEBDAV_PASS" | htpasswd -niB "$WEBDAV_USER" | grep : >> "$HTPASSWD"
fi
if [ -f /config/users.htpasswd ]; then
  tr -d '\r' < /config/users.htpasswd | grep -v '^[[:space:]]*#' | grep : >> "$HTPASSWD" || true
fi
[ -s "$HTPASSWD" ] || { echo "ERROR: no logins - set WEBDAV_USER/WEBDAV_PASS in .env"; exit 1; }
echo "logins: $(cut -d: -f1 "$HTPASSWD" | tr '\n' ' ')"

# ---- hide clutter: HIDE is a ;-separated list of rclone filter patterns ----
HIDE=${HIDE-*.sfv;Thumbs.db;desktop.ini;.DS_Store;@Recycle/**;.qsyncclient/**;Sample/**;Proof/**}
set -f
old_ifs=$IFS; IFS=';'
set --
for pattern in $HIDE; do
  [ -n "$pattern" ] && set -- "$@" --exclude "$pattern"
done
IFS=$old_ifs
set +f

# ---- optional: tell Plex to scan folders as soon as they change ----
if [ -n "$PLEX_URL" ] && [ -n "$PLEX_TOKEN" ]; then
  /usr/local/bin/plex-refresh &
fi

exec rclone serve webdav /view --addr :8080 --read-only --htpasswd "$HTPASSWD" \
  --dir-cache-time "${DIR_CACHE_TIME:-15s}" --ignore-case "$@" $RCLONE_OPTS
