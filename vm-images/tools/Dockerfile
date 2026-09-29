# The tools a disk is assembled with: nothing here ends up in an image
FROM debian:trixie-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    grub-efi-amd64-bin grub-pc-bin grub2-common grub-common mtools dosfstools \
    fdisk e2fsprogs qemu-utils zstd xz-utils genisoimage ca-certificates \
    && rm -rf /var/lib/apt/lists/*
