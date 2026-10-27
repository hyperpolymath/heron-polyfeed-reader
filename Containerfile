# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# Build + test + runtime image. Works with podman or docker:
#   podman build -f Containerfile --target test    -t heron-test .   # runs the unit tests
#   podman build -f Containerfile --target runtime -t heron .        # static binary on scratch
# The Zig toolchain is pinned by version and verified by SHA-256 (ADD --checksum).
ARG BASE=docker.io/library/alpine:3
FROM ${BASE} AS toolchain
ARG ZIG_VERSION=0.17.0
ADD --checksum=sha256:1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 \
    https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz /tmp/zig.tar.xz
RUN mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
# An empty, runtime-UID-owned directory to seed /data in the scratch image (see the runtime stage).
RUN mkdir -p /seed/data && chown 10001:10001 /seed/data

FROM toolchain AS test
WORKDIR /src
COPY . .
RUN zig build test --summary all

FROM toolchain AS build
WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

FROM scratch AS runtime
COPY --from=build /src/zig-out/bin/heron /heron
# CA roots for HTTPS (Zig reads /etc/ssl/certs/ca-certificates.crt).
COPY --from=toolchain /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# /data must exist in the image, owned by the runtime UID: an anonymous or fresh named volume
# inherits this directory's ownership, whereas a mount point the engine creates itself is root's
# and heron (UID 10001) could not create its log, index or lock file there.
COPY --from=toolchain --chown=10001:10001 /seed/data /data
USER 10001:10001
ENV HERON_DATA=/data HERON_CONFIG=/config/heron.json
VOLUME ["/data"]
# The web UI binds 127.0.0.1 by default. Inside a container that is unreachable from the host;
# set "web": {"bind": "0.0.0.0", "allow_non_loopback": true} only together with `-p 127.0.0.1:8484:8484` on the host side.
ENTRYPOINT ["/heron"]
CMD ["daemon"]
