#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATE=$(date +%Y%m%d)
VARIANT="${VARIANT_NAME:-gnome}"
IMAGE_NAME="ubuntu-pipa-${VARIANT}-${DATE}"
RAW_IMAGE="${1:-$REPO_ROOT/work/ubuntu-pipa-${VARIANT}.img}"
OUTPUT_DIR="$REPO_ROOT/output/$IMAGE_NAME"

ROOTFS_LABEL="ub-pipa"
BOOT_LABEL="boot"
ESP_LABEL="UBPIPAESP"

SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
VBMETA_DISABLED="$REPO_ROOT/assets/vbmeta-disabled.img"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi

if [ ! -f "$RAW_IMAGE" ]; then
    echo "Raw image not found: $RAW_IMAGE"
    echo "Usage: $0 <path-to-raw-disk-image>"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
MNT=$(mktemp -d)
BOOT_MNT=$(mktemp -d)
ESP_MNT=$(mktemp -d)

cleanup() {
    umount "$MNT/boot" 2>/dev/null || true
    umount "$MNT" 2>/dev/null || true
    umount "$BOOT_MNT" 2>/dev/null || true
    umount "$ESP_MNT" 2>/dev/null || true
    rmdir "$MNT" "$BOOT_MNT" "$ESP_MNT" 2>/dev/null || true
    losetup -j "$RAW_IMAGE" | cut -d: -f1 | xargs -r losetup -d 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Setting up loop device ==="
LOOP=$(losetup --find --show --partscan "$RAW_IMAGE")

ESP_PART="${LOOP}p1"
BOOT_PART="${LOOP}p2"
ROOT_PART="${LOOP}p3"

echo "=== Extracting rootfs ==="
mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot"
mount "$BOOT_PART" "$MNT/boot"

KERNEL_VER=$(find "$MNT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
echo "Kernel version: $KERNEL_VER"
echo "Boot contents:"
ls -la "$MNT/boot/" | head -20

SIZE=$(du -sBM "$MNT" | awk '{print $1}' | tr -d 'M')
SIZE=$((SIZE + (SIZE / 8) + 512))
echo "Rootfs size: ${SIZE}M"

truncate -s "${SIZE}M" "$OUTPUT_DIR/ubuntu_rootfs.raw"
MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
    mkfs.ext4 -L "$ROOTFS_LABEL" "$OUTPUT_DIR/ubuntu_rootfs.raw"
ROOT_MNT=$(mktemp -d)
mount -o loop "$OUTPUT_DIR/ubuntu_rootfs.raw" "$ROOT_MNT"
rsync -aHAX --exclude '/tmp/*' --exclude '/boot/*' --exclude '/boot/efi' "$MNT/" "$ROOT_MNT/"

cat > "$ROOT_MNT/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL / ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
EOF

mkdir -p "$ROOT_MNT/boot/grub"
cat > "$ROOT_MNT/boot/grub/grub.cfg" <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub
configfile (\$boot)/grub/grub.cfg
EOF

umount "$ROOT_MNT"
rmdir "$ROOT_MNT"

echo "=== Creating boot image ==="
truncate -s 1024M "$OUTPUT_DIR/ubuntu_boot.raw"
mkfs.ext4 -F -L "$BOOT_LABEL" -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file "$OUTPUT_DIR/ubuntu_boot.raw"
mount -o loop "$OUTPUT_DIR/ubuntu_boot.raw" "$BOOT_MNT"

KERNEL_IMAGE=""
for f in "$MNT/boot/Image.gz" "$MNT/boot/vmlinuz-$KERNEL_VER"; do
    [ -f "$f" ] && KERNEL_IMAGE="$f" && break
done
KERNEL_IMAGE_UNCOMPRESSED=""
for f in "$MNT/boot/Image" "$MNT/boot/vmlinuz-$KERNEL_VER.uncompressed"; do
    [ -f "$f" ] && KERNEL_IMAGE_UNCOMPRESSED="$f" && break
done
INITRAMFS="$MNT/boot/initramfs-$KERNEL_VER.img"
INITRAMFS_STABLE="initramfs-linux-pipa.img"

if [ -z "$KERNEL_IMAGE" ] || [ ! -f "$KERNEL_IMAGE" ]; then
    # Fallback: Ubuntu-style initrd naming
    for f in "$MNT/boot"/initrd.img-* "$MNT/boot"/initramfs-*.img; do
        [ -f "$f" ] && INITRAMFS="$f" && break
    done
fi

if [ -z "$KERNEL_IMAGE" ] || [ ! -f "$KERNEL_IMAGE" ]; then
    echo "ERROR: kernel image not found under $MNT/boot" >&2
    ls -la "$MNT/boot/" >&2 || true
    exit 1
fi

cp "$KERNEL_IMAGE" "$BOOT_MNT/Image.gz"
[ -n "$KERNEL_IMAGE_UNCOMPRESSED" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ] && cp "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/Image"
if [ -f "$INITRAMFS" ]; then
    cp "$INITRAMFS" "$BOOT_MNT/initramfs-$KERNEL_VER.img" 2>/dev/null || cp "$INITRAMFS" "$BOOT_MNT/$(basename "$INITRAMFS")"
    cp "$INITRAMFS" "$BOOT_MNT/$INITRAMFS_STABLE"
elif [ -f "$MNT/boot/$INITRAMFS_STABLE" ]; then
    cp "$MNT/boot/$INITRAMFS_STABLE" "$BOOT_MNT/$INITRAMFS_STABLE"
else
    echo "ERROR: initramfs not found" >&2
    exit 1
fi

mkdir -p "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub"
shopt -s nullglob
dtb_files=("$MNT/boot/dtbs/qcom"/sm8250-xiaomi-pipa*.dtb)
shopt -u nullglob
if [ ${#dtb_files[@]} -eq 0 ] && [ -f "$MNT/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb" ]; then
    dtb_files=("$MNT/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb")
fi
if [ ${#dtb_files[@]} -eq 0 ]; then
    echo "ERROR: no DTB found under $MNT/boot/dtbs/qcom" >&2
    exit 1
fi
cp "${dtb_files[@]}" "$BOOT_MNT/dtbs/qcom/"

[ -f "$MNT/boot/System.map-$KERNEL_VER" ] && cp "$MNT/boot/System.map-$KERNEL_VER" "$BOOT_MNT/"
[ -f "$MNT/boot/config-$KERNEL_VER" ] && cp "$MNT/boot/config-$KERNEL_VER" "$BOOT_MNT/"

TARGET_KERNEL_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 earlycon quiet splash clk_ignore_unused pd_ignore_unused"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$BOOT_MNT/cmdline.txt"

kernel_rel="Image"
[ -f "$BOOT_MNT/Image" ] || kernel_rel="Image.gz"

dtb_rels=()
for dtb in "${dtb_files[@]}"; do
    dtb_rels+=("dtbs/qcom/$(basename "$dtb")")
done

"$REPO_ROOT/scripts/write-pipa-grub-cfg.sh" \
    "$BOOT_MNT/grub/grub.cfg" "$BOOT_LABEL" "$TARGET_KERNEL_CMDLINE" \
    "$kernel_rel" "$INITRAMFS_STABLE" "${dtb_rels[@]}"

umount "$BOOT_MNT"

echo "=== Creating ESP image ==="
truncate -s 128M "$OUTPUT_DIR/ubuntu_esp.raw"
mkfs.fat -F 16 -n "$ESP_LABEL" "$OUTPUT_DIR/ubuntu_esp.raw"
mount -o loop "$OUTPUT_DIR/ubuntu_esp.raw" "$ESP_MNT"

# Prefer EFI tree already installed onto the disk ESP during rootfs build
SRC_ESP_MNT=$(mktemp -d)
if mount "$ESP_PART" "$SRC_ESP_MNT" 2>/dev/null; then
    if [ -d "$SRC_ESP_MNT/EFI" ]; then
        cp -a "$SRC_ESP_MNT/EFI" "$ESP_MNT/"
    fi
    umount "$SRC_ESP_MNT"
fi
rmdir "$SRC_ESP_MNT" 2>/dev/null || true

# Also copy from rootfs /boot/efi if present under the mounted image
if [ -d "$MNT/boot/efi/EFI" ]; then
    mkdir -p "$ESP_MNT/EFI"
    cp -a "$MNT/boot/efi/EFI/." "$ESP_MNT/EFI/" 2>/dev/null || true
fi

mkdir -p "$ESP_MNT/EFI/ubuntu" "$ESP_MNT/EFI/BOOT"

# Copy shim / fallback EFI payloads from package paths in the rootfs
copy_shim_payloads() {
    local dest="$1"
    local src
    for src in \
        "$MNT/usr/lib/shim/shimaa64.efi.signed.latest" \
        "$MNT/usr/lib/shim/shimaa64.efi.signed" \
        "$MNT/usr/lib/shim/shimaa64.efi"; do
        if [ -f "$src" ]; then
            cp -f "$src" "$dest/shimaa64.efi"
            break
        fi
    done
    # Any leftover *.efi from shim package
    if [ ! -f "$dest/shimaa64.efi" ]; then
        src="$(ls "$MNT"/usr/lib/shim/shimaa64.efi* 2>/dev/null | head -n1 || true)"
        [ -n "$src" ] && [ -f "$src" ] && cp -f "$src" "$dest/shimaa64.efi"
    fi
    for src in "$MNT"/usr/lib/shim/mmaa64.efi* "$MNT"/usr/lib/shim/fbaa64.efi*; do
        [ -f "$src" ] || continue
        base="$(basename "$src" | sed -E 's/\.signed(\.latest)?$//')"
        cp -f "$src" "$dest/$base"
    done
}

copy_shim_payloads "$ESP_MNT/EFI/ubuntu"

# Build grubaa64.efi if missing (this is what shim loads)
GRUB_MOD_DIR="$MNT/usr/lib/grub/arm64-efi"
if [ ! -f "$ESP_MNT/EFI/ubuntu/grubaa64.efi" ]; then
    if command -v grub-mkimage >/dev/null 2>&1 && [ -d "$GRUB_MOD_DIR" ]; then
        echo "=== Building grubaa64.efi with grub-mkimage ==="
        grub-mkimage \
            -d "$GRUB_MOD_DIR" \
            -O arm64-efi \
            -o "$ESP_MNT/EFI/ubuntu/grubaa64.efi" \
            -p /EFI/ubuntu \
            all_video boot cat chain configfile echo ext2 fat gzio help \
            linux loadenv ls lsefi lsefimmap normal part_gpt part_msdos \
            reboot regexp search search_fs_file search_fs_uuid search_label \
            sleep test true
    elif [ -f "$MNT/usr/lib/grub/arm64-efi/monolithic/grubaa64.efi" ]; then
        cp -f "$MNT/usr/lib/grub/arm64-efi/monolithic/grubaa64.efi" \
            "$ESP_MNT/EFI/ubuntu/grubaa64.efi"
    else
        echo "ERROR: cannot produce grubaa64.efi (shim alone is not enough)" >&2
        find "$MNT/usr/lib/shim" "$MNT/usr/lib/grub" -type f 2>/dev/null | head -50 >&2 || true
        exit 1
    fi
fi

# Removable path: BOOTAA64.EFI (shim preferred) + grubaa64.efi beside it
if [ -f "$ESP_MNT/EFI/ubuntu/shimaa64.efi" ]; then
    cp -f "$ESP_MNT/EFI/ubuntu/shimaa64.efi" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
elif [ -f "$ESP_MNT/EFI/ubuntu/grubaa64.efi" ]; then
    cp -f "$ESP_MNT/EFI/ubuntu/grubaa64.efi" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
else
    echo "ERROR: No shimaa64.efi or grubaa64.efi found for ESP" >&2
    find "$ESP_MNT" -type f >&2 || true
    exit 1
fi
cp -f "$ESP_MNT/EFI/ubuntu/grubaa64.efi" "$ESP_MNT/EFI/BOOT/grubaa64.efi"

# Stub grub.cfg on ESP: redirect to labeled /boot partition
for shim_vendor in ubuntu BOOT; do
    mkdir -p "$ESP_MNT/EFI/$shim_vendor"
    cat > "$ESP_MNT/EFI/$shim_vendor/grub.cfg" <<ESPCFG
if [ -f \${config_directory}/bootuuid.cfg ]; then
  source \${config_directory}/bootuuid.cfg
fi
if [ -n "\${BOOT_UUID}" ]; then
  search --fs-uuid "\${BOOT_UUID}" --set prefix --no-floppy
else
  search --label $BOOT_LABEL --set prefix --no-floppy
fi
if [ -d (\$prefix)/grub ]; then
  set prefix=(\$prefix)/grub
  configfile \$prefix/grub.cfg
else
  set prefix=(\$prefix)/boot/grub
  configfile \$prefix/grub.cfg
fi
boot
ESPCFG
    cat > "$ESP_MNT/EFI/$shim_vendor/bootuuid.cfg" <<UUIDCFG
set BOOT_UUID=""
UUIDCFG
done

echo "=== ESP contents ==="
find "$ESP_MNT" -type f -printf '%p (%s)\n' | sort
if [ ! -f "$ESP_MNT/EFI/ubuntu/grubaa64.efi" ] || [ ! -f "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI" ]; then
    echo "ERROR: ESP missing required EFI binaries after assembly" >&2
    exit 1
fi

umount "$ESP_MNT"
umount "$MNT/boot"
umount "$MNT"

echo "=== Fetching Mu-Silicium ==="
if [ ! -f "$OUTPUT_DIR/silicium.img" ]; then
    wget -O "$OUTPUT_DIR/silicium.img" "$SILICIUM_URL"
fi

echo "=== Copying vbmeta ==="
if [ -f "$VBMETA_DISABLED" ]; then
    cp "$VBMETA_DISABLED" "$OUTPUT_DIR/vbmeta-disabled.img"
else
    echo "WARNING: vbmeta-disabled.img not found at $VBMETA_DISABLED"
fi

echo "=== Writing flash scripts ==="
cat > "$OUTPUT_DIR/flash.sh" <<'FLASH'
#!/usr/bin/env bash
set -euo pipefail

announce() {
    printf '### %s\n' "$1"
}

announce "Xiaomi Pad 6 single-boot flasher"
announce "This mode flashes Ubuntu rootfs to userdata."
announce "Android userdata will be overwritten."
announce "First Linux flash usually needs dtbo erase + disabled vbmeta."
echo

ERASE_DTBO="${ERASE_DTBO:-}"
FLASH_VBMETA="${FLASH_VBMETA:-}"

choose_yes_no() {
    local prompt="$1"
    local default_answer="$2"
    local answer

    while true; do
        read -r -p "$prompt [$default_answer]: " answer
        if [ -z "$answer" ]; then
            answer="$default_answer"
        fi

        case "$answer" in
            y|Y|yes|YES)
                printf 'yes\n'
                return 0
                ;;
            n|N|no|NO)
                printf 'no\n'
                return 0
                ;;
        esac

        echo "Please answer yes or no."
    done
}

announce "Verifying connected device"
fastboot getvar product 2>&1 | grep pipa

if [ -z "$ERASE_DTBO" ]; then
    ERASE_DTBO="$(choose_yes_no 'Erase dtbo_ab before flashing? (needed to avoid fastboot loops)' 'yes')"
fi

if [ -z "$FLASH_VBMETA" ]; then
    FLASH_VBMETA="$(choose_yes_no 'Flash disabled vbmeta to vbmeta_ab? (needed for Mu-Silicium)' 'yes')"
fi

announce "Flash plan"
echo "Erase dtbo_ab         -> $ERASE_DTBO"
echo "Flash vbmeta_ab       -> $FLASH_VBMETA"
echo "Mu-Silicium boot      -> boot_ab"
echo "Ubuntu EFI image      -> rawdump"
echo "Ubuntu boot           -> cust"
echo "Ubuntu rootfs         -> userdata"
echo "Refresh A/B slot      -> yes (set_active toggle)"
echo

read -r -p "Proceed with flashing? [Y/n]: " CONFIRM_FLASH
case "${CONFIRM_FLASH:-Y}" in
    y|Y|yes|YES|"")
        ;;
    *)
        echo "Aborted."
        exit 0
        ;;
esac

if [ "$ERASE_DTBO" = "yes" ]; then
    announce "Erasing dtbo_ab"
    fastboot erase dtbo_ab
fi

if [ "$FLASH_VBMETA" = "yes" ]; then
    announce "Flashing vbmeta_ab"
    fastboot flash vbmeta_ab vbmeta-disabled.img
fi

announce "Flashing Mu-Silicium boot image to boot_ab"
fastboot flash boot_ab silicium.img

# Flashing boot_ab can leave the current slot marked unbootable until the
# active slot is toggled (otherwise the device re-enters fastboot).
refresh_boot_slot() {
    local current other
    current="$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot:[[:space:]]*//p' | tr -d '\r' | head -n1)"
    case "$current" in
        a) other=b ;;
        b) other=a ;;
        *)
            announce "current-slot unavailable ($current); forcing slot a"
            fastboot set_active a
            return 0
            ;;
    esac
    announce "Refreshing A/B slot state ($current -> $other -> $current)"
    fastboot set_active "$other"
    fastboot set_active "$current"
}

announce "Flashing Ubuntu EFI image to rawdump"
fastboot flash rawdump ubuntu_esp.raw

announce "Flashing Ubuntu boot image to cust"
fastboot flash cust ubuntu_boot.raw

announce "Flashing Ubuntu rootfs image to userdata"
fastboot flash userdata ubuntu_rootfs.raw

refresh_boot_slot

announce "Rebooting device"
fastboot reboot
FLASH
chmod +x "$OUTPUT_DIR/flash.sh"

cat > "$OUTPUT_DIR/flash-multiboot.sh" <<'MFLASH'
#!/usr/bin/env bash
set -euo pipefail

announce() {
    printf '### %s\n' "$1"
}

choose_from_menu() {
    local prompt="$1"
    local default_index="$2"
    shift 2

    local options=("$@")
    local answer
    local index

    echo "$prompt" >&2
    for index in "${!options[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&2
    done

    while true; do
        read -r -p "Select an option [$default_index]: " answer
        if [ -z "$answer" ]; then
            answer="$default_index"
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
            printf '%s\n' "${options[$((answer - 1))]}"
            return 0
        fi
        echo "Invalid selection: $answer" >&2
    done
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    local value

    read -r -p "$prompt [$default_value]: " value
    if [ -z "$value" ]; then
        value="$default_value"
    fi
    printf '%s\n' "$value"
}

announce "Xiaomi Pad 6 multiboot flasher"
announce "This mode flashes Ubuntu rootfs to a dedicated partition such as linux."
announce "It does not use userdata unless you explicitly choose that partition."
announce "First Linux flash usually needs dtbo erase + disabled vbmeta."
announce "Press Enter to accept the default shown in brackets."
echo

BOOT_SLOT_TARGET="${BOOT_SLOT_TARGET:-}"
ROOTFS_PARTITION="${ROOTFS_PARTITION:-}"
ERASE_DTBO="${ERASE_DTBO:-}"
FLASH_VBMETA="${FLASH_VBMETA:-}"
ESP_PARTITION="rawdump"
BOOT_PARTITION="cust"

if [ -z "$BOOT_SLOT_TARGET" ]; then
    BOOT_SLOT_TARGET="$(choose_from_menu 'Choose the boot slot target:' 3 \
        'boot_a' \
        'boot_b' \
        'boot_ab')"
fi

if [ -z "$ROOTFS_PARTITION" ]; then
    ROOTFS_PARTITION="$(prompt_with_default 'Dedicated root filesystem partition name' 'linux')"
fi

if [ -z "$ERASE_DTBO" ]; then
    ERASE_DTBO="$(choose_from_menu 'Erase dtbo_ab before flashing? (needed to avoid fastboot loops)' 2 \
        'no' \
        'yes')"
fi

if [ -z "$FLASH_VBMETA" ]; then
    FLASH_VBMETA="$(choose_from_menu 'Flash disabled vbmeta to vbmeta_ab? (needed for Mu-Silicium)' 2 \
        'no' \
        'yes')"
fi

case "$BOOT_SLOT_TARGET" in
    boot_a|boot_b|boot_ab) ;;
    *)
        echo "Unsupported boot slot target: $BOOT_SLOT_TARGET" >&2
        exit 1
        ;;
esac

case "$ERASE_DTBO" in
    yes|y|Y)
        ERASE_DTBO="yes"
        ;;
    no|n|N)
        ERASE_DTBO="no"
        ;;
    *)
        echo "ERASE_DTBO must be yes or no" >&2
        exit 1
        ;;
esac

case "$FLASH_VBMETA" in
    yes|y|Y)
        FLASH_VBMETA="yes"
        ;;
    no|n|N)
        FLASH_VBMETA="no"
        ;;
    *)
        echo "FLASH_VBMETA must be yes or no" >&2
        exit 1
        ;;
esac

if [[ ! "$ROOTFS_PARTITION" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid root filesystem partition name: $ROOTFS_PARTITION" >&2
    exit 1
fi

announce "Verifying connected device"
fastboot getvar product 2>&1 | grep pipa

if [ "$ERASE_DTBO" = "yes" ]; then
    announce "Erasing dtbo_ab"
    fastboot erase dtbo_ab
fi

announce "Flash plan"
echo "vbmeta image          -> vbmeta_ab"
echo "Flash vbmeta_ab       -> $FLASH_VBMETA"
echo "Ubuntu EFI image      -> $ESP_PARTITION"
echo "Ubuntu boot           -> $BOOT_PARTITION"
echo "Ubuntu rootfs         -> $ROOTFS_PARTITION"
echo "Erase dtbo_ab         -> $ERASE_DTBO"
echo "Refresh A/B slot      -> yes (set_active toggle)"
echo
echo

read -r -p "Proceed with flashing? [Y/n]: " CONFIRM_FLASH
case "${CONFIRM_FLASH:-Y}" in
    y|Y|yes|YES|"")
        ;;
    *)
        echo "Aborted."
        exit 0
        ;;
esac

if [ "$FLASH_VBMETA" = "yes" ]; then
    announce "Flashing vbmeta_ab"
    fastboot flash vbmeta_ab vbmeta-disabled.img
fi

announce "Flashing Mu-Silicium boot image to $BOOT_SLOT_TARGET"
fastboot flash "$BOOT_SLOT_TARGET" silicium.img

announce "Flashing Ubuntu EFI image to $ESP_PARTITION"
fastboot flash "$ESP_PARTITION" ubuntu_esp.raw

announce "Flashing Ubuntu boot image to $BOOT_PARTITION"
fastboot flash "$BOOT_PARTITION" ubuntu_boot.raw

announce "Flashing Ubuntu rootfs image to $ROOTFS_PARTITION"
fastboot flash "$ROOTFS_PARTITION" ubuntu_rootfs.raw

# Flashing boot_* can leave a slot marked unbootable until active slot is
# refreshed (otherwise the device re-enters fastboot).
refresh_boot_slot() {
    local wanted="$1"
    local current other target
    current="$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot:[[:space:]]*//p' | tr -d '\r' | head -n1)"
    case "$wanted" in
        boot_a) target=a ;;
        boot_b) target=b ;;
        boot_ab)
            case "$current" in
                a|b) target="$current" ;;
                *) target=a ;;
            esac
            ;;
        *)
            target=a
            ;;
    esac
    case "$target" in
        a) other=b ;;
        b) other=a ;;
    esac
    announce "Refreshing A/B slot state (want $target; $current -> $other -> $target)"
    fastboot set_active "$other"
    fastboot set_active "$target"
}

refresh_boot_slot "$BOOT_SLOT_TARGET"

announce "Rebooting device"
fastboot reboot
MFLASH
chmod +x "$OUTPUT_DIR/flash-multiboot.sh"

echo "=== Writing build metadata ==="
cat > "$OUTPUT_DIR/BUILDINFO.txt" <<EOF
Ubuntu Pipa Image Build
================================
Desktop:        ${VARIANT}
Build date:     $DATE
Kernel:         ${KERNEL_VER:-unknown}
Rootfs label:   $ROOTFS_LABEL
Boot label:     $BOOT_LABEL
ESP label:      $ESP_LABEL
Silicium URL:   $SILICIUM_URL
Git rev:        ${BUILD_GIT_REV:-unknown}
EOF

echo "=== Generating checksums ==="
(cd "$OUTPUT_DIR" && sha256sum -- *.raw *.img *.sh BUILDINFO.txt > SHA256SUMS)

ARCHIVE="$REPO_ROOT/output/${IMAGE_NAME}.tar.xz"
echo "=== Creating tar.xz archive: $ARCHIVE ==="
# Top-level directory inside the archive so extract creates IMAGE_NAME/
tar -C "$REPO_ROOT/output" -cvf - "$IMAGE_NAME" | xz -T0 -9 > "$ARCHIVE"
(
    cd "$REPO_ROOT/output"
    sha256sum -- "$(basename "$ARCHIVE")" > "${IMAGE_NAME}.tar.xz.sha256"
)

echo ""
echo "=== Done! ==="
echo "Output:  $OUTPUT_DIR/"
echo "Archive: $ARCHIVE"
