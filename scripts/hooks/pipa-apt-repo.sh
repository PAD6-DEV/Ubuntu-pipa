#!/bin/bash
# Ensure Ubuntu pipa-pkgs apt repo persists in the image.
set -eux
mkdir -p /etc/apt/sources.list.d /etc/apt/preferences.d

cat > /etc/apt/sources.list.d/pipa-pkgs.list <<'EOF'
# Xiaomi Pad 6 (pipa) Ubuntu device packages
deb [trusted=yes] https://thespider2.github.io/pipa-pkgs/repo/ubuntu/ ./
EOF

# Prefer packages published by pipa-pkgs over Ubuntu archives on name clash.
cat > /etc/apt/preferences.d/pipa-pkgs.pref <<'EOF'
Package: *
Pin: origin thespider2.github.io
Pin-Priority: 1001
EOF
