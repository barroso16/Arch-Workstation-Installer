#!/usr/bin/env bash
# Compatibility loader for disk helpers.
#
# Public disk functions now live in smaller single-responsibility libraries.
# Source this file when a caller needs the complete disk API.

set -euo pipefail

DISK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=disk-common.sh
source "${DISK_LIB_DIR}/disk-common.sh"
# shellcheck source=disk-partition.sh
source "${DISK_LIB_DIR}/disk-partition.sh"
# shellcheck source=disk-luks.sh
source "${DISK_LIB_DIR}/disk-luks.sh"
# shellcheck source=disk-btrfs.sh
source "${DISK_LIB_DIR}/disk-btrfs.sh"
