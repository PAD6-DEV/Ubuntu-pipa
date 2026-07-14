#!/bin/bash
set -x

# Offline tablet images: cloud-init can hang before the display manager.
mkdir -p /etc/cloud
touch /etc/cloud/cloud-init.disabled
systemctl disable --now cloud-init.service cloud-init-local.service \
    cloud-init-main.service cloud-init-network.service \
    cloud-config.service cloud-final.service 2>/dev/null || true
systemctl mask cloud-init.service cloud-init-local.service \
    cloud-init-main.service cloud-init-network.service \
    cloud-config.service cloud-final.service 2>/dev/null || true

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
