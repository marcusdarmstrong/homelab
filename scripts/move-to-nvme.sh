#!/usr/bin/env bash
# Install Raspberry Pi OS onto this Pi's NVMe drive and reboot into it.
#
# Run for you by scripts/provision.sh, as root, on a host whose settings say
# HOST_STORAGE=ssd but which booted from the SD card it was imaged on. Writes
# the latest Raspberry Pi OS Lite to the NVMe and carries over what Raspberry
# Pi Imager customized on the card (its cloud-init files and kernel command
# line additions) plus the SSH host keys, so the host comes back as itself.
# Then erases the card's partition table, so the Pi boots from the NVMe
# whether or not the card stays in, and reboots.
#
#   move-to-nvme.sh [--wipe]   --wipe: the NVMe isn't blank; overwrite it
set -euo pipefail

IMAGE_URL=https://downloads.raspberrypi.com/raspios_lite_arm64_latest
SD=/dev/mmcblk0
NVME=/dev/nvme0n1

log() { printf '\033[1m[move-to-nvme]\033[0m %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

wipe=0
[[ "${1:-}" != --wipe ]] || wipe=1

[[ $EUID -eq 0 ]] || die "run as root"
[[ "$(findmnt -no SOURCE /)" == "${SD}p2" ]] || die "not booted from the SD card"
[[ -b $NVME ]] || die "no NVMe drive"
if (($(lsblk -no NAME "$NVME" | wc -l) > 1)) && ((!wipe)); then
  die "$NVME already has partitions; pass --wipe to overwrite it"
fi
for f in user-data meta-data network-config cmdline.txt; do
  [[ -f /boot/firmware/$f ]] || die "no /boot/firmware/$f; image the card with Raspberry Pi Imager"
done

work="$(mktemp -d /var/tmp/move-to-nvme.XXXXXX)"
cleanup() {
  umount "$work/boot" "$work/root" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$IMAGE_URL")"
log "downloading $url"
curl -fL --progress-bar -o "$work/image.img.xz" "$url"
[[ "$(curl -fsSL "$url.sha256" | cut -d' ' -f1)" == "$(sha256sum "$work/image.img.xz" | cut -d' ' -f1)" ]] ||
  die "image checksum mismatch"

log "writing $NVME"
wipefs --all --quiet "$NVME"
xz -dc "$work/image.img.xz" | dd of="$NVME" bs=4M conv=fsync status=progress
rm -f "$work/image.img.xz"
partprobe "$NVME"
udevadm settle

mkdir "$work/boot" "$work/root"
mount "${NVME}p1" "$work/boot"
mount "${NVME}p2" "$work/root"

# Imager's customization: cloud-init creates the user, sets the hostname and
# the network on first boot.
cp /boot/firmware/{user-data,meta-data,network-config} "$work/boot/"
# And the kernel arguments it added (the cloud-init datasource, the Wi-Fi
# country): anything on the card's command line the image's lacks, except
# root=, which must stay the image's own.
cmdline="$(cat "$work/boot/cmdline.txt")"
read -ra card_args </boot/firmware/cmdline.txt
for arg in "${card_args[@]}"; do
  [[ $arg == root=* || " $cmdline " == *" ${arg%%=*}="* || " $cmdline " == *" $arg "* ]] || cmdline+=" $arg"
done
printf '%s\n' "$cmdline" >"$work/boot/cmdline.txt"

# Keep the SSH host keys, so ssh still trusts the host after the move. First
# boot would otherwise delete and regenerate them.
cp -a /etc/ssh/ssh_host_* "$work/root/etc/ssh/"
ln -sf /dev/null "$work/root/etc/systemd/system/regenerate_ssh_host_keys.service"

umount "$work/boot" "$work/root"
sync

# The bootloader tries the SD card first; without a partition table it moves
# on to the NVMe. (The running system has its partitions open already.)
log "erasing the SD card's partition table"
dd if=/dev/zero of="$SD" bs=1M count=1 conv=fsync status=none

log "rebooting from the NVMe"
systemd-run --quiet --on-active=3 systemctl reboot
