#!/usr/bin/env bash
#
# Build minimal rootfs tarballs for Debian, Ubuntu and Alpine.
# Each distro always targets its latest stable release.
#
#   DISTRO  debian | ubuntu | alpine   ($1)
#   ARCH    amd64 | arm64 | armhf | ... (env; default amd64)
#
# Debian/Ubuntu         debootstrap (minbase) using the suite's own
#                       debootstrap package so brand-new codenames work.
#                       Cross-arch uses debootstrap --foreign plus a
#                       qemu-user-static emulator for the chrooted second
#                       stage (no emulator is baked into the final image).
# Alpine                downloads and verifies the official minirootfs
#                       tarball; it is multi-arch by construction.
set -euo pipefail

DISTRO="${1:?usage: build-rootfs.sh <debian|ubuntu|alpine>}"
ARCH="${ARCH:-amd64}"

OUT="dist"
ROOTFS="$(mktemp -d)"
ARCHIVE="${ROOTFS}.tgz"
PY="${ROOTFS}.py"
DBROOT=""

trap 'sudo rm -rf "$ROOTFS" "$ARCHIVE" "$PY" "$DBROOT"' EXIT
mkdir -p "$OUT"

if ! command -v xz >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
  sudo apt-get update -qq >/dev/null 2>&1 || true
  sudo apt-get install -y -qq xz-utils e2fsprogs >/dev/null 2>&1 || true
fi

pack() { # $1 tarball  $2 rootfs dir
  sudo tar --numeric-owner --use-compress-program='xz -9e --threads=0' \
    -c -f "$1" -C "$2" .
}

# Project the rootfs onto a raw ext4 disk image, then shrink the filesystem
# (resize2fs -M) so the .img is the smallest size that fits. The filesystem is
# created with 4k blocks, no reserved blocks and no journal so that
# resize2fs -M's computed minimum matches what e2fsck accepts, letting the
# file be truncated to exactly the final block count.
make_img() { # $1 img path  $2 rootfs dir
  local img="$1" root="$2"
  local used blocks mnt
  used="$(sudo du -sB 4096 "$root" | cut -f1)"
  # 12% headroom for ext4 metadata; resize2fs -M reclaims everything unused
  # (du -sB 4096 already counts in 4k blocks, so no extra rounding needed)
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

surf_log() { # $1 rootfs dir - surface debootstrap's own log on failure
  [ -f "$1/debootstrap/debootstrap.log" ] || return 0
  echo "--- debootstrap.log ---" >&2
  sudo tail -n 40 "$1/debootstrap/debootstrap.log" >&2 || true
}

# Fetch and unpack the debootstrap package the target suite itself ships.
# That exact build is validated against the release we are bootstrapping,
# so a brand-new codename never depends on a stale host debootstrap.
suite_debootstrap() { # $1 suite  $2 mirror-base
  local suite="$1" base="$2" ver file
  DBROOT="$(mktemp -d)"
  if ! curl -fsSL --retry 3 -o "$DBROOT/Packages.gz" \
      "$base/dists/$suite/main/binary-$ARCH/Packages.gz"; then
    sudo rm -rf "$DBROOT"; return 1
  fi
  # awk reads the whole stream (no early exit) so gzip never gets a SIGPIPE
  ver="$(gzip -dc "$DBROOT/Packages.gz" | awk '/^Package: debootstrap$/{p=1; next} p && /^Version:/{print $2; p=0}')"
  [ -n "$ver" ] || { sudo rm -rf "$DBROOT"; return 1; }
  file="${ver//+/%2b}"
  if ! curl -fsSL --retry 3 -o "$DBROOT/debootstrap.deb" \
      "$base/pool/main/d/debootstrap/debootstrap_${file}_all.deb"; then
    sudo rm -rf "$DBROOT"; return 1
  fi
  dpkg -x "$DBROOT/debootstrap.deb" "$DBROOT"
  DEBOOTSTRAP="$DBROOT/usr/sbin/debootstrap"
  DEBOOTSTRAP_DIR="$DBROOT/usr/share/debootstrap"
  SCRIPTS="$DEBOOTSTRAP_DIR/scripts"
}

# Map a Debian/Ubuntu arch to its static qemu user-mode emulator.
cross_qemu() { # $1 debian/ubuntu arch
  case "$1" in
    amd64)   echo qemu-x86_64-static ;;
    i386)    echo qemu-i386-static ;;
    arm64)   echo qemu-aarch64-static ;;
    armhf|armel) echo qemu-arm-static ;;
    riscv64) echo qemu-riscv64-static ;;
    s390x)   echo qemu-s390x-static ;;
    ppc64el) echo qemu-ppc64le-static ;;
    *)       return 1 ;;
  esac
}

# Alpine names its ports differently from Debian (x86_64, aarch64, armv7).
alpine_arch() { # $1 debian-style arch
  case "$1" in
    amd64)   echo x86_64 ;;
    i386)    echo x86 ;;
    arm64)   echo aarch64 ;;
    armhf)   echo armv7 ;;
    riscv64) echo riscv64 ;;
    s390x)   echo s390x ;;
    ppc64el) echo ppc64le ;;
    *)       return 1 ;;
  esac
}

# Install qemu-user-static on the host and make sure binfmt_misc dispatches
# foreign binaries (dpkg, sh, maintainer scripts) to the emulator.
qemu_bootstrap() { # $1 target arch
  local qemu
  qemu="/usr/bin/$(cross_qemu "$1")" || {
    echo "error: no qemu emulator for arch '$1'" >&2
    return 1
  }
  if [ ! -x "$qemu" ]; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y --no-install-recommends qemu-user-static binfmt-support >/dev/null
  fi
  [ -x "$qemu" ] || { echo "error: qemu-user-static does not provide $qemu" >&2; return 1; }
  sudo mkdir -p /proc/sys/fs/binfmt_misc 2>/dev/null || true
  sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc >/dev/null 2>&1 || true
  sudo /usr/lib/systemd/systemd-binfmt >/dev/null 2>&1 || true
  sudo update-binfmts --import >/dev/null 2>&1 || true
  CROSS=1
}

case "$DISTRO" in

  debian|ubuntu)
    if [ "$DISTRO" = debian ]; then
      MIRROR="http://deb.debian.org/debian"
      SUITE="$(curl -fsSL --retry 3 "$MIRROR/dists/stable/Release" | awk '/^Codename:/{print $2}')"
    else
      MIRROR="http://archive.ubuntu.com/ubuntu"
      SUITE="$(curl -fsSL --retry 3 https://changelogs.ubuntu.com/meta-release | awk '/^Dist:/{c=$2} END{print c}')"
    fi
    [ -n "$SUITE" ] || { echo "error: could not resolve the latest suite for $DISTRO" >&2; exit 1; }
    echo "bootstrapping $DISTRO $SUITE ($ARCH)"

    CROSS=0
    if [ "$ARCH" != "$(dpkg --print-architecture)" ]; then
      qemu_bootstrap "$ARCH"
    fi

    if suite_debootstrap "$SUITE" "$MIRROR"; then
      echo "using the debootstrap $SUITE itself ships"
    elif [ -f "/usr/share/debootstrap/scripts/$SUITE" ] && command -v debootstrap >/dev/null 2>&1; then
      echo "warning: using the system debootstrap" >&2
      DEBOOTSTRAP="$(command -v debootstrap)"
      DEBOOTSTRAP_DIR=""
      SCRIPTS="/usr/share/debootstrap/scripts"
    else
      echo "error: could not find a debootstrap with a script for suite '$SUITE'" >&2
      exit 1
    fi
    [ -f "$SCRIPTS/$SUITE" ] || {
      echo "error: no debootstrap script for suite '$SUITE'" >&2
      exit 1
    }

    # --foreign only downloads and unpacks; the chrooted second stage runs
    # afterwards (via the qemu emulator for cross-arch). Keeps one code path
    # for native and foreign builds and fails early and clearly on emulation
    # problems instead of mid-install.
    #
    # minbase pulls in everything dpkg needs (diffutils and tzdata are
    # Priority: required, so they must NOT be excluded or dpkg's own sanity
    # check aborts with "expected program not found in PATH"). Only the
    # "important" e2fsprogs is excluded, and the tzdata payload is trimmed in
    # slim.sh instead of the package being removed.
    attempts=0
    while :; do
      attempts=$((attempts + 1))
      if sudo env DEBOOTSTRAP_DIR="$DEBOOTSTRAP_DIR" "$DEBOOTSTRAP" \
          --foreign --variant=minbase --components=main \
          --include=ca-certificates \
          --exclude=e2fsprogs \
          --arch "$ARCH" "$SUITE" "$ROOTFS" "$MIRROR"; then

        if [ "$CROSS" = 1 ]; then
          # the unpacked packages are foreign ELF binaries; prove binfmt/qemu
          # can run them before the long second stage
          if ! sudo chroot "$ROOTFS" /bin/sh -c 'exit 0' 2>/dev/null; then
            echo "error: cannot execute $ARCH binaries (binfmt_misc/qemu not active)." >&2
            echo 'hint: sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc && sudo systemctl restart systemd-binfmt' >&2
            exit 1
          fi
        fi

        if sudo chroot "$ROOTFS" /debootstrap/debootstrap --second-stage; then
          break
        fi
        echo "debootstrap --second-stage failed (attempt $attempts)..." >&2
      else
        echo "debootstrap first stage failed (attempt $attempts)..." >&2
      fi
      surf_log "$ROOTFS"
      if [ "$attempts" -ge 2 ]; then
        echo "error: debootstrap failed after $attempts attempts" >&2
        exit 1
      fi
      # second stage leaves dpkg/status half-written; retrying it in place
      # only corrupts it further, so start both stages from a clean target
      echo "retrying debootstrap from scratch (attempt $((attempts + 1)))..." >&2
      sudo rm -rf "$ROOTFS"
      sudo mkdir -p "$ROOTFS"
    done
    sudo rm -rf "$ROOTFS/debootstrap"

    cat > "$ROOTFS/tmp/slim.sh" <<'STAGE'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive

# never auto-install recommends/suggests, never start services while imaging
printf 'APT::Get::Install-Recommends "false";\nAPT::Get::Install-Suggests "false";\n' \
  > /etc/apt/apt.conf.d/99minimal
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d

# e2fsprogs is the one thing a container never needs; tzdata and diffutils
# are intentionally kept (installed, slimmed) so dpkg/apt still work
dpkg --force-all --purge e2fsprogs 2>/dev/null || true

# docs, man/info pages and almost all locale/zone data are dead weight
rm -rf /usr/share/doc /usr/share/man /usr/share/info \
       /usr/share/lintian /usr/share/doc-base /usr/share/bug
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name en -exec rm -rf {} + 2>/dev/null || true
find /usr/share/zoneinfo -mindepth 1 ! -path '/usr/share/zoneinfo/Etc*' -exec rm -rf {} + 2>/dev/null || true

rm -rf /var/log /var/tmp /tmp/* /run /var/backups
rm -rf /var/cache/debconf /var/cache/ldconfig
# the .deb payload debootstrap unpacked is dead weight now; dropping it
# (and the package indexes, which `apt-get update` regenerates) slims both
# the tarball and the disk image
rm -f /var/cache/apt/archives/*.deb
rm -rf /var/lib/apt/lists/*
mkdir -p /run /var/lib/apt/lists/partial /var/cache/apt/archives/partial /var/log/apt
STAGE
    # the file is owned by the (unprivileged) runner user with mode 0644, so
    # chroot cannot exec it directly; hand it to the target's /bin/sh instead
    sudo chroot "$ROOTFS" /bin/sh /tmp/slim.sh
    sudo rm -f "$ROOTFS/tmp/slim.sh"

    sudo chroot "$ROOTFS" /bin/bash -c \
      'command -v bash && command -v openssl && [ -d /etc/ssl/certs ] && [ -f /etc/os-release ] && echo "rootfs OK: shell + openssl + CA certs present"'

    NAME="$DISTRO-$SUITE-$ARCH"
    ;;

  alpine)
    REL="latest-stable"
    AARCH="$(alpine_arch "$ARCH")" || { echo "error: no alpine port for arch '$ARCH'" >&2; exit 1; }
    MANIFEST="$(curl -fsSL --retry 3 \
      "https://dl-cdn.alpinelinux.org/alpine/$REL/releases/$AARCH/latest-releases.yaml")"
    cat > "$PY" <<'PY'
import sys

def fields(block):
    cur = {}
    for line in block.splitlines():
        s = line.strip()
        if ":" in s:
            k, v = (p.strip() for p in s.split(":", 1))
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            cur[k] = v
    return cur

for block in sys.argv[1].split("-\n"):
    cur = fields(block)
    if cur.get("flavor") == "alpine-minirootfs" and cur.get("file"):
        print(cur["version"], cur["file"], cur["sha256"])
        break
PY
    if ! read -r AV FNAME SHA <<< "$(python3 "$PY" "$MANIFEST")"; then
      echo "error: could not resolve an alpine-minirootfs for $ARCH" >&2
      exit 1
    fi
    [ -n "$FNAME" ] && [ -n "$SHA" ] || { echo "error: incomplete minirootfs lookup" >&2; exit 1; }
    echo "downloading alpine $AV ($ARCH)"

    curl -fsSL --retry 3 -o "$ARCHIVE" \
      "https://dl-cdn.alpinelinux.org/alpine/$REL/releases/$AARCH/$FNAME"
    echo "$SHA  $ARCHIVE" | sha256sum -c -
    sudo mkdir -p "$ROOTFS"
    sudo tar -xzf "$ARCHIVE" -C "$ROOTFS"
    sudo rm -f "$ARCHIVE"

    # The minirootfs is a build base, not a bootable system: its inittab (and
    # busybox's /sbin/init) hand control to /sbin/openrc, which is missing.
    # Install openrc so /sbin/init -> openrc-init is real, and boot the
    # classic ttyS0 serial console. Cross-arch needs the qemu emulator to
    # run the target's apk inside the chroot.
    if [ "$AARCH" != "$(uname -m)" ]; then
      qemu_bootstrap "$ARCH"
    fi
    # the minirootfs has no resolv.conf, which makes DNS inside the (possibly
    # qemu-emulated) chroot flaky; borrow the host's for the install step only
    sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
    cat > "$ROOTFS/tmp/setup.sh" <<'SETUP'
#!/bin/sh
set -e
i=0
until apk update >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 5 ] || { echo "apk update failed after 5 tries" >&2; exit 1; }
  echo "apk update retry $i..." >&2
  sleep "$((i * 5))"
done
i=0
until apk add --no-cache openrc >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 5 ] || { echo "apk add openrc failed after 5 tries" >&2; exit 1; }
  echo "apk add openrc retry $i..." >&2
  sleep "$((i * 5))"
done
# serial console so a VM gets a login prompt
printf 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100\n' >> /etc/inittab
# minimal early services: /dev and /sys (mdev is a separate package and
# unnecessary for booting to a serial console, devtmpfs already provides ttys)
rc-update add devfs sysinit
rc-update add sysfs sysinit
mkdir -p /run/openrc
touch /run/openrc/softlevel
SETUP
    sudo chroot "$ROOTFS" /bin/sh /tmp/setup.sh
    sudo rm -f "$ROOTFS/tmp/setup.sh" "$ROOTFS/etc/resolv.conf"

    sudo rm -rf "$ROOTFS/var/cache/apk"/* "$ROOTFS/var/log" \
      "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/info"
    sudo rm -f "$ROOTFS/etc/motd"

    NAME="alpine-$AV-$ARCH"
    ;;

  *)
    echo "error: unknown distro '$DISTRO' (use debian, ubuntu or alpine)" >&2
    exit 1
    ;;
esac

ARTIFACT="$OUT/$NAME-rootfs.tar.xz"
IMG="$OUT/$NAME.img"
pack "$ARTIFACT" "$ROOTFS"
make_img "$IMG" "$ROOTFS"
( cd "$OUT" && sha256sum "$NAME-rootfs.tar.xz" "$NAME.img" > "$NAME-SHA256SUMS" )
report "$ARTIFACT"
report "$IMG"