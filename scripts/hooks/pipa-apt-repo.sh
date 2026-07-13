#!/bin/bash
# Ensure pipa apt repo persists in the image.
set -eux
mkdir -p /etc/apt/sources.list.d
if [ ! -f /etc/apt/sources.list.d/pipa-pkgs.list ]; then
    cat > /etc/apt/sources.list.d/pipa-pkgs.list <<'EOF'
deb [trusted=yes] https://thespider2.github.io/pipa-pkgs/repo/ubuntu/ ./
EOF
fi
