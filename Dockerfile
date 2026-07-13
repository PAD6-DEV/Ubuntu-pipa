FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    mmdebstrap debootstrap \
    dosfstools e2fsprogs fdisk gdisk util-linux \
    rsync wget curl ca-certificates \
    android-tools-adb android-tools-fastboot \
    grub-efi-arm64-bin shim-signed \
    zip xz-utils pigz \
    python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . /build/
ENTRYPOINT ["/build/scripts/ci-build.sh"]
