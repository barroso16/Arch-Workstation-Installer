#!/usr/bin/env bash
# Compatibility wrapper for the current Stage05 implementation.
#
# The authoritative Stage05 flow is stage05-bootloader.sh: it installs and
# configures systemd-boot, prepares sbctl keys, signs artifacts, verifies
# signatures, and conditionally enrolls keys when firmware Setup Mode allows it.

set -euo pipefail

STAGE05_COMPAT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

exec bash "${STAGE05_COMPAT_DIR}/stage05-bootloader.sh" "$@"
