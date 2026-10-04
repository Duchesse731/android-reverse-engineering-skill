#!/usr/bin/env bash
# Shared Python implementation keeps ZIP/DEX parsing consistent across platforms.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/fingerprint.py" "$@"
