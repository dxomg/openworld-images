#!/bin/sh
# openworld-provision -- tiny-cloud-style first-boot provisioner.
#
# A tiny-cloud clone: runs once on first boot and configures the instance from
# a datasource, picked in this order:
#
#   cidata   a secondary disk or ISO labelled 'cidata' (legacy 'OPENWORLD'
#            label and a few common device paths are also scanned) carrying
#              user-data   -> OPENWORLD_* shell vars, #! script, or a minimal
#                             #cloud-config (hostname + ssh_authorized_keys)
#              meta-data   -> local-hostname / instance-id (nocloud style)
#
#   imds     the EC2-compatible metadata service (http://169.254.169.254 or
#            http://[fd00:ec2::254], override in /etc/openworld.conf). Fetches
#            local-hostname, public keys and user-data like an EC2/OpenStack/
#            Firecracker MMDS metadata endpoint.
#
# The datasource is chosen by OPENWORLD_CLOUD (auto|cidata|imds|none, default
# auto) from the environment or /etc/openworld.conf; environment/kernel values
# win over the conf file. After a successful run the script stamps
# /var/lib/openworld/provisioned and disables itself so later host-side changes
# are never overwritten. With no datasource it exits quietly and retries on the
# next boot.
#
# user-data is sourced as a small shell script and may set:
#   OPENWORLD_USER                account to configure (default root)
#   OPENWORLD_PASSWORD            set that account's password
#   OPENWORLD_PUBKEY              public key(s) added to authorized_keys
#   OPENWORLD_HOSTNAME            new hostname (also via meta-data local-hostname)
#   OPENWORLD_NETWORK             static|dhcp (default: keep baked DHCP config)
#   OPENWORLD_ADDRESS / NETMASK / GATEWAY / DNS    static settings (NETWORK=static)
#   OPENWORLD_ETH                 interface to configure (default eth0)
#   OPENWORLD_RESIZE              1 grow the root filesystem (default 1)

SENTINEL="${OPENWORLD_SENTINEL:-/var/lib/openworld/provisioned}"
CONF="${OPENWORLD_CONF:-/etc/openworld.conf}"
MOUNTDIR="${OPENWORLD_SEED:-/mnt/openworld-seed}"
ROOTD="${OPENWORLD_ROOT:-/}"
VARS="OPENWORLD_CLOUD OPENWORLD_IMDS OPENWORLD_USER OPENWORLD_PASSWORD OPENWORLD_PUBKEY OPENWORLD_HOSTNAME OPENWORLD_NETWORK OPENWORLD_ADDRESS OPENWORLD_NETMASK OPENWORLD_GATEWAY OPENWORLD_DNS OPENWORLD_ETH OPENWORLD_RESIZE"

log() { echo "[openworld-provision] $*"; }

[ -e "${ROOTD%/}$SENTINEL" ] && exit 0

# -- config: values already exported take precedence over /etc/openworld.conf --
for v in $VARS; do
  eval "varbak_${v}=\${${v}-}"
done
if [ -r "$CONF" ]; then
  . "$CONF" 2>/dev/null && log "loaded $CONF"
fi
for v in $VARS; do
  eval "was=\${varbak_${v}+x}"
  if [ -n "$was" ]; then eval "${v}=\$varbak_${v}"; fi
done

OPENWORLD_USER="${OPENWORLD_USER:-root}"
OPENWORLD_CLOUD="${OPENWORLD_CLOUD:-auto}"
OPENWORLD_HTTP="${OPENWORLD_IMDS:=http://169.254.169.254}"

fetch() { # $1 url -> stdout body, zero exit on success
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 2 --max-time 4 "$1" 2>/dev/null && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO- -T 4 "$1" 2>/dev/null && return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# cidata (nocloud) datasource: a secondary disk/ISO with user-data / meta-data
# ---------------------------------------------------------------------------
cidata_mount() {
  local devs dev
  devs=""
  for lbl in cidata OPENWORLD; do
    [ -e "/dev/disk/by-label/$lbl" ] && devs="$devs /dev/disk/by-label/$lbl"
    if command -v blkid >/dev/null 2>&1; then
      devs="$devs $(blkid -L "$lbl" 2>/dev/null)"
    fi
  done
  devs="$devs /dev/vdb /dev/vdb1 /dev/sdb /dev/sdb1 /dev/xvdb /dev/xvdb1 \
         /dev/nvme0n1p1 /dev/vdc /dev/vdc1 /dev/sr0"
  for dev in $devs; do
    [ -e "$dev" ] || continue
    mount -o ro "$dev" "$MOUNTDIR" 2>/dev/null || continue
    if [ -f "$MOUNTDIR/user-data" ] || [ -f "$MOUNTDIR/userdata" ] ||
       [ -f "$MOUNTDIR/meta-data" ]; then
      return 0
    fi
    umount "$MOUNTDIR" 2>/dev/null || true
  done
  return 1
}

# minimal YAML helpers for the small #cloud-config subset we accept
cc_scalar() { # $1 key  $2 file -> inline value
  sed -n "s/^${1}:[[:space:]]*\(.*\)[[:space:]]*$/\1/p" "$2" 2>/dev/null | head -n1
}
cc_keys() { # $1 key  $2 file -> `- item` list entries under a top-level key
  awk -v k="$1" '
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    $0 !~ /^[ \t]/ { top = $0; sub(/:.*/, "", top); active = (top == k); next }
    active {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^-/) { sub(/^-/, "", line); sub(/^[ \t]+/, "", line); print line }
    }
  ' "$2" 2>/dev/null
}

read_userdata() { # $1 file path -> apply shell vars / run #! script / cloud-config
  [ -f "$1" ] || return 1
  if grep -q '^#cloud-config' "$1" 2>/dev/null; then
    h="$(cc_scalar hostname "$1")";    [ -n "$h" ] && OPENWORLD_HOSTNAME="$h"
    h="$(cc_scalar fqdn "$1")";        [ -n "$h" ] && OPENWORLD_HOSTNAME="$h"
    k="$(cc_keys ssh_authorized_keys "$1")"
    [ -n "$k" ] && OPENWORLD_PUBKEY="$k"
    u="$(cc_scalar user "$1")";        [ -n "$u" ] && OPENWORLD_USER="$u"
    u="$(cc_scalar default_user "$1")";[ -n "$u" ] && OPENWORLD_USER="$u"
    return 0
  fi
  if grep -q '^#!' "$1" 2>/dev/null; then
    log "running user-data script $1"
    chmod +x "$1" 2>/dev/null || true
    "$1" 2>&1 || log "user-data script exited nonzero"
    return 0
  fi
  # shell 'source' style: must contain at least one OPENWORLD_ variable
  if grep -q 'OPENWORLD_' "$1" 2>/dev/null; then
    . "$1" 2>/dev/null || log "warning: could not source $1"
    return 0
  fi
  log "unsupported user-data format in $1"
  return 0
}

cidata_hostname() { # from nocloud meta-data
  local h
  h="$(sed -n 's/^[[:space:]]*local-hostname[[:space:]]*:[[:space:]]*//p' \
            "$MOUNTDIR/meta-data" 2>/dev/null | head -n1)"
  [ -n "$h" ] || h="$(sed -n 's/^[[:space:]]*hostname[[:space:]]*:[[:space:]]*//p' \
            "$MOUNTDIR/meta-data" 2>/dev/null | head -n1)"
  case "$h" in ""|localhost|unknown|localhost.localdomain) h="";; esac
  [ -n "$h" ] && [ -z "${OPENWORLD_HOSTNAME:-}" ] && OPENWORLD_HOSTNAME="$h"
}

# ---------------------------------------------------------------------------
# imds datasource: EC2/OpenStack/Firecracker metadata service
# ---------------------------------------------------------------------------
imds_probe() { # -> zero + sets OPENWORLD_* when the service responds
  local base h meta ud
  base=""
  for url in "$OPENWORLD_HTTP" "http://[fd00:ec2::254]"; do
    if [ -n "$(fetch "$url/latest/meta-data/instance-id" 2>/dev/null)" ] ||
       [ -n "$(fetch "$url/latest/meta-data/" 2>/dev/null)" ]; then
      base="$url"; break
    fi
  done
  [ -n "$base" ] || return 1

  h="$(fetch "$base/latest/meta-data/local-hostname" 2>/dev/null)"
  case "$h" in ""|localhost|unknown|localhost.localdomain) h="";; esac
  [ -n "$h" ] && [ -z "${OPENWORLD_HOSTNAME:-}" ] && OPENWORLD_HOSTNAME="$h"

  # AWS/EC2 style public key, plus OpenStack meta_data.json hostname/public_keys
  k="$(fetch "$base/latest/meta-data/public-keys/0/openssh-key" 2>/dev/null)"
  if [ -z "$k" ]; then
    meta="$(fetch "$base/openstack/latest/meta_data.json" 2>/dev/null)"
    if [ -n "$meta" ]; then
      [ -z "${OPENWORLD_HOSTNAME:-}" ] && {
        h="$(printf '%s\n' "$meta" | sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$h" ] && OPENWORLD_HOSTNAME="$h"
      }
      k="$(printf '%s\n' "$meta" | grep -o 'ssh-rsa [^"\\]*' | sed 's/[[:space:]]*$//' | head -n1)"
    fi
  fi
  [ -n "$k" ] && [ -z "${OPENWORLD_PUBKEY:-}" ] && OPENWORLD_PUBKEY="$k"

  # user-data: EC2 /latest/user-data, OpenStack /openstack/latest/user_data
  ud="$(fetch "$base/latest/user-data" 2>/dev/null)"
  [ -n "$ud" ] || ud="$(fetch "$base/openstack/latest/user_data" 2>/dev/null)"
  if [ -n "$ud" ]; then
    tmp="$(mktemp /tmp/openworld-ud.XXXXXX)" 2>/dev/null || tmp=/tmp/openworld-ud
    printf '%s\n' "$ud" > "$tmp"
    read_userdata "$tmp"
    rm -f "$tmp"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# apply: credentials, networking, hostname
# ---------------------------------------------------------------------------
ensure_user() { # $1 username
  id "$1" >/dev/null 2>&1 && return 0
  if command -v useradd >/dev/null 2>&1; then
    useradd -m -s /bin/sh "$1"
  elif command -v adduser >/dev/null 2>&1; then
    adduser -D -s /bin/sh -h "/home/$1" "$1"
  fi
  return 0
}

apply_user() {
  local user="$OPENWORLD_USER"

  if [ -n "${OPENWORLD_PASSWORD:-}" ]; then
    ensure_user "$user"
    printf '%s:%s\n' "$user" "$OPENWORLD_PASSWORD" | chpasswd
  fi

  if [ -n "${OPENWORLD_PUBKEY:-}" ]; then
    local home
    ensure_user "$user"
    if [ "$user" = "root" ]; then
      home="$ROOTD/root"
    else
      home="$(getent passwd "$user" | cut -d: -f6)"
      [ -n "$home" ] || home="/home/$user"
      home="$ROOTD$home"
    fi
    mkdir -p "$home/.ssh"
    printf '%s\n' "$OPENWORLD_PUBKEY" > "$home/.ssh/authorized_keys"
    chown -R "$user:" "$home/.ssh" 2>/dev/null || true
    chmod 700 "$home"
    chmod 600 "$home/.ssh/authorized_keys"
  fi
}

apply_network() {
  [ -n "${OPENWORLD_NETWORK:-}" ] || return 0
  local eth="${OPENWORLD_ETH:-eth0}"
  if [ "$OPENWORLD_NETWORK" = "static" ] && [ -n "${OPENWORLD_ADDRESS:-}" ]; then
    {
      echo "auto $eth"
      echo "iface $eth inet static"
      echo "    address $OPENWORLD_ADDRESS"
      echo "    netmask ${OPENWORLD_NETMASK:-255.255.255.0}"
      [ -n "${OPENWORLD_GATEWAY:-}" ] && echo "    gateway $OPENWORLD_GATEWAY"
      [ -n "${OPENWORLD_DNS:-}" ] && echo "    dns-nameservers $OPENWORLD_DNS"
    } > "$ROOTD/etc/network/interfaces"
    if [ -n "${OPENWORLD_DNS:-}" ]; then
      : > "$ROOTD/etc/resolv.conf"
      for d in $OPENWORLD_DNS; do
        echo "nameserver $d" >> "$ROOTD/etc/resolv.conf"
      done
    fi
  elif [ "$OPENWORLD_NETWORK" = "dhcp" ]; then
    printf 'auto %s\niface %s inet dhcp\n' "$eth" "$eth" > "$ROOTD/etc/network/interfaces"
  fi
  if [ "$ROOTD" = "/" ] && command -v ifdown >/dev/null 2>&1; then
    ifdown "$eth" >/dev/null 2>&1 || true
    ifup "$eth" >/dev/null 2>&1 || true
  fi
}

apply_hostname() {
  [ -n "${OPENWORLD_HOSTNAME:-}" ] || return 0
  [ "$ROOTD" = "/" ] && hostname "$OPENWORLD_HOSTNAME" 2>/dev/null || true
  printf '%s\n' "$OPENWORLD_HOSTNAME" > "$ROOTD/etc/hostname"
  sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $OPENWORLD_HOSTNAME/" "$ROOTD/etc/hosts"
  if [ "$ROOTD" = "/" ] && command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$OPENWORLD_HOSTNAME" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# rootfs grow (tiny-cloud-style): best effort, needs resize2fs
# ---------------------------------------------------------------------------
grow_root() {
  [ "${OPENWORLD_RESIZE:-1}" = "1" ] || return 0
  command -v resize2fs >/dev/null 2>&1 || { log "resize2fs not found; skipping rootfs grow"; return 0; }
  command -v blockdev >/dev/null 2>&1 || { log "blockdev not found; skipping rootfs grow"; return 0; }
  local rdev fssz blksz devsz
  rdev="$(awk '$2 == "/" { print $1; exit }' /proc/mounts)"
  [ -n "$rdev" ] || return 0
  fssz="$(dumpe2fs -h "$rdev" 2>/dev/null | awk '/^Block count:/ {print $3}')"
  blksz="$(dumpe2fs -h "$rdev" 2>/dev/null | awk '/^Block size:/ {print $3}')"
  devsz="$(blockdev --getsize64 "${rdev%[0-9]*}" 2>/dev/null)"
  [ -n "$fssz" ] && [ -n "$blksz" ] && [ -n "$devsz" ] || return 0
  if [ $((fssz * blksz)) -ge "$devsz" ]; then
    log "root filesystem already fills its device; skipping grow"
    return 0
  fi
  log "growing root filesystem on $rdev"
  resize2fs -f "$rdev" >/dev/null 2>&1 && log "root filesystem grown" \
    || log "could not grow root filesystem"
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
mkdir -p "$MOUNTDIR" "$(dirname "${ROOTD%/}$SENTINEL")"

grow_root

found=0
try_ds() {
  case "$OPENWORLD_CLOUD" in
    none) return 1 ;;
    cidata)
      if cidata_mount; then cidata_hostname; read_userdata "$MOUNTDIR/user-data" || read_userdata "$MOUNTDIR/userdata"; umount "$MOUNTDIR" 2>/dev/null || true; return 0; fi
      return 1 ;;
    imds)
      imds_probe && return 0
      return 1 ;;
    *)
      if cidata_mount; then
        cidata_hostname
        read_userdata "$MOUNTDIR/user-data" || read_userdata "$MOUNTDIR/userdata"
        umount "$MOUNTDIR" 2>/dev/null || true
        return 0
      fi
      imds_probe && return 0
      return 1 ;;
  esac
}

if try_ds; then
  found=1
else
  log "no datasource found, retrying once after 3s"
  sleep 3
  try_ds && found=1
fi

if [ "$found" -eq 0 ]; then
  log "no datasource; leaving system untouched (will run again next boot)"
  exit 0
fi

apply_user
apply_network
apply_hostname

: > "${ROOTD%/}$SENTINEL"
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable openworld-provision.service >/dev/null 2>&1 || true
else
  rc-update del openworld-provision >/dev/null 2>&1 || true
fi

log "provisioning complete"
exit 0