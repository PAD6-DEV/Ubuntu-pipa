#!/bin/bash
set -eux

ROOTFS_LABEL="${ROOTFS_LABEL:-ub-pipa}"
BOOT_LABEL="${BOOT_LABEL:-boot}"
CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 quiet splash clk_ignore_unused pd_ignore_unused"

printf '%s\n' "$CMDLINE" > /etc/cmdline
mkdir -p /boot
printf '%s\n' "$CMDLINE" > /boot/cmdline.txt

# Build initramfs with dracut if available
KERNEL_VER="$(ls /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [ -n "$KERNEL_VER" ]; then
    if command -v pipa-refresh-initramfs >/dev/null 2>&1; then
        pipa-refresh-initramfs || true
    elif command -v dracut >/dev/null 2>&1; then
        dracut --force --kver "$KERNEL_VER" "/boot/initramfs-${KERNEL_VER}.img" || true
        cp -f "/boot/initramfs-${KERNEL_VER}.img" /boot/initramfs-linux-pipa.img || true
    elif command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -c -k "$KERNEL_VER" || update-initramfs -u || true
    fi
fi

mkdir -p /boot/grub
cat > /boot/grub/grub.cfg <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub
configfile (\$boot)/grub/grub.cfg
EOF

if command -v pipa-refresh-grub-config >/dev/null 2>&1; then
    # Script expects /boot mounted; inside image build it is
    pipa-refresh-grub-config || true
fi

# Wipe identity leftovers
rm -f /etc/machine-id /var/lib/dbus/machine-id
: > /etc/machine-id
rm -f /etc/NetworkManager/system-connections/* || true
rm -f /var/lib/systemd/random-seed || true
