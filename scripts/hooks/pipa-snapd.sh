#!/bin/bash
# Make snapd work on pipa (squashfs is modular; mounts fail without it).
set -eux

install -d /etc/modules-load.d
cat > /etc/modules-load.d/pipa-snap.conf <<'EOF'
loop
squashfs
EOF

# systemd rejects snap mounts if /snap is a dangling/broken symlink layout.
install -d /var/lib/snapd/snap
if [ -L /snap ]; then
    target="$(readlink -f /snap 2>/dev/null || true)"
    if [ -z "$target" ] || [ ! -d "$target" ]; then
        rm -f /snap
        install -d /snap
    fi
elif [ ! -e /snap ]; then
    # Prefer the classic Ubuntu layout snapd expects.
    ln -s /var/lib/snapd/snap /snap
fi

# Ensure AppArmor + snapd are enabled for confinement / mounts.
systemctl enable apparmor.service 2>/dev/null || true
systemctl enable snapd.apparmor.service 2>/dev/null || true
systemctl enable snapd.socket snapd.service 2>/dev/null || true
systemctl enable snapd.seeded.service 2>/dev/null || true
