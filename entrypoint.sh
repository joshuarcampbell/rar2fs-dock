#!/bin/sh
# Container start-up. In order:
#   1. Mounts every folder under /sources through rar2fs at /view/<name>.
#      Sources named <name>@<anything> are first merged (mergerfs) into one
#      /view/<name>, e.g. /sources/tv@e + /sources/tv@f -> /view/tv.
#   2. Builds the login list (.env login + config/users.htpasswd).
#   3. Works out which files to hide (HIDE) and sets up HTTPS (unless TLS=0).
#   4. Starts the helpers in the background: status-server (:8081, the status page),
#      monitor (health, auto-restart, update check, scheduled health report)
#      and, if configured, plex-refresh.
#   5. Serves /view read-only over WebDAV as the main process, behind HAProxy
#      (:8080), which handles HTTPS and slows down password guessing.
# The helpers live in scripts/ (installed to /usr/local/bin).
set -e

mounted=""
# every mount made below is listed here; healthcheck and the status page check each one
EXPECTED=/tmp/mounts.expected
: > "$EXPECTED"

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
    mounted="$src $mounted"; echo "$src" >> "$EXPECTED"
  fi

  # NESTED_RAR=1 runs rar2fs twice, so archives inside archives are opened too
  # (e.g. scene subtitles: Subs/x.rar -> x.idx + x.rar -> x.sub)
  if [ "${NESTED_RAR:-1}" = "1" ]; then
    mkdir -p "/pass1/$name"
    rar2fs -o allow_other,ro $RAR2FS_OPTS "$src" "/pass1/$name"
    mounted="/pass1/$name $mounted"; echo "/pass1/$name" >> "$EXPECTED"
    src="/pass1/$name"
  fi

  target="/view/$name"
  mkdir -p "$target"
  echo "rar2fs: $src -> $target"
  rar2fs -o allow_other,ro $RAR2FS_OPTS "$src" "$target"
  mounted="$target $mounted"; echo "$target" >> "$EXPECTED"
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
export HIDE=${HIDE-*.sfv;Thumbs.db;desktop.ini;.DS_Store;@Recycle/**;.qsyncclient/**;Sample/**;Proof/**}
set -f
old_ifs=$IFS; IFS=';'
set --
for pattern in $HIDE; do
  [ -n "$pattern" ] && set -- "$@" --exclude "$pattern"
done
IFS=$old_ifs
set +f

# ---- HTTPS (on unless TLS=0): uses /tls/cert.pem + key.pem, creating a self-signed pair if missing ----
if [ "${TLS:-1}" = "1" ]; then
  hosts="localhost,127.0.0.1${TLS_HOSTS:+,$TLS_HOSTS}"
  if [ ! -s /tls/cert.pem ] || [ ! -s /tls/key.pem ] || [ "$(cat /tls/hosts.txt 2>/dev/null)" != "$hosts" ]; then
    san=$(printf '%s' "$hosts" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep . |
      awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), ($0 ~ /^[0-9.]+$/ || $0 ~ /:/ ? "IP" : "DNS"), $0 }')
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=rar2fs-dock" \
      -addext "subjectAltName=$san" -keyout /tls/key.pem -out /tls/cert.pem 2>/dev/null
    printf '%s' "$hosts" > /tls/hosts.txt
    echo "tls: created a self-signed certificate for $hosts"
  fi
  echo "tls: $(openssl x509 -in /tls/cert.pem -noout -fingerprint -sha256)"
  [ -n "$TLS_HOSTS" ] || echo "tls: the certificate only covers this PC (localhost). For other devices, set TLS_HOSTS in .env to this PC's address or name."
  # HAProxy wants the certificate and key in one file
  ( umask 077; cat /tls/cert.pem /tls/key.pem > /tmp/haproxy.pem )
  bind_opts="ssl crt /tmp/haproxy.pem ssl-min-ver TLSv1.2"
else
  bind_opts=""
fi

# ---- status page (port 8081) and the watchdog that keeps it fresh ----
mkdir -p /state/www
status-page 2>/dev/null || true
status-server &
monitor &

# ---- optional: tell Plex to scan folders as soon as they change ----
if [ -n "$PLEX_URL" ] && [ -n "$PLEX_TOKEN" ]; then
  /usr/local/bin/plex-refresh &
fi

# ---- the drive: HAProxy (:8080) in front of rclone (127.0.0.1:8079) ----
# HAProxy handles HTTPS and slows down password guessing. rclone can't do the second
# itself, so HAProxy watches its answers:
#   - a login that has worked is remembered and always let through
#   - more than LOGIN_GUESS_LIMIT wrong logins in 10 seconds, and further logins that
#     haven't worked before are refused (429) until the guessing stops
# Nobody is locked out: devices already logged in never notice.
cat > /tmp/haproxy.cfg <<HAPROXY
global
    maxconn 512
defaults
    mode http
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout http-request 30s
    timeout http-keep-alive 2m
backend st_bad
    stick-table type string len 8 size 1 expire 2m store gpc0,gpc0_rate(10s)
backend st_good
    stick-table type string len 64 size 1k expire 12h store gpc0
frontend drive
    bind :8080 $bind_opts
    acl has_auth req.hdr(Authorization) -m found
    http-request set-var(txn.auth) req.hdr(Authorization),sha2(256),hex if has_auth
    http-request track-sc0 str(all) table st_bad
    http-request track-sc1 var(txn.auth) table st_good if has_auth
    acl known_good sc1_get_gpc0 gt 0
    acl too_many sc0_gpc0_rate gt ${LOGIN_GUESS_LIMIT:-5}
    http-request deny deny_status 429 if has_auth !known_good too_many
    http-response sc-inc-gpc0(0) if { status 401 } { var(txn.auth) -m found }
    http-response sc-inc-gpc0(1) if { status lt 400 } { var(txn.auth) -m found }
    default_backend rclone
backend rclone
    server rclone 127.0.0.1:8079
HAPROXY
haproxy -c -q -f /tmp/haproxy.cfg || { echo "ERROR: could not start the login throttle (HAProxy configuration)"; exit 1; }
haproxy -f /tmp/haproxy.cfg -db &

exec rclone serve webdav /view --addr 127.0.0.1:8079 --read-only --htpasswd "$HTPASSWD" \
  --dir-cache-time "${DIR_CACHE_TIME:-15s}" --ignore-case "$@" $RCLONE_OPTS
