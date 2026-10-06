# ---- build rar2fs + libunrar from source ----
FROM debian:bookworm-slim AS build
ARG UNRAR_VERSION=7.0.9
ARG RAR2FS_VERSION=1.29.7
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libfuse-dev wget ca-certificates
WORKDIR /src
RUN wget -qO- https://www.rarlab.com/rar/unrarsrc-${UNRAR_VERSION}.tar.gz | tar xz \
 && make -C unrar lib && make -C unrar install-lib DESTDIR=/usr
RUN wget -qO- https://github.com/hasse69/rar2fs/archive/refs/tags/v${RAR2FS_VERSION}.tar.gz | tar xz \
 && cd rar2fs-${RAR2FS_VERSION} \
 && autoreconf -f -i \
 && ./configure --with-unrar=/src/unrar --with-unrar-lib=/usr/lib/ \
 && make && make install

# ---- runtime ----
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends fuse libfuse2 rclone ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/libunrar.so /usr/lib/
COPY --from=build /usr/local/bin/rar2fs /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && ldconfig && rar2fs --version

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
