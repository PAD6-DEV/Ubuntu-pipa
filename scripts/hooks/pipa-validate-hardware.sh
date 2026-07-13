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

echo "Hardware validation passed."
