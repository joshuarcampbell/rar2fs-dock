#!/bin/sh
# Container start-up. In order:
#   1. Mounts every folder through rar2fs at /view/<name> (see scripts/mount-folders).
#      Folders sharing a name are first merged (mergerfs) into one.
#   2. Builds the login list (.env login + config/users.htpasswd).
#   3. Works out which files to hide (HIDE) and sets up HTTPS (unless TLS=0).
#   4. Starts the helpers in the background: status-server (:8081, the status page),
#      monitor (health, auto-restart, update check, scheduled health report)
#      and, if configured, plex-refresh.
#   5. Serves /view read-only over WebDAV as the main process, behind HAProxy
#      (:8080), which handles HTTPS and slows down password guessing.
# The helpers live in scripts/ (installed to /usr/local/bin).
set -e

# ---- folders: everything under /sources, plus config/folders.conf ----
# mount-folders does the work, so the same code can add or remove a folder later
# ("mount-folders reload") without restarting the container.
EXPECTED=/tmp/mounts.expected
# Tidies up if start-up stops part-way. Once the last line hands over to rclone (exec)
# this no longer applies; when the container ends, its mounts end with it.
trap 'mount-folders stop' EXIT INT TERM
mount-folders start < /dev/null

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

# ---- optional: a second view where over-long paths are shortened (for Windows) ----
# Served by its own rclone (127.0.0.1:8078), behind the same HAProxy as the normal drive.
short_bind=""; short_use=""; short_backend=""
if [ "${SHORT_PATHS:-0}" = "1" ]; then
  shortfs /view /short --max-path "${MAX_PATH:-230}" &
  tries=0
  until mountpoint -q /short || [ "$tries" -ge 20 ]; do sleep 0.5; tries=$((tries + 1)); done
  if mountpoint -q /short; then
    echo "/short" >> "$EXPECTED"
    echo "shortfs: /view -> /short (paths up to ${MAX_PATH:-230} characters)"
    rclone serve webdav /short --addr 127.0.0.1:8078 --read-only --htpasswd "$HTPASSWD" \
      --dir-cache-time "${DIR_CACHE_TIME:-15s}" --ignore-case "$@" $RCLONE_OPTS &
    short_bind="bind :8082 $bind_opts"
    short_use="use_backend rclone_short if { dst_port 8082 }"
    short_backend="backend rclone_short
    server rclone_short 127.0.0.1:8078"
  else
    echo "ERROR: the short-names view failed to start; the normal drive is unaffected"
  fi
fi

# ---- the drive: HAProxy (:8080, and :8082 for the short-names view) in front of rclone ----
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
    $short_bind
    acl has_auth req.hdr(Authorization) -m found
    http-request set-var(txn.auth) req.hdr(Authorization),sha2(256),hex if has_auth
    http-request track-sc0 str(all) table st_bad
    http-request track-sc1 var(txn.auth) table st_good if has_auth
    acl known_good sc1_get_gpc0 gt 0
    acl too_many sc0_gpc0_rate gt ${LOGIN_GUESS_LIMIT:-5}
    http-request deny deny_status 429 if has_auth !known_good too_many
    http-response sc-inc-gpc0(0) if { status 401 } { var(txn.auth) -m found }
    http-response sc-inc-gpc0(1) if { status lt 400 } { var(txn.auth) -m found }
    $short_use
    default_backend rclone
backend rclone
    server rclone 127.0.0.1:8079
$short_backend
HAPROXY
haproxy -c -q -f /tmp/haproxy.cfg || { echo "ERROR: could not start the login throttle (HAProxy configuration)"; exit 1; }
haproxy -f /tmp/haproxy.cfg -db &

exec rclone serve webdav /view --addr 127.0.0.1:8079 --read-only --htpasswd "$HTPASSWD" \
  --dir-cache-time "${DIR_CACHE_TIME:-15s}" --ignore-case "$@" $RCLONE_OPTS
