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

# Grab the newest debootstrap straight from Debian's pool so the moment a new
# Debian/Ubuntu codename is released it can still be bootstrapped.
latest_debootstrap() {
  local deb
  deb="$(curl -fsSL --retry 3 https://deb.debian.org/debian/pool/main/d/debootstrap/ \
    | grep -oE 'debootstrap_[0-9.]+_all\.deb' | sort -Vu | tail -1)"
  [ -n "$deb" ] || return 1
  DBROOT="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$DBROOT/db.deb" "https://deb.debian.org/debian/pool/main/d/debootstrap/$deb"
  dpkg -x "$DBROOT/db.deb" "$DBROOT"
  DEBOOTSTRAP="$DBROOT/usr/sbin/debootstrap"
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

    if [ "$ARCH" != "$(dpkg --print-architecture)" ]; then
      echo "error: debootstrap cross-arch ($ARCH) is not supported here; use the runner's native arch." >&2
      exit 1
    fi

    if latest_debootstrap; then
      echo "using debootstrap $("$DEBOOTSTRAP" --version | head -n1 | awk '{print $NF}') from the Debian pool"
      scripts_dir="$(dirname "$DEBOOTSTRAP")/../share/debootstrap/scripts"
    else
      echo "warning: could not fetch the latest debootstrap, falling back to the system package" >&2
      sudo apt-get install -y -qq debootstrap >/dev/null 2>&1 || true
      DEBOOTSTRAP="$(command -v debootstrap)"
      scripts_dir="/usr/share/debootstrap/scripts"
    fi

    [ -f "$scripts_dir/$SUITE" ] || {
      echo "error: no debootstrap script for suite '$SUITE'." >&2
      echo "hint: pass an explicit SUITE (e.g. bookworm, noble) or update debootstrap." >&2
      exit 1
    }

    sudo "$DEBOOTSTRAP" --quiet --variant=minbase --components=main \
      --include=ca-certificates \
      --exclude=e2fsprogs,tzdata,diffutils \
      --arch "$ARCH" "$SUITE" "$ROOTFS" "$MIRROR"

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
    sudo chroot "$ROOTFS" /tmp/min.sh
    sudo rm -f "$ROOTFS/tmp/min.sh"

    sudo chroot "$ROOTFS" /bin/bash -c \
      'command -v bash && command -v openssl && [ -d /etc/ssl/certs ] && [ -f /etc/os-release ] && echo "rootfs OK: shell + openssl + CA certs present"'

    NAME="$DISTRO-$SUITE-$ARCH"
    ;;

  alpine)
    case "${ALPINE_VERSION:-latest}" in
      ""|latest|stable) REL="latest-stable" ;;
      *) REL="v$ALPINE_VERSION" ;;
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