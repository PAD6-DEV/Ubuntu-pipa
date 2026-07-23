#!/usr/bin/env bash
# Patch an already-built ubuntu_rootfs.raw with Plasma firstboot + SDDM keyboard fixes.
# Usage: sudo ./scripts/patch-rootfs-image.sh /path/to/ubuntu_rootfs.raw
set -euo pipefail

IMG="${1:?usage: $0 /path/to/ubuntu_rootfs.raw}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root (sudo $0 $IMG)" >&2
    exit 1
fi
if [ ! -f "$IMG" ]; then
    echo "Image not found: $IMG" >&2
    exit 1
fi

MNT="$(mktemp -d /tmp/pipa-rootfs-XXXXXX)"
finish() {
    sync || true
    if mountpoint -q "$MNT" 2>/dev/null; then
        umount "$MNT/run" 2>/dev/null || true
        umount "$MNT/sys" 2>/dev/null || true
        umount "$MNT/proc" 2>/dev/null || true
        umount "$MNT/dev/pts" 2>/dev/null || true
        umount "$MNT/dev" 2>/dev/null || true
        umount "$MNT" 2>/dev/null || true
    fi
    rmdir "$MNT" 2>/dev/null || true
}
trap finish EXIT

echo "Mounting $IMG -> $MNT"
mount -o loop "$IMG" "$MNT"

ROOT_HASH="$(openssl passwd -6 root)"
awk -F: -v h="$ROOT_HASH" 'BEGIN{OFS=FS} $1=="root"{$2=h} {print}' "$MNT/etc/shadow" > "$MNT/etc/shadow.new"
mv "$MNT/etc/shadow.new" "$MNT/etc/shadow"
chmod 640 "$MNT/etc/shadow"
chown root:shadow "$MNT/etc/shadow" 2>/dev/null || chown root:root "$MNT/etc/shadow"

mkdir -p "$MNT/etc/sddm.conf.d"
SESSION_FILE=""
for candidate in \
    "$MNT/usr/share/wayland-sessions/plasma.desktop" \
    "$MNT/usr/share/wayland-sessions/plasmawayland.desktop" \
    "$MNT/usr/share/xsessions/plasma.desktop"
do
    if [ -f "$candidate" ]; then
        SESSION_FILE="$candidate"
        break
    fi
done
SESSION_NAME="$(basename "${SESSION_FILE:-plasma.desktop}" .desktop)"
echo "Plasma session: $SESSION_NAME"

# Keep root login possible; do not put DisplayServer here (Wayland lives in 11-*).
cat > "$MNT/etc/sddm.conf.d/00-root-login.conf" <<'EOF'
[Users]
MinimumUid=0
HideUsers=
HideShells=
EOF

# Only write firstboot autologin if setup is still pending.
if [ -f "$MNT/var/lib/pipa-firstboot/needs-setup" ]; then
    cat > "$MNT/etc/sddm.conf.d/10-firstboot-autologin.conf" <<EOF
[Autologin]
User=root
Session=$SESSION_NAME
Relogin=false
EOF
fi

# SDDM greeter on-screen keyboard (ArchWiki / Plasma 6.6).
cat > "$MNT/etc/sddm.conf.d/11-virtual-keyboard.conf" <<'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell,KWIN_IM_SHOW_ALWAYS=1,PLASMA_KEYBOARD_USE_QT_LAYOUTS=1

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1 --inputmethod plasma-keyboard
EOF

for pam in "$MNT/etc/pam.d/sddm" "$MNT/etc/pam.d/sddm-autologin"; do
    if [ -f "$pam" ]; then
        sed -i '/pam_succeed_if.so.*user != root/d' "$pam"
        sed -i '/pam_succeed_if.so.*uid >= 1000/d' "$pam"
    fi
done

mkdir -p "$MNT/etc/environment.d"
cat > "$MNT/etc/environment.d/90-plasma-keyboard.conf" <<'EOF'
KWIN_IM_SHOW_ALWAYS=1
PLASMA_KEYBOARD_USE_QT_LAYOUTS=1
EOF

desktop_file=""
for candidate in \
    /usr/share/applications/org.kde.plasma.keyboard.desktop \
    /usr/share/applications/org.kde.plasma-keyboard.desktop \
    /usr/share/applications/plasma-keyboard.desktop
do
    if [ -f "$MNT$candidate" ]; then
        desktop_file="$candidate"
        break
    fi
done
if [ -z "$desktop_file" ]; then
    desktop_file="$(grep -rl '^X-KDE-Wayland-VirtualKeyboard=true' "$MNT/usr/share/applications" 2>/dev/null \
        | grep -i plasma | head -n1 | sed "s|^$MNT||" || true)"
fi
if [ -z "$desktop_file" ]; then
    desktop_file="/usr/share/applications/org.kde.plasma.keyboard.desktop"
fi

write_kwinrc() {
    local dest="$1"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" <<EOF
[Wayland]
InputMethod=$desktop_file
VirtualKeyboardEnabled=true
EOF
}

write_kwinrc "$MNT/root/.config/kwinrc"
write_kwinrc "$MNT/etc/skel/.config/kwinrc"
write_kwinrc "$MNT/etc/xdg/kwinrc"
write_kwinrc "$MNT/var/lib/sddm/.config/kwinrc"
if grep -q '^sddm:' "$MNT/etc/passwd"; then
    chown -R sddm:sddm "$MNT/var/lib/sddm/.config" 2>/dev/null || true
fi

# Patch existing user homes so post-firstboot sessions get the keyboard too.
while IFS=: read -r user _ uid _ _ home _; do
    case "$uid" in
        ''|*[!0-9]*) continue ;;
    esac
    if [ "$uid" -ge 1000 ] && [ -d "$MNT$home" ]; then
        write_kwinrc "$MNT$home/.config/kwinrc"
        echo "Updated kwinrc for user $user ($home)"
    fi
done < "$MNT/etc/passwd"

echo "=== SDDM keyboard config ==="
cat "$MNT/etc/sddm.conf.d/11-virtual-keyboard.conf"
echo "=== kwinrc (system) ==="
cat "$MNT/etc/xdg/kwinrc"

sync
umount "$MNT"
trap - EXIT
rmdir "$MNT" 2>/dev/null || true
e2fsck -fy "$IMG" || true
echo "Patched OK: $IMG"
echo "Reflash ubuntu_rootfs.raw. SDDM should show plasma-keyboard; login sessions too."
