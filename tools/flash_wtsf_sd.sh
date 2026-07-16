#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/flash_wtsf_sd.sh --image IMAGE --device /dev/sdX --yes

Writes a raw WTSF image directly to an SD card block device. This destroys the
target device contents. The script refuses mounted devices and requires --yes.
EOF
}

image=""
device=""
yes=0
bs="4M"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      image="$2"
      shift 2
      ;;
    --device)
      device="$2"
      shift 2
      ;;
    --bs)
      bs="$2"
      shift 2
      ;;
    --yes)
      yes=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$image" ] || [ -z "$device" ]; then
  usage >&2
  exit 2
fi
if [ "$yes" -ne 1 ]; then
  echo "refusing to write without --yes" >&2
  exit 2
fi
if [ ! -f "$image" ]; then
  echo "image not found: $image" >&2
  exit 1
fi
if [ ! -b "$device" ]; then
  echo "device is not a block device: $device" >&2
  exit 1
fi

device_real=$(readlink -f "$device")
root_dev=$(findmnt -no SOURCE / || true)
if [ -n "$root_dev" ] && [ "$(readlink -f "$root_dev")" = "$device_real" ]; then
  echo "refusing to write the root filesystem device: $device" >&2
  exit 1
fi

if lsblk -nr -o MOUNTPOINT "$device" | grep -qv '^$'; then
  echo "refusing to write mounted device: $device" >&2
  lsblk "$device" >&2
  exit 1
fi

echo "About to overwrite $device with $image" >&2
lsblk "$device" >&2

if [ "$(id -u)" -eq 0 ]; then
  dd if="$image" of="$device" bs="$bs" status=progress conv=fsync
else
  sudo dd if="$image" of="$device" bs="$bs" status=progress conv=fsync
fi
sync
echo "wrote $image to $device"
