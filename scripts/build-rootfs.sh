#!/usr/bin/env bash
#
# Build bootable ext4 cloud images (.img) for Debian, Ubuntu and Alpine.
#
#   DISTRO  debian | ubuntu | alpine   ($1)
#   ARCH    amd64 | arm64 | armhf | ... (env; default amd64)
#
# Each distro is provisioned into a Docker image instead of being bootstrapped
# on the runner: images/<distro>/Dockerfile (with its COPY-able config files)
# installs dropbear, networking and slimmes the base. The container is exported
# with `docker export`, unpacked, and projected onto a raw ext4 image that is
# shrunk to its exact minimum (resize2fs -M, no journal, no reserved blocks).
#
# A public SSH key may be baked into the images by setting OPENWORLD_PUBKEY;
# without it the images still boot but have no ssh-configured account.
set -euo pipefail

DISTRO="${1:?usage: build-rootfs.sh <debian|ubuntu|alpine>}"
ARCH="${ARCH:-amd64}"
PUBKEY="${OPENWORLD_PUBKEY:-}"

OUT="dist"
ROOTFS="$(mktemp -d)"
BLDDIR="images/$DISTRO"
TAG="openworld-$DISTRO:$ARCH"

trap 'sudo rm -rf "$ROOTFS"' EXIT
mkdir -p "$OUT"

case "$DISTRO" in
  debian|ubuntu|alpine) ;;
  *) echo "error: unknown distro '$DISTRO' (use debian, ubuntu or alpine)" >&2; exit 1 ;;
esac
[ -d "$BLDDIR" ] || { echo "error: no Dockerfile context at $BLDDIR" >&2; exit 1; }

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found in PATH" >&2
  exit 1
fi
# GitHub-hosted runners install docker but do not start the daemon
if ! docker info >/dev/null 2>&1; then
  sudo service docker start >/dev/null 2>&1 || sudo systemctl start docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || { echo "error: cannot talk to the docker daemon" >&2; exit 1; }
fi

echo "building rootfs for $DISTRO ($ARCH) from $BLDDIR"
if docker buildx version >/dev/null 2>&1; then
  args=(buildx build --platform "linux/$ARCH" --load -t "$TAG" -f "$BLDDIR/Dockerfile" "$BLDDIR")
  [ -n "$PUBKEY" ] && args+=(--build-arg "OPENWORLD_PUBKEY=$PUBKEY")
  docker "${args[@]}"
elif [ "$ARCH" = "$(uname -m)" ]; then
  # no buildx: native builds can still use the classic builder
  docker build -t "$TAG" --build-arg "OPENWORLD_PUBKEY=$PUBKEY" -f "$BLDDIR/Dockerfile" "$BLDDIR"
else
  echo "error: cross-arch ($ARCH) builds need buildx (docker buildx version fails)" >&2
  exit 1
fi

# the container is never started; export its (flattened) rootfs directly
cid="$(docker create "$TAG" /bin/true)"
docker export "$cid" | sudo tar -xzf - -C "$ROOTFS"
docker rm -f "$cid" >/dev/null 2>&1 || true

# docker plants its runtime /etc/{hostname,hosts,resolv.conf} into the export;
# drop them so the booted image carries its own (dhclient writes resolv.conf at
# first boot)
sudo rm -f "$ROOTFS/.dockerenv" \
  "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/hostname" "$ROOTFS/etc/hosts"
printf '%s\n' "$DISTRO" | sudo tee "$ROOTFS/etc/hostname" >/dev/null
printf '%s\n' \
  "127.0.0.1 localhost" \
  "::1 localhost" \
  "127.0.1.1 $DISTRO" | sudo tee "$ROOTFS/etc/hosts" >/dev/null

# name the image after the suite/version the base resolved to
VER="$(awk -F= '/^VERSION_CODENAME=/{print $2; exit}' "$ROOTFS/etc/os-release")"
[ -n "$VER" ] || VER="$(awk -F= '/^VERSION_ID=/{print $2; exit}' "$ROOTFS/etc/os-release")"
[ -n "$VER" ] || { echo "error: could not resolve a version from etc/os-release" >&2; exit 1; }
NAME="$DISTRO-$VER-$ARCH"

# Project the rootfs onto a raw ext4 disk image, then shrink the filesystem
# (resize2fs -M) so the .img is the smallest size that fits. The filesystem is
# created with 4k blocks, no reserved blocks and no journal so that
# resize2fs -M's computed minimum matches what e2fsck accepts, letting the
# file be truncated to exactly the final block count.
make_img() { # $1 img path  $2 rootfs dir
  local img="$1" root="$2"
  local used blocks mnt
  used="$(sudo du -sB 4096 "$root" | cut -f1)"
  # 12% headroom for ext4 metadata (du -sB 4096 already counts in 4k blocks)
  blocks=$(( used * 112 / 100 ))
  # 64 MiB floor keeps the filesystem sane for tiny rootfs builds
  [ "$blocks" -ge 16384 ] || blocks=16384
  truncate -s $((blocks * 4096)) "$img"
  sudo mkfs.ext4 -q -F -m 0 -O ^has_journal,^metadata_csum -b 4096 "$img"
  mnt="$(mktemp -d)"
  sudo mount -o loop "$img" "$mnt"
  sudo cp -a "$root"/. "$mnt"/
  sudo umount "$mnt"
  sudo rmdir "$mnt"

  sudo e2fsck -fy "$img" >/dev/null 2>&1
  sudo resize2fs -M "$img" >/dev/null 2>&1
  blocks="$(sudo dumpe2fs -h "$img" 2>/dev/null | awk '/^Block count:/{print $3}')"
  [ -n "$blocks" ] || { echo "error: could not read shrunk block count from $img" >&2; exit 1; }
  truncate -s $((blocks * 4096)) "$img"
  # belt and suspenders: the shrunk fs must pass a full check
  sudo e2fsck -fn "$img" >/dev/null 2>&1 || {
    echo "error: shrunk $img fails e2fsck" >&2
    sudo e2fsck -fn "$img" >&2 || true
    exit 1
  }
}

report() {
  local size
  size="$(du -h "$1" | cut -f1)"
  echo "$1 ($size)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '| %s | %s |\n' "$NAME" "$size" >> "$GITHUB_STEP_SUMMARY"
  fi
}

if ! command -v xz >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
  sudo apt-get update -qq >/dev/null 2>&1 || true
  sudo apt-get install -y -qq xz-utils e2fsprogs >/dev/null 2>&1 || true
fi

IMG="$OUT/$NAME.img"
make_img "$IMG" "$ROOTFS"
( cd "$OUT" && sha256sum "$NAME.img" > "$NAME-SHA256SUMS" )
report "$IMG"