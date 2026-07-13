#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

VARIANTS="${BUILD_VARIANTS:-gnome plasma}"
mkdir -p "$REPO_ROOT/work" "$REPO_ROOT/output"

for variant in $VARIANTS; do
    echo "=========================================="
    echo " Building Ubuntu pipa variant: $variant"
    echo "=========================================="
    RAW="$REPO_ROOT/work/ubuntu-pipa-${variant}.img"
    rm -f "$RAW"
    "$REPO_ROOT/scripts/build-rootfs.sh" "$variant" "$RAW"
    VARIANT_NAME="$variant" "$REPO_ROOT/scripts/post-process-image.sh" "$RAW"
done

echo "All variants built."
