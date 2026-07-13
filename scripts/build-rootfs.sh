#!/bin/bash
# Build a 3-partition Ubuntu disk image for Xiaomi Pad 6 (pipa).
# Usage: build-rootfs.sh <gnome|plasma> [output.img]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARIANT="${1:?usage: $0 <gnome|plasma> [output.img]}"
OUT_IMG="${2:-$REPO_ROOT/work/ubuntu-pipa-${VARIANT}.img}"
SUITE="${UBUNTU_SUITE:-resolute}"
MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
PIPA_PKGS_URL="${PIPA_PKGS_URL:-https://thespider2.github.io/pipa-pkgs/repo/ubuntu/}"
IMAGE_SIZE_GIB="${IMAGE_SIZE_GIB:-16}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root"
    exit 1
fi

case "$VARIANT" in
    gnome|plasma) ;;
    *) echo "Unknown variant: $VARIANT"; exit 1 ;;
esac

read_pkg_list() {
    local file="$1"
    grep -vE '^\s*(#|$)' "$file" | tr '\n' ',' | sed 's/,$/\n/' | tr -d ' '
}

COMMON_PKGS="$(read_pkg_list "$REPO_ROOT/manifests/pipa-common.txt")"
VARIANT_PKGS="$(read_pkg_list "$REPO_ROOT/manifests/pipa-${VARIANT}.txt")"
INCLUDE_PKGS="${COMMON_PKGS},${VARIANT_PKGS}"

WORK="$(mktemp -d)"
ROOT="$WORK/root"
mkdir -p "$ROOT" "$(dirname "$OUT_IMG")"
trap 'umount -R "$ROOT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "=== Creating ${IMAGE_SIZE_GIB}GiB disk image ==="
rm -f "$OUT_IMG"
truncate -s "${IMAGE_SIZE_GIB}G" "$OUT_IMG"

# GPT: ESP 512MiB, boot 1GiB, root remainder
sgdisk -Z "$OUT_IMG" >/dev/null
sgdisk -n 1:0:+512M -t 1:EF00 -c 1:ESP "$OUT_IMG"
sgdisk -n 2:0:+1G -t 2:8300 -c 2:boot "$OUT_IMG"
sgdisk -n 3:0:0 -t 3:8300 -c 3:root "$OUT_IMG"

LOOP=$(losetup --find --show --partscan "$OUT_IMG")
partprobe "$LOOP" 2>/dev/null || true
# Wait for partition nodes
for _ in $(seq 1 20); do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p3" ] && break
    sleep 0.2
done

ESP_PART="${LOOP}p1"
BOOT_PART="${LOOP}p2"
ROOT_PART="${LOOP}p3"

mkfs.vfat -F 32 -n UBPIPAESP "$ESP_PART"
MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
    mkfs.ext4 -F -L boot "$BOOT_PART"
MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
    mkfs.ext4 -F -L ub-pipa "$ROOT_PART"

# Mount root, then boot, then create EFI dir on the boot fs (not under root
# where it would be hidden by the /boot mount), then mount ESP.
mount "$ROOT_PART" "$ROOT"
mkdir -p "$ROOT/boot"
mount "$BOOT_PART" "$ROOT/boot"
mkdir -p "$ROOT/boot/efi"
mount "$ESP_PART" "$ROOT/boot/efi"

echo "=== mmdebstrap $SUITE ($VARIANT) ==="
# Prefer apt packages from Ubuntu; pipa packages installed in a second pass
# so a missing remote repo does not fail the entire bootstrap.
mmdebstrap \
    --arch=arm64 \
    --variant=apt \
    --components=main,universe,multiverse,restricted \
    --include="systemd,systemd-sysv,dbus,apt-utils,ca-certificates,sudo,locales" \
    --skip=cleanup/apt/lists \
    "$SUITE" "$ROOT" "$MIRROR"

# Bind mounts for chroot package installs
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
mount -t tmpfs tmpfs "$ROOT/run"

cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe multiverse restricted
deb $MIRROR $SUITE-updates main universe multiverse restricted
deb $MIRROR $SUITE-security main universe multiverse restricted
EOF

mkdir -p "$ROOT/etc/apt/sources.list.d" "$ROOT/etc/apt/preferences.d"
cat > "$ROOT/etc/apt/sources.list.d/pipa-pkgs.list" <<EOF
deb [trusted=yes] $PIPA_PKGS_URL ./
EOF

# Prefer pipa kernel over stock Ubuntu kernels
cat > "$ROOT/etc/apt/preferences.d/pipa-kernel.pref" <<'EOF'
Package: linux-image-generic linux-image-virtual linux-headers-generic
Pin: release *
Pin-Priority: -1

Package: linux-image-pipa linux-modules-pipa linux-headers-pipa
Pin: release *
Pin-Priority: 1001
EOF

chroot "$ROOT" apt-get update

# Install desktop + shared packages; tolerate missing optional qc tools
IFS=',' read -ra PKG_ARR <<< "$INCLUDE_PKGS"
INSTALL_PKGS=()
OPTIONAL_PKGS=(qrtr-tools rmtfs tqftpserv pd-mapper tuned tuned-ppd plymouth-theme-kubuntu-logo)
for pkg in "${PKG_ARR[@]}"; do
    [ -n "$pkg" ] || continue
    skip=0
    for opt in "${OPTIONAL_PKGS[@]}"; do
        if [ "$pkg" = "$opt" ]; then
            # Try later; don't fail bootstrap if absent
            INSTALL_PKGS+=("$pkg")
            skip=1
            break
        fi
    done
    [ "$skip" -eq 1 ] && continue
    INSTALL_PKGS+=("$pkg")
done

echo "=== Installing packages (${#INSTALL_PKGS[@]}) ==="
# Noninteractive
export DEBIAN_FRONTEND=noninteractive
chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confnew" \
    "${INSTALL_PKGS[@]}" || {
    echo "WARN: bulk install failed; retrying without optional packages"
    FILTERED=()
    for pkg in "${INSTALL_PKGS[@]}"; do
        is_opt=0
        for opt in "${OPTIONAL_PKGS[@]}"; do
            [ "$pkg" = "$opt" ] && is_opt=1 && break
        done
        [ "$is_opt" -eq 0 ] && FILTERED+=("$pkg")
    done
    chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confnew" \
        "${FILTERED[@]}"
    for opt in "${OPTIONAL_PKGS[@]}"; do
        chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$opt" 2>/dev/null || true
    done
}

# Ensure EFI bootloader bits are present
chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    grub-efi-arm64 shim-signed || true

echo "=== Running post-install hooks ==="
if [ "$VARIANT" = plasma ]; then
    SERVICES_HOOK=pipa-services-plasma.sh
else
    SERVICES_HOOK=pipa-services-gnome.sh
fi

HOOKS=(
    pipa-apt-repo.sh
    pipa-grub-setup.sh
    "$SERVICES_HOOK"
    pipa-firstboot-install.sh
    pipa-validate-hardware.sh
    pipa-default-target.sh
)

for hook in "${HOOKS[@]}"; do
    src="$REPO_ROOT/scripts/hooks/$hook"
    if [ ! -f "$src" ]; then
        echo "ERROR: missing hook $hook"
        exit 1
    fi
    echo "--- $hook ---"
    cp "$src" "$ROOT/tmp/hook.sh"
    chmod +x "$ROOT/tmp/hook.sh"
    chroot "$ROOT" /tmp/hook.sh
    rm -f "$ROOT/tmp/hook.sh"
done

# fstab for the live image
cat > "$ROOT/etc/fstab" <<EOF
LABEL=ub-pipa / ext4 defaults,x-systemd.growfs 0 1
LABEL=boot /boot ext4 defaults 0 2
LABEL=UBPIPAESP /boot/efi vfat umask=0077 0 1
EOF

# Cleanup
chroot "$ROOT" apt-get clean || true
rm -rf "$ROOT/var/cache/apt/archives"/*.deb
rm -f "$ROOT/etc/machine-id" "$ROOT/var/lib/dbus/machine-id"
: > "$ROOT/etc/machine-id"

umount "$ROOT/boot/efi"
umount "$ROOT/boot"
# unmount bind mounts
umount "$ROOT/dev/pts" 2>/dev/null || true
umount "$ROOT/dev" 2>/dev/null || true
umount "$ROOT/proc" 2>/dev/null || true
umount "$ROOT/sys" 2>/dev/null || true
umount "$ROOT/run" 2>/dev/null || true
umount "$ROOT"

losetup -d "$LOOP"
LOOP=""

echo "=== Disk image ready: $OUT_IMG ==="
