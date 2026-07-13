#!/bin/bash
set -x

# Display manager (GNOME)
systemctl enable gdm3.service || systemctl enable gdm.service || true

# Core services
systemctl enable ssh.service || systemctl enable sshd.service || true
systemctl enable NetworkManager iwd bluetooth systemd-resolved systemd-timesyncd || true

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-iwd.conf <<'EOF'
[device]
wifi.backend=iwd
EOF

# Power management
systemctl enable tuned || true
systemctl enable tuned-ppd || true

# Bluetooth MAC
systemctl enable bootmac-bluetooth || true

# Clock offset (no writable RTC on pipa)
systemctl enable swclock-offset-boot.service swclock-offset-shutdown.service || true

# Qualcomm firmware services
systemctl enable pd-mapper rmtfs tqftpserv || true

# Sensor / audio stack
systemctl enable \
    pipa-sensors-persist \
    hexagonrpcd-sdsp \
    hexagonrpcd-adsp-sensorspd \
    iio-sensor-proxy \
    pipa-audio-init || true

systemctl mask hexagonrpcd-adsp-rootpd.service || true
