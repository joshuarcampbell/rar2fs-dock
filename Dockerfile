# Versions are set once here. When you change one, update its SHA-256 below too.
ARG UNRAR_VERSION=7.3.1
ARG RAR2FS_VERSION=1.29.7

# ---- build rar2fs + libunrar from source ----
FROM debian:bookworm-slim AS build
ARG UNRAR_VERSION
ARG UNRAR_SHA256=634900842a3737d9cc15bbcc71d4c74cc713437e0bca296a573424fe5f2660ab
ARG RAR2FS_VERSION
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
# Recorded so the container can tell you when newer releases exist
ARG UNRAR_VERSION
ARG RAR2FS_VERSION
ENV UNRAR_VERSION=${UNRAR_VERSION} RAR2FS_VERSION=${RAR2FS_VERSION}
RUN apt-get update \
 && apt-get install -y --no-install-recommends fuse libfuse2 mergerfs rclone ca-certificates tini curl jq apache2-utils openssl python3 haproxy \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/libunrar.so /usr/lib/
COPY --from=build /usr/local/bin/rar2fs /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /usr/local/bin/

# Everything runs as an unprivileged user. Only the setuid fusermount helpers
# use SYS_ADMIN, so code parsing archives can't remount /sources writable.
# Every other setuid/setgid program (su, passwd, mount ...) has that bit removed.
RUN chmod +x /entrypoint.sh /usr/local/bin/* && ldconfig && rar2fs --version \
 && useradd --system --uid 1000 --no-create-home --shell /usr/sbin/nologin rar2fs \
 && chmod u+s /usr/bin/mergerfs-fusermount \
 && find / -xdev -type f -perm /6000 ! -name fusermount ! -name mergerfs-fusermount -exec chmod a-s {} + \
 && echo user_allow_other >> /etc/fuse.conf \
 && mkdir -p /view /merged /pass1 /state /tls && chown rar2fs:rar2fs /view /merged /pass1 /state /tls
USER rar2fs

HEALTHCHECK --interval=60s --timeout=20s --start-period=60s --retries=3 CMD ["/usr/local/bin/healthcheck"]

EXPOSE 8080 8081
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
