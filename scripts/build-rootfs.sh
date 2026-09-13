#!/usr/bin/env bash
#
# Build the smallest practical rootfs tarballs.
# Each distro always targets its latest stable release unless overridden.
#
#   DISTRO                debian | ubuntu | alpine   ($1)
#   ARCH                  amd64 | arm64 | ...        (env; only alpine supports cross-arch)
#   SUITE                 debian/ubuntu codename override (env, blank = latest stable)
#   ALPINE_VERSION        alpine major.minor override      (env, blank = latest stable)
#   MINIMAL               bare | slim                 (env; default slim)
#     slim  = keeps a working apt/dpkg so packages can be added later
#     bare  = no apt/dpkg/perl: absolute smallest, no package manager
set -euo pipefail

DISTRO="${1:?usage: build-rootfs.sh <debian|ubuntu|alpine>}"
ARCH="${ARCH:-amd64}"
MINIMAL="${MINIMAL:-slim}"
case "$MINIMAL" in
  bare|slim) ;;
  *) echo "error: MINIMAL must be bare or slim (got '$MINIMAL')" >&2; exit 1 ;;
esac

OUT="dist"
ROOTFS="$(mktemp -d)"
ARCHIVE="${ROOTFS}.tgz"
PY="${ROOTFS}.py"

DBROOT=""
DEBOOTSTRAP=""
DEBOOTSTRAP_DIR=""
trap 'sudo rm -rf "$ROOTFS" "$ARCHIVE" "$PY" "$DBROOT"' EXIT
mkdir -p "$OUT"

sudo apt-get update -qq >/dev/null 2>&1 || true
if ! command -v xz >/dev/null 2>&1; then
  sudo apt-get install -y -qq xz-utils >/dev/null 2>&1 || true
fi

pack() {
  sudo tar --numeric-owner --use-compress-program='xz -9e --threads=0' \
    -c -f "$1" -C "$2" .
}

print_report() {
  local size
  size="$(du -h "$1" | cut -f1)"
  echo "$NAME -> $1 ($size)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '| %s | %s |\n' "$NAME" "$size" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Fetch the debootstrap package that the TARGET suite itself was validated
# with (Debian/Ubuntu package this exact version for that release), so the
# bootstrap stays on a tested tool even when a brand-new codename appears.
# Running the newest package from the shared Debian pool is unsafe: that is
# usually an unreleased (sid) build with unvalidated suite scripts.
# debootstrap hardcodes DEBOOTSTRAP_DIR, so we point it at the extracted copy.
suite_debootstrap() { # $1 suite  $2 mirror-base-URL
  local suite="$1" base="$2" ver file
  DBROOT="$(mktemp -d)"
  local pkgs_gz="$DBROOT/Packages.gz" pkgs_raw="$DBROOT/Packages.txt"
  curl -fsSL --retry 3 -o "$pkgs_gz" "$base/dists/$suite/main/binary-$ARCH/Packages.gz" || { sudo rm -rf "$DBROOT"; return 1; }
  gzip -dc "$pkgs_gz" > "$pkgs_raw"
  ver="$(awk '/^Package: debootstrap$/{f=1; next} f && /^Version:/{print $2; exit}' "$pkgs_raw")"
  [ -n "$ver" ] || { sudo rm -rf "$DBROOT"; return 1; }
  file="${ver//+/%2b}"
  curl -fsSL --retry 3 -o "$DBROOT/db.deb" "$base/pool/main/d/debootstrap/debootstrap_${file}_all.deb" || { sudo rm -rf "$DBROOT"; return 1; }
  dpkg -x "$DBROOT/db.deb" "$DBROOT"
  DEBOOTSTRAP="$DBROOT/usr/sbin/debootstrap"
  DEBOOTSTRAP_DIR="$DBROOT/usr/share/debootstrap"
  scripts_dir="$DEBOOTSTRAP_DIR/scripts"
}

# Last resort: newest plain-numbered debootstrap in the shared Debian pool.
latest_pool_debootstrap() {
  local deb
  deb="$(curl -fsSL --retry 3 https://deb.debian.org/debian/pool/main/d/debootstrap/ \
    | grep -oE 'debootstrap_[0-9.]+_all\.deb' | sort -Vu | tail -1)"
  [ -n "$deb" ] || return 1
  DBROOT="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$DBROOT/db.deb" "https://deb.debian.org/debian/pool/main/d/debootstrap/$deb"
  dpkg -x "$DBROOT/db.deb" "$DBROOT"
  DEBOOTSTRAP="$DBROOT/usr/sbin/debootstrap"
  DEBOOTSTRAP_DIR="$DBROOT/usr/share/debootstrap"
  scripts_dir="$DEBOOTSTRAP_DIR/scripts"
}

# Static user-mode emulator (from qemu-user-static) for cross-arch debootstrap.
cross_qemu() { # $1 target debian/ubuntu arch
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

# Enable cross-architecture emulation on the host and prove it works. The
# static qemu binary is later copied into the target so chrooted foreign
# executables (dpkg, sh, maintainer scripts) can actually run.
cross_setup() { # $1 target arch
  CROSS=1
  QEMU_STATIC="/usr/bin/$(cross_qemu "$1")" || {
    echo "error: no qemu emulator available for arch '$1'" >&2
    return 1
  }
  if [ ! -x "$QEMU_STATIC" ]; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    ( sudo apt-get install -y --no-install-recommends qemu-user-static binfmt-support ) \
      >/dev/null 2>&1 || sudo apt-get install -y --no-install-recommends qemu-user-static binfmt-support
  fi
  [ -x "$QEMU_STATIC" ] || { echo "error: qemu-user-static has no $QEMU_STATIC" >&2; return 1; }
  # binfmt_misc must be mounted and the handler enabled so a chrooted foreign
  # binary is dispatched to qemu. Fresh runners sometimes need a nudge.
  sudo mkdir -p /proc/sys/fs/binfmt_misc 2>/dev/null || true
  sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc >/dev/null 2>&1 || true
  sudo /usr/lib/systemd/systemd-binfmt >/dev/null 2>&1 || true
  sudo update-binfmts --import >/dev/null 2>&1 || true
  echo "cross-build: emulating $1 with $QEMU_STATIC"
}

case "$DISTRO" in

  debian|ubuntu)
    if [ "$DISTRO" = debian ]; then
      MIRROR="${MIRROR:-http://deb.debian.org/debian}"
      SUITE="${SUITE:-$(curl -fsSL --retry 3 https://deb.debian.org/debian/dists/stable/Release | awk '/^Codename:/{print $2}')}"
    else
      MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
      SUITE="${SUITE:-$(curl -fsSL --retry 3 https://changelogs.ubuntu.com/meta-release | awk '/^Dist:/{c=$2} END{print c}')}"
    fi
    [ -n "$SUITE" ] || { echo "error: could not resolve the latest suite for $DISTRO" >&2; exit 1; }
    echo "building $DISTRO $SUITE from $MIRROR (minimal=$MINIMAL)"

    NATIVE="$(dpkg --print-architecture)"
    CROSS=0
    QEMU_STATIC=""
    if [ "$ARCH" != "$NATIVE" ]; then
      cross_setup "$ARCH" || exit 1
    fi

    if suite_debootstrap "$SUITE" "$MIRROR"; then
      DEBOOTSTRAP_VER="$(sed -n "s/^VERSION='\(.*\)'$/\1/p" "$DEBOOTSTRAP" | head -n1)"
      echo "using debootstrap ${DEBOOTSTRAP_VER:-} (the version $SUITE ships)"
    elif latest_pool_debootstrap; then
      DEBOOTSTRAP_VER="$(sed -n "s/^VERSION='\(.*\)'$/\1/p" "$DEBOOTSTRAP" | head -n1)"
      echo "warning: using debootstrap ${DEBOOTSTRAP_VER:-} from the shared Debian pool" >&2
    elif [ -f "/usr/share/debootstrap/scripts/$SUITE" ] && command -v debootstrap >/dev/null 2>&1; then
      echo "warning: using the system debootstrap" >&2
      DEBOOTSTRAP="$(command -v debootstrap)"
      DEBOOTSTRAP_DIR=""
      scripts_dir="/usr/share/debootstrap/scripts"
    else
      echo "error: could not find a debootstrap build for suite '$SUITE'" >&2
      exit 1
    fi

    [ -f "$scripts_dir/$SUITE" ] || {
      echo "error: no debootstrap script for suite '$SUITE'." >&2
      echo "hint: pass an explicit SUITE (e.g. bookworm, noble) or update debootstrap." >&2
      exit 1
    }

    # Cross-arch can't run foreign maintainer scripts during the first pass, so
    # debootstrap does --foreign (download + unpack only); the chrooted scripts
    # run afterwards under qemu. The static emulator must be inside the target
    # for both the second stage and our own min.sh chroot.
    BOOTSTRAP=()
    [ "$CROSS" = 1 ] && BOOTSTRAP+=(--foreign)

    # debootstrap is network-heavy and can fail transiently (broken mirror
    # download, etc); retry and surface its own log so the real cause shows up.
    attempts=0
    while ! sudo env DEBOOTSTRAP_DIR="$DEBOOTSTRAP_DIR" "$DEBOOTSTRAP" \
        "${BOOTSTRAP[@]}" --variant=minbase --components=main \
        --include=ca-certificates \
        --exclude=e2fsprogs,tzdata,diffutils \
        --arch "$ARCH" "$SUITE" "$ROOTFS" "$MIRROR"; do
      attempts=$((attempts + 1))
      if [ -f "$ROOTFS/debootstrap/debootstrap.log" ]; then
        echo "--- debootstrap.log (attempt $attempts) ---" >&2
        sudo tail -n 40 "$ROOTFS/debootstrap/debootstrap.log" >&2 || true
      fi
      if [ "$attempts" -ge 2 ]; then
        echo "error: debootstrap failed after $attempts attempts" >&2
        exit 1
      fi
      echo "debootstrap failed, retrying (attempt $attempts)..." >&2
      sudo rm -rf "$ROOTFS"
      sudo mkdir -p "$ROOTFS"
    done

    if [ "$CROSS" = 1 ]; then
      # the static emulator must be inside the target so chrooted foreign
      # binaries (sh, dpkg, maintainer scripts) can be dispatched to qemu
      sudo mkdir -p "$ROOTFS/usr/bin"
      sudo cp "$QEMU_STATIC" "$ROOTFS/usr/bin/"
      if ! sudo chroot "$ROOTFS" /bin/sh -c 'exit 0' 2>/dev/null; then
        echo "error: cannot run $ARCH binaries inside the target (binfmt_misc not active)." >&2
        echo 'hint: sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc && sudo systemctl restart systemd-binfmt' >&2
        exit 1
      fi
      # --foreign leaves the actual package configuration to the second stage
      attempts=0
      while ! sudo chroot "$ROOTFS" /debootstrap/debootstrap --second-stage; do
        attempts=$((attempts + 1))
        if [ -f "$ROOTFS/debootstrap/debootstrap.log" ]; then
          echo "--- debootstrap.log --second-stage (attempt $attempts) ---" >&2
          sudo tail -n 40 "$ROOTFS/debootstrap/debootstrap.log" >&2 || true
        fi
        if [ "$attempts" -ge 2 ]; then
          echo "error: debootstrap --second-stage failed after $attempts attempts" >&2
          exit 1
        fi
        echo "debootstrap --second-stage failed, retrying (attempt $attempts)..." >&2
        # --second-stage resumes from its partial state on a re-run
      done
    fi

    cat > "$ROOTFS/tmp/min.sh" <<'STAGE'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
MINIMAL="${MINIMAL:-slim}"

# never auto-install recommends/suggests, and never let maintainer scripts
# start services while we build the image
mkdir -p /usr/sbin /etc/apt/apt.conf.d
printf 'APT::Get::Install-Recommends "false";\nAPT::Get::Install-Suggests "false";\n' \
  > /etc/apt/apt.conf.d/99minimal
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d

# packages a container never needs (debootstrap excluded them too, but purge
# anyway in case a dependency pulled one back in)
for p in e2fsprogs tzdata diffutils; do
  dpkg --force-all --purge "$p" 2>/dev/null || true
done

if [ "$MINIMAL" = "bare" ]; then
  # drop the entire package-management stack: nothing is ever installed again
  for p in perl perl-base debconf apt; do
    dpkg --force-all --purge "$p" 2>/dev/null || true
  done
  rm -rf /var/lib/apt /var/lib/dpkg /var/cache/apt /usr/lib/dpkg /usr/lib/apt /etc/apt
  rm -f /usr/bin/dpkg* /usr/lib/*/libapt-pkg*.so* /usr/lib/*/libapt-private*.so* 2>/dev/null || true
  rm -rf /usr/share/perl /usr/lib/*/perl-base /usr/lib/*/perl 2>/dev/null || true
fi

# documentation, info, and (nearly all) locale/zone data are dead weight
rm -rf /usr/share/doc /usr/share/man /usr/share/info \
       /usr/share/lintian /usr/share/common-licenses \
       /usr/share/doc-base /usr/share/bug
if [ -d /usr/share/locale ]; then
  find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name en -exec rm -rf {} +
fi
if [ -d /usr/share/zoneinfo ]; then
  find /usr/share/zoneinfo -mindepth 1 ! -path '/usr/share/zoneinfo/Etc*' -exec rm -rf {} +
fi

rm -rf /var/log /var/tmp /tmp/* /run /var/backups
rm -rf /var/cache/debconf /var/cache/ldconfig
mkdir -p /run /var/lib/apt/lists/partial /var/cache/apt/archives/partial 2>/dev/null || true
STAGE
    sudo env MINIMAL="$MINIMAL" chroot "$ROOTFS" /tmp/min.sh
    sudo rm -f "$ROOTFS/tmp/min.sh"

    sudo chroot "$ROOTFS" /bin/bash -c \
      'command -v bash && command -v openssl && [ -d /etc/ssl/certs ] && [ -f /etc/os-release ] && echo "rootfs OK: shell + openssl + CA certs present"'

    if [ "$CROSS" = 1 ]; then
      # the static emulator was only a build convenience; the final rootfs is
      # foreign-pure and must not carry a ~20MB amd64 qemu binary
      sudo rm -f "$ROOTFS${QEMU_STATIC}"
    fi

    NAME="$DISTRO-$SUITE-$ARCH"
    ;;

  alpine)
    case "${ALPINE_VERSION:-latest}" in
      ""|latest|stable) REL="latest-stable" ;;
      *) REL="v${ALPINE_VERSION%.*}" ;;
    esac

    MANIFEST="$(curl -fsSL --retry 3 \
      "https://dl-cdn.alpinelinux.org/alpine/$REL/releases/$ARCH/latest-releases.yaml")"
    cat > "$PY" <<'PY'
import sys

def hit(cur):
    return cur.get("flavor") == "alpine-minirootfs" and cur.get("file")

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
    if hit(cur):
        print(cur["version"], cur["file"], cur["sha256"])
        break
PY
    read -r AV FNAME SHA <<< "$(python3 "$PY" "$MANIFEST")" || true
    [ -n "$FNAME" ] && [ -n "$SHA" ] || {
      echo "error: could not resolve a minirootfs for $REL/releases/$ARCH" >&2
      exit 1
    }
    echo "building alpine $AV"

    curl -fsSL --retry 3 -o "$ARCHIVE" \
      "https://dl-cdn.alpinelinux.org/alpine/$REL/releases/$ARCH/$FNAME"
    echo "$SHA  $ARCHIVE" | sha256sum -c -
    sudo mkdir -p "$ROOTFS"
    sudo tar -xzf "$ARCHIVE" -C "$ROOTFS"
    sudo rm -f "$ARCHIVE"

    sudo rm -rf "$ROOTFS"/var/cache/apk/* 2>/dev/null || true
    sudo rm -rf "$ROOTFS/var/log" \
      "$ROOTFS/usr/share/doc" \
      "$ROOTFS/usr/share/man" \
      "$ROOTFS/usr/share/info"
    sudo rm -f "$ROOTFS/etc/motd"

    NAME="alpine-$AV-$ARCH"
    ;;

  *)
    echo "error: unknown distro '$DISTRO' (use debian, ubuntu or alpine)" >&2
    exit 1
    ;;
esac

ARTIFACT="$OUT/$NAME-rootfs.tar.xz"
pack "$ARTIFACT" "$ROOTFS"
( cd "$OUT" && sha256sum "$NAME-rootfs.tar.xz" > "$NAME-SHA256SUMS" )
print_report "$ARTIFACT"