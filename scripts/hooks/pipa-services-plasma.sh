#!/bin/bash
set -x

# Display manager (Plasma / Kubuntu)
systemctl enable sddm.service || true

# Core services
systemctl enable ssh.service || systemctl enable sshd.service || true
systemctl enable NetworkManager iwd bluetooth systemd-resolved systemd-timesyncd || true

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-iwd.conf <<'EOF'
[device]
wifi.backend=iwd
EOF

systemctl enable tuned || true
systemctl enable tuned-ppd || true
systemctl enable bootmac-bluetooth || true
systemctl enable swclock-offset-boot.service swclock-offset-shutdown.service || true
systemctl enable pd-mapper rmtfs tqftpserv || true
systemctl enable \
    pipa-sensors-persist \
    hexagonrpcd-sdsp \
    hexagonrpcd-adsp-sensorspd \
    iio-sensor-proxy \
    pipa-audio-init || true
systemctl mask hexagonrpcd-adsp-rootpd.service || true

mkdir -p /etc/environment.d
cat > /etc/environment.d/90-plasma-keyboard.conf <<'EOF'
KWIN_IM_SHOW_ALWAYS=1
PLASMA_KEYBOARD_USE_QT_LAYOUTS=1
EOF
