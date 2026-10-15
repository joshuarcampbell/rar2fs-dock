# Versions are set once here. When you change one, update its SHA-256 below too.
ARG UNRAR_VERSION=7.3.1
ARG RAR2FS_VERSION=1.29.7
ARG RCLONE_VERSION=1.75.2

# ---- build rar2fs + libunrar from source, and fetch rclone ----
FROM debian:trixie-slim AS build
ARG UNRAR_VERSION
ARG UNRAR_SHA256=634900842a3737d9cc15bbcc71d4c74cc713437e0bca296a573424fe5f2660ab
ARG RAR2FS_VERSION
ARG RAR2FS_SHA256=a875d138b7ed7e3353b5de2f0c5ec02ef6a32c310fe3b07886bc95314d7875ba
ARG RCLONE_VERSION
# rclone publishes one download per kind of processor; these are their checksums,
# from https://downloads.rclone.org/v<version>/SHA256SUMS
ARG RCLONE_SHA256_AMD64=349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702
ARG RCLONE_SHA256_ARM64=7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libfuse-dev wget ca-certificates unzip
WORKDIR /src
# Downloads are pinned by SHA-256; bump the hash together with the version.
RUN wget -qO unrar.tgz https://www.rarlab.com/rar/unrarsrc-${UNRAR_VERSION}.tar.gz \
 && echo "${UNRAR_SHA256}  unrar.tgz" | sha256sum -c - \
 && tar xzf unrar.tgz \
 && make -C unrar lib && make -C unrar install-lib DESTDIR=/usr
RUN wget -qO rar2fs.tgz https://github.com/hasse69/rar2fs/archive/refs/tags/v${RAR2FS_VERSION}.tar.gz \
 && echo "${RAR2FS_SHA256}  rar2fs.tgz" | sha256sum -c - \
 && tar xzf rar2fs.tgz \
 && cd rar2fs-${RAR2FS_VERSION} \
 && autoreconf -f -i \
 && ./configure --with-unrar=/src/unrar --with-unrar-lib=/usr/lib/ \
 && make && make install
# rclone straight from its makers rather than from Debian: Debian's copy is years old
# and was built with a version of Go that has many known security bugs.
RUN arch=${TARGETARCH:-amd64} \
 && case "$arch" in \
      amd64) sum=${RCLONE_SHA256_AMD64} ;; \
      arm64) sum=${RCLONE_SHA256_ARM64} ;; \
      *) echo "no rclone checksum here for $arch - add one above" >&2; exit 1 ;; \
    esac \
 && wget -qO rclone.zip https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-${arch}.zip \
 && echo "${sum}  rclone.zip" | sha256sum -c - \
 && unzip -q -j rclone.zip "*/rclone" -d /usr/local/bin && chmod 755 /usr/local/bin/rclone

# ---- runtime ----
FROM debian:trixie-slim
# Recorded so the container can tell you when newer releases exist
ARG UNRAR_VERSION
ARG RAR2FS_VERSION
ARG RCLONE_VERSION
# (not "RCLONE_VERSION": rclone reads every RCLONE_... variable as one of its own options)
ENV UNRAR_VERSION=${UNRAR_VERSION} RAR2FS_VERSION=${RAR2FS_VERSION} VERSION_RCLONE=${RCLONE_VERSION}
# "upgrade" picks up Debian's security fixes that are newer than the base image.
# Kept small on purpose - every package here is one more thing to keep patched:
#   fuse3, libfuse2t64   the mount helper and the library rar2fs and shortfs use
#   mergerfs             merges folders that share a name
#   haproxy              HTTPS and the login throttle in front of rclone
#   python3 (+fusepy, bcrypt)   status-server, shortfs, activity, and checking logins
#   curl, jq, openssl, tini, ca-certificates   used by the scripts
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends fuse3 libfuse2t64 mergerfs ca-certificates tini curl jq openssl python3 python3-fusepy python3-bcrypt haproxy \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/libunrar.so /usr/lib/
COPY --from=build /usr/local/bin/rar2fs /usr/local/bin/rclone /usr/local/bin/
COPY VERSION /etc/rar2fs-dock-version
COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /usr/local/bin/

# The working folders are open to any user (mode 1777, like /tmp), because the container
# can be told to run as another unprivileged user than the default - PUID / PGID in
# .env, for Linux hosts where your files belong to someone other than user 1000.
#
# For the same reason the list of users (/etc/passwd) can be added to: fusermount refuses
# to work for a user id that has no name, so the entrypoint gives that user one. Nothing
# can be gained by editing the list, because no program that could act on it (su, login,
# passwd ...) keeps its privileges - see below.
#
# Everything runs as an unprivileged user. Only the setuid fusermount helpers
# use SYS_ADMIN, so code parsing archives can't remount /sources writable.
# Every other setuid/setgid program (su, passwd, mount ...) has that bit removed.
# (fusermount is a link to fusermount3 here; mergerfs brings its own.)
RUN chmod +x /entrypoint.sh /usr/local/bin/* && ldconfig && rar2fs --version && rclone version | head -1 \
 && useradd --system --uid 1000 --no-create-home --shell /usr/sbin/nologin rar2fs \
 && chmod u+s /usr/bin/mergerfs-fusermount \
 && find / -xdev -type f -perm /6000 ! -name fusermount ! -name fusermount3 ! -name mergerfs-fusermount -exec chmod a-s {} + \
 && command -v fusermount > /dev/null \
 && echo user_allow_other >> /etc/fuse.conf \
 && chmod 666 /etc/passwd \
 && mkdir -p /view /merged /pass1 /short /state /tls && chown rar2fs:rar2fs /view /merged /pass1 /short /state /tls \
 && chmod 1777 /view /merged /pass1 /short /state /tls
USER rar2fs

HEALTHCHECK --interval=60s --timeout=20s --start-period=60s --retries=3 CMD ["/usr/local/bin/healthcheck"]

EXPOSE 8080 8081 8082
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
