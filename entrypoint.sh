#!/bin/sh
# Mounts every folder under /sources through rar2fs at /view/<name>,
# then serves /view read-only over WebDAV.
set -e

mkdir -p /view
mounted=""

cleanup() {
  for m in $mounted; do fusermount -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

for src in /sources/*/; do
  [ -d "$src" ] || continue
  name=$(basename "$src")
  target="/view/$name"
  mkdir -p "$target"
  echo "rar2fs: $src -> $target"
  rar2fs -o allow_other,ro $RAR2FS_OPTS "$src" "$target"
  mounted="$mounted $target"
done

[ -n "$mounted" ] || echo "WARNING: nothing found under /sources - add volumes in docker-compose.yml"

AUTH=""
[ -n "$WEBDAV_USER" ] && AUTH="--user $WEBDAV_USER --pass $WEBDAV_PASS"

exec rclone serve webdav /view --addr :8080 --read-only $AUTH $RCLONE_OPTS
