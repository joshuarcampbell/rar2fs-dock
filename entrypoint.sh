#!/bin/sh
# Mounts every folder under /sources through rar2fs at /view/<name>,
# then serves /view read-only over WebDAV.
#
# Sources named <name>@<anything> are merged (via mergerfs) into a single
# /view/<name>, e.g. /sources/tv@e + /sources/tv@f -> /view/tv.
set -e

mkdir -p /view /merged
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

  target="/view/$name"
  mkdir -p "$target"
  echo "rar2fs: $src -> $target"
  rar2fs -o allow_other,ro $RAR2FS_OPTS "$src" "$target"
  mounted="$target $mounted"
done

[ -n "$mounted" ] || echo "WARNING: nothing found under /sources - add volumes in docker-compose.yml"

AUTH=""
[ -n "$WEBDAV_USER" ] && AUTH="--user $WEBDAV_USER --pass $WEBDAV_PASS"

exec rclone serve webdav /view --addr :8080 --read-only $AUTH $RCLONE_OPTS
