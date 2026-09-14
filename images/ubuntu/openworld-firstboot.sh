#!/bin/sh
# Openworld seed provisioning (cloud-init replacement): look for a secondary
# disk at boot, mount it read-only, and apply its 'userdata' file
# (OPENWORLD_USER / OPENWORLD_PASSWORD / OPENWORLD_PUBKEY). Runs once: after
# provisioning it stamps /var/lib/openworld/firstboot.done and disables itself
# so it never re-applies over later host-side changes.

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

mkdir -p "$(dirname "$SENTINEL")"
: > "$SENTINEL"
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable openworld-firstboot.service >/dev/null 2>&1 || true
else
    rc-update del openworld-firstboot >/dev/null 2>&1 || true
fi

exit 0