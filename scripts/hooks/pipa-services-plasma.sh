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

# SDDM greeter virtual keyboard (Wayland + KWin). Do not set General
# InputMethod= here — that hides the keyboard with a Wayland greeter.
install -d /etc/sddm.conf.d
cat > /etc/sddm.conf.d/11-virtual-keyboard.conf <<'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell,KWIN_IM_SHOW_ALWAYS=1,PLASMA_KEYBOARD_USE_QT_LAYOUTS=1

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1 --inputmethod plasma-keyboard
EOF

# Wire Plasma's virtual keyboard into KWin for root (firstboot), new users,
# system defaults, and the sddm greeter user.
desktop_file=""
for candidate in \
    /usr/share/applications/org.kde.plasma.keyboard.desktop \
    /usr/share/applications/org.kde.plasma-keyboard.desktop \
    /usr/share/applications/plasma-keyboard.desktop
do
    if [ -f "$candidate" ]; then
        desktop_file="$candidate"
        break
    fi
done
if [ -z "$desktop_file" ]; then
    desktop_file="$(grep -rl '^X-KDE-Wayland-VirtualKeyboard=true' /usr/share/applications 2>/dev/null \
        | grep -i plasma | head -n1 || true)"
fi
if [ -n "$desktop_file" ]; then
    for config_root in /root /etc/skel /var/lib/sddm; do
        install -d "$config_root/.config"
        cat > "$config_root/.config/kwinrc" <<EOF
[Wayland]
InputMethod=$desktop_file
VirtualKeyboardEnabled=true
EOF
    done
    # System-wide KWin defaults for all users.
    install -d /etc/xdg
    cat > /etc/xdg/kwinrc <<EOF
[Wayland]
InputMethod=$desktop_file
VirtualKeyboardEnabled=true
EOF
    if id sddm >/dev/null 2>&1; then
        chown -R sddm:sddm /var/lib/sddm/.config 2>/dev/null || true
    fi
    echo "pipa-services-plasma: KWin InputMethod=$desktop_file"
else
    echo "pipa-services-plasma: WARNING: plasma-keyboard desktop file not found" >&2
fi
