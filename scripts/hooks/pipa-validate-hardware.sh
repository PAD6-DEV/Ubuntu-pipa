#!/bin/bash
set -euo pipefail

fail() { echo "HW validate FAIL: $*" >&2; exit 1; }
ok() { echo "HW validate OK: $*"; }

# Audio
[ -x /usr/local/bin/pipa-audio-init ] || fail "pipa-audio-init missing"
[ -f /usr/lib/systemd/system/pipa-audio-init.service ] || fail "pipa-audio-init.service missing"
[ -f "/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi Pad 6.conf" ] || fail "ALSA UCM missing"
[ -f /usr/share/wireplumber/wireplumber.conf.d/51-pipa.conf ] || fail "WirePlumber pipa conf missing"
ok "audio"

# Sensors
[ -f /usr/lib/udev/rules.d/81-libssc-xiaomi-pipa.rules ] || fail "sensor udev rules missing"
[ -f /usr/lib/systemd/system/pipa-sensors-persist.service ] || fail "pipa-sensors-persist missing"
[ -e /usr/lib/*/libssc.so.2 ] || [ -e /usr/lib/aarch64-linux-gnu/libssc.so.2 ] || fail "libssc missing"
ok "sensors"

# Firmware / GSK
[ -d /usr/lib/firmware/qcom/sm8250/xiaomi/pipa ] || fail "pipa qcom firmware missing"
[ -f /etc/profile.d/90-pipa-gsk-renderer.sh ] || fail "GSK renderer profile missing"
ok "firmware/gsk"

# Kernel
ls /boot/Image* >/dev/null 2>&1 || ls /boot/vmlinuz-* >/dev/null 2>&1 || fail "kernel image missing"
[ -d /boot/dtbs/qcom ] || fail "DTB directory missing"
ok "kernel"

# Boot / GUI (OOB boot path)
# Do not require kernel "splash" — pipa panel black-screens without early DRM plymouth.
grep -qw quiet /etc/cmdline 2>/dev/null || fail "cmdline missing quiet"
! grep -qw splash /etc/cmdline 2>/dev/null || fail "cmdline must not include splash on pipa"
command -v plymouth >/dev/null 2>&1 || fail "plymouth missing"
[ -d /usr/share/plymouth/themes/spinner ] || fail "plymouth spinner theme missing"
[ -f /etc/cloud/cloud-init.disabled ] || fail "cloud-init not disabled"
systemctl get-default 2>/dev/null | grep -q graphical.target || fail "default target is not graphical"
if [ -f /etc/gdm3/custom.conf ] || [ -L /etc/systemd/system/display-manager.service ]; then
    for pam in /etc/pam.d/gdm-autologin /etc/pam.d/gdm-password; do
        if [ -f "$pam" ] && grep -q 'pam_succeed_if.so user != root' "$pam"; then
            fail "$pam still blocks root autologin"
        fi
    done
    ok "gdm root autologin pam"
fi
if mountpoint -q /boot/efi 2>/dev/null || [ -d /boot/efi/EFI ]; then
    [ -f /boot/efi/EFI/ubuntu/grubaa64.efi ] || [ -f /boot/efi/EFI/BOOT/grubaa64.efi ] \
        || fail "ESP missing grubaa64.efi"
    ok "esp grubaa64"
fi
ok "boot/gui"

# Snap prerequisites (firefox etc. are snaps on Ubuntu)
[ -f /etc/modules-load.d/pipa-snap.conf ] || fail "pipa-snap modules-load missing"
grep -q '^squashfs$' /etc/modules-load.d/pipa-snap.conf || fail "squashfs not listed for autoload"
command -v snap >/dev/null 2>&1 || fail "snap client missing"
ok "snapd"

echo "Hardware validation passed."
