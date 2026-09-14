#!/bin/sh
# Openworld seed provisioning (cloud-init replacement): look for a secondary
# disk at boot, mount it read-only, and apply its 'userdata' file:
#   OPENWORLD_USER / OPENWORLD_PASSWORD / OPENWORLD_PUBKEY  (credentials)
#   OPENWORLD_NETWORK / address / netmask / gateway / DNS  (networking)
#   OPENWORLD_HOSTNAME                                  (hostname)
# Runs once: after provisioning it stamps /var/lib/openworld/firstboot.done
# and disables itself so it never re-applies over later host-side changes.

SENTINEL=/var/lib/openworld/firstboot.done
MOUNTDIR=/mnt/openworld-seed

[ -e "$SENTINEL" ] && exit 0

mkdir -p "$MOUNTDIR"

open_seed() {
    for dev in /dev/disk/by-label/OPENWORLD /dev/vdb /dev/vdb1 \
               /dev/sdb /dev/sdb1 /dev/xvdb /dev/nvme0n1p1; do
        [ -e "$dev" ] || continue
        mount -o ro "$dev" "$MOUNTDIR" 2>/dev/null || continue
        if [ -f "$MOUNTDIR/userdata" ]; then
            return 0
        fi
        umount "$MOUNTDIR" 2>/dev/null || true
    done
    return 1
}

found=0
if ! open_seed; then
    sleep 3   # the virtio-blk device may still be enumerating
    open_seed || exit 0
fi

# shellcheck disable=SC1090
. "$MOUNTDIR/userdata" 2>/dev/null || { umount "$MOUNTDIR" 2>/dev/null || true; exit 0; }
umount "$MOUNTDIR" 2>/dev/null || true

user="${OPENWORLD_USER:-root}"

ensure_user() {
    id "$user" >/dev/null 2>&1 && return
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s /bin/sh "$user"
    elif command -v adduser >/dev/null 2>&1; then
        adduser -D -s /bin/sh -h "/home/$user" "$user"
    fi
}

if [ -n "${OPENWORLD_PASSWORD:-}" ]; then
    ensure_user
    printf '%s:%s\n' "$user" "$OPENWORLD_PASSWORD" | chpasswd
fi

if [ -n "${OPENWORLD_PUBKEY:-}" ]; then
    if [ "$user" = "root" ]; then
        home=/root
    else
        ensure_user
        home="$(getent passwd "$user" | cut -d: -f6)"
        [ -n "$home" ] || home="/home/$user"
    fi
    mkdir -p "$home/.ssh"
    printf '%s\n' "$OPENWORLD_PUBKEY" > "$home/.ssh/authorized_keys"
    chown -R "$user:" "$home/.ssh" 2>/dev/null || true
    chmod 700 "$home"
    chmod 600 "$home/.ssh/authorized_keys"
fi

# Network: OPENWORLD_NETWORK=static|dhcp (default: keep the baked DHCP config).
# For static, use OPENWORLD_ADDRESS, OPENWORLD_NETMASK, OPENWORLD_GATEWAY and
# OPENWORLD_DNS (space separated). The interfaces file (ifupdown/netifrc,
# same syntax on Debian/Ubuntu and Alpine) is rewritten and the interface is
# re-raised so the config is live before dropbear serves ssh.
if [ -n "${OPENWORLD_NETWORK:-}" ]; then
    eth="${OPENWORLD_ETH:-eth0}"
    if [ "$OPENWORLD_NETWORK" = "static" ] && [ -n "${OPENWORLD_ADDRESS:-}" ]; then
        {
            echo "auto $eth"
            echo "iface $eth inet static"
            echo "    address $OPENWORLD_ADDRESS"
            echo "    netmask ${OPENWORLD_NETMASK:-255.255.255.0}"
            [ -n "${OPENWORLD_GATEWAY:-}" ] && echo "    gateway $OPENWORLD_GATEWAY"
            [ -n "${OPENWORLD_DNS:-}" ] && echo "    dns-nameservers $OPENWORLD_DNS"
        } > /etc/network/interfaces
        if [ -n "${OPENWORLD_DNS:-}" ]; then
            : > /etc/resolv.conf
            for d in $OPENWORLD_DNS; do
                echo "nameserver $d" >> /etc/resolv.conf
            done
        fi
    elif [ "$OPENWORLD_NETWORK" = "dhcp" ]; then
        printf 'auto %s\niface %s inet dhcp\n' "$eth" "$eth" > /etc/network/interfaces
    fi
    if command -v ifdown >/dev/null 2>&1; then
        ifdown "$eth" >/dev/null 2>&1 || true
        ifup "$eth" >/dev/null 2>&1 || true
    fi
fi

if [ -n "${OPENWORLD_HOSTNAME:-}" ]; then
    hostname "$OPENWORLD_HOSTNAME" 2>/dev/null || true
    printf '%s\n' "$OPENWORLD_HOSTNAME" > /etc/hostname
    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $OPENWORLD_HOSTNAME/" /etc/hosts
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$OPENWORLD_HOSTNAME" 2>/dev/null || true
    fi
fi

mkdir -p "$(dirname "$SENTINEL")"
: > "$SENTINEL"
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable openworld-firstboot.service >/dev/null 2>&1 || true
else
    rc-update del openworld-firstboot >/dev/null 2>&1 || true
fi

exit 0