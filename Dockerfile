# ---- build rar2fs + libunrar from source ----
FROM debian:bookworm-slim AS build
ARG UNRAR_VERSION=7.0.9
ARG UNRAR_SHA256=505c13f9e4c54c01546f2e29b2fcc2d7fabc856a060b81e5cdfe6012a9198326
ARG RAR2FS_VERSION=1.29.7
ARG RAR2FS_SHA256=a875d138b7ed7e3353b5de2f0c5ec02ef6a32c310fe3b07886bc95314d7875ba
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libfuse-dev wget ca-certificates
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

# ---- runtime ----
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends fuse libfuse2 mergerfs rclone ca-certificates tini curl jq apache2-utils \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/libunrar.so /usr/lib/
COPY --from=build /usr/local/bin/rar2fs /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /usr/local/bin/

# Everything runs as an unprivileged user. Only the setuid fusermount helper
# uses SYS_ADMIN, so code parsing archives can't remount /sources writable.
RUN chmod +x /entrypoint.sh /usr/local/bin/healthcheck /usr/local/bin/health-report /usr/local/bin/plex-refresh && ldconfig && rar2fs --version \
 && useradd --system --uid 1000 --no-create-home --shell /usr/sbin/nologin rar2fs \
 && chmod u+s /usr/bin/mergerfs-fusermount \
 && echo user_allow_other >> /etc/fuse.conf \
 && mkdir -p /view /merged /pass1 && chown rar2fs:rar2fs /view /merged /pass1
USER rar2fs

HEALTHCHECK --interval=60s --timeout=20s --start-period=60s --retries=3 CMD ["/usr/local/bin/healthcheck"]

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
