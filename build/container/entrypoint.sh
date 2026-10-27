#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# heron-polyfeed-reader container entrypoint (build/container/Containerfile, Tier-A image).
#
# Logs the effective configuration, warns early when the data directory is not writable, then
# execs heron so it is PID 1 and receives the engine's stop signals directly.

set -e

echo "Starting heron..."
echo "  Config: ${HERON_CONFIG:-/config/heron.json}"
echo "  Data:   ${HERON_DATA:-/data}"

# A bind-mounted or engine-created data directory may be owned by root; heron cannot create its
# log, index or lock file there. Say so before the daemon fails with StoreOpenFailed.
if [ -d "${HERON_DATA:-/data}" ] && [ ! -w "${HERON_DATA:-/data}" ]; then
    echo "WARNING: ${HERON_DATA:-/data} is not writable by $(id -un 2>/dev/null || echo "uid $(id -u)")" >&2
fi

# Default command is `daemon` (CMD in the Containerfile); any heron sub-command can be passed:
#   podman run --rm heron:latest check-config
exec /app/heron "$@"
