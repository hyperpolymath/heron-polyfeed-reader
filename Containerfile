# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# Build + test + runtime image. Works with podman or docker:
#   podman build --target test  -t sfr-test .     # runs the unit tests
#   podman build --target runtime -t sfr .        # static binary, scratch image
FROM docker.io/library/debian:stable-slim AS toolchain
ARG ZIG_VERSION=0.17.0
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir /opt/zig && tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH

FROM toolchain AS test
WORKDIR /src
COPY . .
RUN zig build test --summary all

FROM toolchain AS build
WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

FROM scratch AS runtime
COPY --from=build /src/zig-out/bin/sfr /sfr
COPY --from=toolchain /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 10001:10001
ENV SFR_DATA=/data SFR_CONFIG=/config/sfr.json
VOLUME ["/data"]
# Web UI binds 127.0.0.1 inside the container; publish with -p 127.0.0.1:8484:8484 and
# set "web_bind":"0.0.0.0" in the config only when the host publish is loopback-only.
ENTRYPOINT ["/sfr"]
CMD ["daemon"]
