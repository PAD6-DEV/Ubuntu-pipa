# Ubuntu for Xiaomi Pad 6 (pipa)

Ubuntu 26.04 LTS (Resolute) port for the Xiaomi Pad 6, built with mmdebstrap.
Device packages come from [pipa-pkgs](https://github.com/thespider2/pipa-pkgs)
(`repo/ubuntu/`) and are pulled at image build time.

## Variants

- **GNOME** — `ubuntu-desktop` + `gdm3`
- **Plasma** — `kubuntu-desktop` + `sddm`

Images are flashable via fastboot (Mu-Silicium UEFI → ESP / boot / rootfs),
same partition map as the Ultramarine pipa port.

## Repository structure

```
ubuntu-pipa/
├── manifests/           # Package lists (common, gnome, plasma)
├── scripts/
│   ├── build-rootfs.sh  # mmdebstrap → 3-partition disk image
│   ├── post-process-image.sh
│   ├── ci-build.sh / build-all.sh
│   └── hooks/           # chroot post-install scripts
├── assets/              # vbmeta-disabled.img
├── Dockerfile
└── Makefile
```

## Package repo

```
https://thespider2.github.io/pipa-pkgs/repo/ubuntu/
```

```bash
# On a running tablet
sudo apt update && sudo apt upgrade
```

## Building

### Docker (recommended)

```bash
docker build -t ubuntu-pipa-builder .
docker run --privileged --rm \
  -v "$PWD/output:/build/output" \
  -v /dev:/dev \
  ubuntu-pipa-builder
```

Or: `make image`

### Local

```bash
# Requires Ubuntu 26.04 aarch64 host (or suitable chroot) with mmdebstrap
sudo ./scripts/build-all.sh
# or a single variant:
sudo ./scripts/build-all.sh gnome
```

## Flashing

Download the variant you want from the matching
[GitHub Release](https://github.com/PAD6-DEV/Ubuntu-pipa/releases)
(successful `main` / manual builds publish a `build-YYYYMMDD-<sha>` tag +
release). Archives larger than ~1.9 GiB are split into `.part` pieces to stay
under GitHub’s 2 GiB asset limit — reassemble with `./join-archives.sh` (or
`cat …part*`) before extracting. Push a `v*` / `nightly-*` tag yourself for a
named release.

Then:

```bash
# If the release has .part files:
./join-archives.sh ubuntu-pipa-gnome-YYYYMMDD.tar.xz

tar -xJf ubuntu-pipa-gnome-YYYYMMDD.tar.xz
cd ubuntu-pipa-gnome-YYYYMMDD

# Put the device into fastboot mode, then:
./flash.sh

# Multiboot (interactive: choose boot slot + rootfs partition name)
./flash-multiboot.sh
```

Both scripts can also be driven non-interactively with env vars
(`ERASE_DTBO`, `FLASH_VBMETA`; multiboot also accepts `BOOT_SLOT_TARGET`,
`ROOTFS_PARTITION`).

| Artifact | Fastboot target |
|----------|-----------------|
| `silicium.img` | `boot_ab` (or `boot_a` / `boot_b`) |
| `ubuntu_esp.raw` | `rawdump` |
| `ubuntu_boot.raw` | `cust` |
| `ubuntu_rootfs.raw` | `userdata` (single-boot) or e.g. `linux` (multiboot) |
| `vbmeta-disabled.img` | `vbmeta_ab` (optional) |

## First boot

Root autologins once (`root` / `root`). A zenity/kdialog wizard creates your
user (sudo group), sets hostname, and reboots to the normal login screen.
