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
  local used blocks mnt cinit=0
  used="$(sudo du -sB 4096 "$root" | cut -f1)"
  if [ -f "$root/tmp/cloud-init.sh" ]; then
    cinit=1
    # cloud-init + python3 + systemd add a lot of packages; oversize the
    # staging fs (mkfs writes all of it) and let resize2fs -M reclaim the
    # slack afterwards, so the shipped .img stays minimal
    blocks=$(( used * 400 / 100 ))
    [ "$blocks" -ge 262144 ] || blocks=262144   # 1 GiB floor for provisioning
  else
    # 12% headroom for ext4 metadata (du -sB 4096 already counts in 4k blocks)
    blocks=$(( used * 112 / 100 ))
  fi
  # 64 MiB floor keeps the filesystem sane for tiny rootfs builds
  [ "$blocks" -ge 16384 ] || blocks=16384
  truncate -s $((blocks * 4096)) "$img"
  sudo mkfs.ext4 -q -F -m 0 -O ^has_journal,^metadata_csum -b 4096 "$img"
  mnt="$(mktemp -d)"
  sudo mount -o loop "$img" "$mnt"
  sudo cp -a "$root"/. "$mnt"/

  if [ "$cinit" = 1 ]; then
    # package maintainer scripts expect /proc,/sys,/dev (debootstrap mounts
    # them during its own second stage); hand the fresh image the host's so
    # the cloud-init install behaves. The minirootfs also has no resolv.conf.
    sudo mkdir -p "$mnt/proc" "$mnt/sys" "$mnt/dev"
    sudo mount --bind /proc "$mnt/proc"
    sudo mount --bind /sys "$mnt/sys"
    sudo mount --bind /dev "$mnt/dev"
    sudo cp /etc/resolv.conf "$mnt/etc/resolv.conf" 2>/dev/null || true
    if ! sudo chroot "$mnt" /bin/sh /tmp/cloud-init.sh; then
      echo "error: cloud-init provisioning failed inside $img" >&2
      sudo umount "$mnt/dev" "$mnt/sys" "$mnt/proc" 2>/dev/null || true
      sudo umount "$mnt" 2>/dev/null || true
      sudo rmdir "$mnt" 2>/dev/null || true
      exit 1
    fi
    sudo umount "$mnt/dev" "$mnt/sys" "$mnt/proc"
    # don't ship the build host's network config or the setup script
    sudo rm -f "$mnt/etc/resolv.conf" "$mnt/tmp/cloud-init.sh"
  fi

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

# Write a provisioning script for the .img: cloud-init is only baked into the
# disk images (the rootfs tarballs stay bare). The script is placed in the
# rootfs' world-writable /tmp so make_img can chroot into the mounted image
# and run it; afterwards it is removed from both artifacts.
make_cloud_init() { # uses $DISTRO and writes $ROOTFS/tmp/cloud-init.sh
  case "$DISTRO" in
    debian)
      cat > "$ROOTFS/tmp/cloud-init.sh" <<'CI'
#!/bin/sh
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
i=0
until apt-get update -qq 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 5 ] || { echo "apt-get update failed after 5 tries" >&2; exit 1; }
  echo "apt-get update retry $i..." >&2
  sleep "$((i * 5))"
done
apt-get install -y --no-install-recommends \
  systemd-sysv cloud-init dropbear ifupdown >/dev/null
# force the NoCloud datasource and keep networking on plain ifupdown DHCP so a
# missing seed never wedges the boot; root is never logged into via ssh,
# users are provisioned from the seed with ssh keys
cat > /etc/cloud/cloud.cfg.d/99-openworld.cfg <<'EOF'
datasource_list: [ NoCloud ]
disable_root: true
ssh_pwauth: false
network:
  config: disabled
EOF
cat > /etc/network/interfaces <<'EOF'
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
apt-get clean
rm -rf /var/lib/apt/lists/*
CI
      ;;
    ubuntu)
      cat > "$ROOTFS/tmp/cloud-init.sh" <<'CI'
#!/bin/sh
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
# minbase enabled only 'main'; dropbear-run lives in universe, so enable it
# for whatever suites are configured (deb822 or legacy sources.list)
f="$(grep -rl '^Components:.*' /etc/apt/sources.list.d/ 2>/dev/null | head -1)"
if [ -n "$f" ]; then
  [ "$(grep -c 'universe' "$f" || true)" -eq 0 ] && sed -i 's/^Components:.*/& universe/' "$f"
fi
[ ! -f /etc/apt/sources.list ] || \
  [ "$(grep -c 'universe' /etc/apt/sources.list)" -gt 0 ] || \
  sed -i 's/^deb \(.*\) main\( .*\)$/deb \1 main universe\2/' /etc/apt/sources.list
i=0
until apt-get update -qq 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 5 ] || { echo "apt-get update failed after 5 tries" >&2; exit 1; }
  echo "apt-get update retry $i..." >&2
  sleep "$((i * 5))"
done
apt-get install -y --no-install-recommends \
  systemd-sysv cloud-init dropbear-run netplan.io >/dev/null
# netplan renders through systemd-networkd; ensure it is enabled at boot
systemctl enable systemd-networkd.service >/dev/null 2>&1 || true
# NoCloud only, root ssh disabled; Ubuntu's network is netplan + systemd-networkd
# (ifupdown is not in Ubuntu main anymore), still left out of cloud-init's hands
cat > /etc/cloud/cloud.cfg.d/99-openworld.cfg <<'EOF'
datasource_list: [ NoCloud ]
disable_root: true
ssh_pwauth: false
network:
  config: disabled
EOF
cat > /etc/netplan/99-openworld.yaml <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
EOF
chmod 0600 /etc/netplan/99-openworld.yaml
apt-get clean
rm -rf /var/lib/apt/lists/*
CI
      ;;
    alpine)
      cat > "$ROOTFS/tmp/cloud-init.sh" <<'CI'
#!/bin/sh
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
i=0
until apk update >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 5 ] || { echo "apk update failed after 5 tries" >&2; exit 1; }
  echo "apk update retry $i..." >&2
  sleep "$((i * 5))"
done
i=0
until apk add --no-cache cloud-init dropbear netifrc \
    >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 5 ] || { echo "apk add cloud-init failed after 5 tries" >&2; exit 1; }
  echo "apk add cloud-init retry $i..." >&2
  sleep "$((i * 5))"
done
# the alpine cloud-init apk ships no init scripts: wire up the four stages as
# OpenRC services mirroring the upstream systemd unit ordering
cat >/etc/init.d/cloud-init-local <<'EOF'
#!/sbin/openrc-run
description="cloud-init local init stage"
depend() { need sysfs devfs; }
start() {
  ebegin "cloud-init init --local"
  /usr/bin/cloud-init init --local
  eend $?
}
EOF
cat >/etc/init.d/cloud-init <<'EOF'
#!/sbin/openrc-run
description="cloud-init init stage"
depend() { need networking cloud-init-local; }
start() {
  ebegin "cloud-init init"
  /usr/bin/cloud-init init
  eend $?
}
EOF
cat >/etc/init.d/cloud-config <<'EOF'
#!/sbin/openrc-run
description="cloud-init config stage"
depend() { need cloud-init; }
start() {
  ebegin "cloud-init modules --mode=config"
  /usr/bin/cloud-init modules --mode=config
  eend $?
}
EOF
cat >/etc/init.d/cloud-final <<'EOF'
#!/sbin/openrc-run
description="cloud-init final stage"
depend() { need cloud-config; }
start() {
  ebegin "cloud-init modules --mode=final"
  /usr/bin/cloud-init modules --mode=final
  eend $?
}
EOF
chmod +x /etc/init.d/cloud-init-local /etc/init.d/cloud-init \
  /etc/init.d/cloud-config /etc/init.d/cloud-final
# dropbear is the ssh server; it ships no init script either, so write one
cat >/etc/init.d/dropbear <<'EOF'
#!/sbin/openrc-run
description="Dropbear SSH server"
depend() { need net; }

start() {
  [ -f /etc/dropbear/dropbear_rsa_host_key ] || \
    /usr/bin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null
  [ -f /etc/dropbear/dropbear_ed25519_host_key ] || \
    /usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null
  ebegin "Starting dropbear sshd"
  start-stop-daemon --start --quiet --background --make-pidfile \
    --pidfile /run/$RC_SVCNAME.pid --exec /usr/sbin/dropbear -- -p 22 \
      -r /etc/dropbear/dropbear_rsa_host_key \
      -r /etc/dropbear/dropbear_ed25519_host_key
  eend $?
}

stop() {
  ebegin "Stopping dropbear sshd"
  start-stop-daemon --stop --quiet --pidfile /run/$RC_SVCNAME.pid
  eend $?
}
EOF
chmod +x /etc/init.d/dropbear
cat > /etc/cloud/cloud.cfg.d/99-openworld.cfg <<'EOF'
datasource_list: [ NoCloud ]
disable_root: true
ssh_pwauth: false
network:
  config: disabled
EOF
rc-update add cloud-init-local sysinit
rc-update add networking default
rc-update add dropbear default
rc-update add cloud-init default
rc-update add cloud-config default
rc-update add cloud-final default
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
CI
      ;;
  esac
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
make_cloud_init
make_img "$IMG" "$ROOTFS"
sudo rm -f "$ROOTFS/tmp/cloud-init.sh"
( cd "$OUT" && sha256sum "$NAME-rootfs.tar.xz" "$NAME.img" > "$NAME-SHA256SUMS" )
report "$ARTIFACT"
report "$IMG"