# openworld-images

Bootable ext4 disk images (`.img`) for **Debian**, **Ubuntu** and **Alpine**, built for
lightweight microVMs (Firecracker, QEMU, etc.) with **no cloud-init** and no `cloud-init`
dependency anywhere. Provisioning is handled by a small built-in "seed disk" mechanism that
mimics the classic `nocloud`/`NoCloud` data-source workflow.

Each image is a minimal, immutable-style rootfs: slimmed live services, key-only
[dropbear](https://matt.ucc.asn.au/dropbear/dropbear.html) SSH, and a serial console on
`ttyS0` so a VM always has a login path.

## Contents

- [Images](#images)
- [Get the images](#get-the-images)
- [Boot a VM](#boot-a-vm)
- [Access](#access)
- [Seed provisioning (custom no-cloud)](#seed-provisioning-custom-no-cloud)
- [Build locally](#build-locally)
- [GitHub Actions](#github-actions)
- [Image layout](#image-layout)
- [Security notes](#security-notes)

## Images

| Distro   | Base        | Init      | Arch support (workflow)                                   |
|----------|-------------|-----------|-----------------------------------------------------------|
| Debian   | `stable-slim` | systemd  | amd64, i386, arm64, armhf, armel, riscv64, s390x, ppc64el |
| Ubuntu   | `latest` LTS | systemd  | same                                                      |
| Alpine   | `latest`    | OpenRC    | same                                                      |

Every image ships:

- **systemd** (Debian/Ubuntu) or **OpenRC** (Alpine) as init.
- **dropbear** only — OpenSSH is never installed. `-s` forces key-only logins
  (password login via ssh is disabled).
- **Networking** via ifupdown/interfaces with DHCP on `eth0` by default, ready to
  reconfigure through the seed disk.
- **Serial console** login on `ttyS0` (`agetty`), gated on `ConditionPathExists` so it never
  stalls boot in a microVM where device units are unreliable.
- **Slimmed runtime**: no hwdb, locale, journal catalogs or manpages; full `terminfo` for
  the common terminal types is kept so `ssh`/serial sessions render correctly.
- **No `cloud-init`**, no `systemd-networkd`, no netplan.

The rootfs is built from a Docker base, exported, and projected onto a raw ext4 image that
is **shrunk to its minimum size** (no journal, no reserved blocks) by
`scripts/build-rootfs.sh`, so the `.img` is a few tens of MiB.

## Get the images

Two rolling GitHub releases publish every build (the rolling release is
re-created to point at the latest commit):

- **`openworld-images`** — key-only dropbear, no pre-set root password.
- **`openworld-images-rootpw`** — same, but with a pre-set root password (default `root`)
  so the serial/console login works without a key.

Tag pushes (`git tag vX && git push --tags`) also produce a permanent `vX` release.
Each release contains the `.img` files (named `<distro>-<codename>-<arch>.img`) plus a
`SHA256SUMS` checksum file.

## Boot a VM

Attach the `.img` as the root disk. No cloud-init datasource, no config drive required —
a VM with just the root disk boots and gets an address via DHCP.

**QEMU:**

```sh
qemu-system-x86_64 \
  -machine accel=kvm -m 512 -smp 2 \
  -kernel vmlinux -append "console=ttyS0" \
  -drive file=debian-trixie-amd64.img,if=virtio,format=raw \
  -nographic
```

(Requires a kernel/vmlinux that contains a virtio-net + virtio-blk driver and a guest
capable of DHCP — the images include the usual `eth0`/virtio support and a DHCP client.)

**Firecracker:** create a drive with `path = "<distro>-<codename>-<arch>.img>",
is_root_device = true`, plus a `tap`-backed network interface.

## Access

- **SSH:** dropbear runs on port 22, key-only. Authenticate as the `openworld` user
  (if a public key was baked in via `OPENWORLD_PUBKEY`/`ssh_pubkey`) or `root` (with a
  key placed via seed provisioning — see below). The baked-in `openworld` user has no
  password; ssh to it only works with a baked key.
- **Console/serial:** a login on `ttyS0` is always available. On non-rootpw images root
  is password-locked, so seed-provision a password/key first; on `-rootpw` images the
  pre-set root password works out of the box.

## Seed provisioning (custom no-cloud)

The images replace cloud-init with `openworld-firstboot`, a one-shot provisioner that runs
once on first boot and applies a `userdata` file from a **secondary seed disk**. This is
the equivalent of an `nocloud` datasource: you prepare a tiny disk, boot the VM with it
attached, and the image configures itself before dropbear accepts the first connection.

### 1. Make the seed disk

```sh
truncate -s 1M seed.img
mkfs.ext4 -L OPENWORLD seed.img        # label is optional but recommended
```

The image scans candidate devices in this order until it finds one with a `userdata` file:

```
/dev/disk/by-label/OPENWORLD  /dev/vdb  /dev/vdb1
/dev/sdb  /dev/sdb1  /dev/xvdb  /dev/nvme0n1p1
```

Labeling the filesystem `OPENWORLD` is the most robust option (it survives kernel/virtio
naming differences). ext4 and FAT both work.

### 2. Write `userdata`

`userdata` is sourced as a small shell script; it may set any of these variables:

| Variable              | Meaning                                                              |
|-----------------------|----------------------------------------------------------------------|
| `OPENWORLD_USER`      | Account to configure (default `root`)                                |
| `OPENWORLD_PASSWORD`  | Set this account's password (`chpasswd`)                             |
| `OPENWORLD_PUBKEY`    | One public key appended to `$user`'s `authorized_keys` (single line) |
| `OPENWORLD_HOSTNAME`  | New hostname (applied live + persisted)                              |
| `OPENWORLD_NETWORK`   | `static` or `dhcp` (default: keep baked DHCP config)                 |
| `OPENWORLD_ADDRESS`   | Static IPv4 address (requires `OPENWORLD_NETWORK=static`)            |
| `OPENWORLD_NETMASK`   | Netmask (default `255.255.255.0`)                                    |
| `OPENWORLD_GATEWAY`   | Default gateway                                                      |
| `OPENWORLD_DNS`       | Space-separated nameservers (writes `resolv.conf`)                   |
| `OPENWORLD_ETH`       | Interface to configure (default `eth0`)                              |

Example `userdata`:

```sh
OPENWORLD_USER=root
OPENWORLD_PASSWORD='changeme'
OPENWORLD_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host'

OPENWORLD_NETWORK=static
OPENWORLD_ADDRESS=192.168.1.50
OPENWORLD_NETMASK=255.255.255.0
OPENWORLD_GATEWAY=192.168.1.1
OPENWORLD_DNS='1.1.1.1 8.8.8.8'

OPENWORLD_HOSTNAME=mybox
```

### 3. Boot with the seed disk attached

The seed disk must be the **second** disk (the root `.img` is disk 0):

```sh
qemu-system-x86_64 \
  -kernel vmlinux -append "console=ttyS0" \
  -drive file=debian-trixie-amd64.img,if=virtio,format=raw \
  -drive file=seed.img,if=virtio,format=raw \
  -nographic
```

On Firecracker, add the seed disk as a second `Drive` with a non-root `drive_id`.

### Behaviour

- Provisioning **runs once**: after applying `userdata` it stamps
  `/var/lib/openworld/firstboot.done` and disables itself (`systemctl disable` on
  systemd, `rc-update del` on Alpine). Later host-side changes are never overwritten
  (to re-provision, re-flash the root image).
- With **no seed disk attached**, boot proceeds normally and nothing is configured.
- The provisioner is ordered **before dropbear**, so keys/passwords are in place before
  the first ssh connection.
- On static networking the interface is re-raised (ifdown/ifup) so the config is already
  live when dropbear starts.

## Build locally

Requires `docker` (with `buildx` for cross-arch), `sudo`, and `xz-utils`/`e2fsprogs`
(installed automatically if missing).

```sh
# native build, default arch amd64
bash scripts/build-rootfs.sh debian
bash scripts/build-rootfs.sh ubuntu
bash scripts/build-rootfs.sh alpine

# cross-arch
ARCH=arm64 bash scripts/build-rootfs.sh debian

# bake a public key and/or root password into the image
OPENWORLD_PUBKEY='ssh-ed25519 AAAA... user@host' \
OPENWORLD_ROOTPW='s3cret' \
bash scripts/build-rootfs.sh debian
```

Output lands in `dist/` as `<distro>-<codename>-<arch>.img` plus `*-SHA256SUMS`.
Baking a key/password is optional and happens at image build time; the same values can
instead be delivered per-VM through the seed disk.

## GitHub Actions

Two workflows build and publish releases:

- **`build-images`** — key-only images, no root password.
  Dispatch inputs: `distros`, `archs`, `ssh_pubkey`. Also runs on `push` to `main`
  (paths: workflows, `scripts/`, `images/`) and weekly Monday.
- **`build-images-rootpw`** — same, but bakes a root password.
  Additional input `root_password` (default `root`, or the `OPENWORLD_ROOTPW` repo
  variable). Runs weekly Tuesday.

Both matrix-build across distros × archs, upload artifacts, and publish the rolling
`openworld-images` / `openworld-images-rootpw` releases (plus a `v*` tagged release for
tag pushes).

## Image layout

```
scripts/
  build-rootfs.sh          # Docker -> exported rootfs -> shrunk ext4 .img
images/
  {debian,ubuntu,alpine}/
    Dockerfile             # provisions & slims the rootfs
    interfaces             # ifupdown config (DHCP eth0)
    99-openworld-eth0.rules     # udev rule pinning the nic to eth0 (systemd)
    openworld-serial-console.service  # ttyS0 agetty (systemd)
    openworld-firstboot.sh  # the seed-disk provisioner (shared)
    openworld-firstboot.service / .init  # systemd unit / OpenRC init
    dropbear.init           # key-only dropbear with host-key gen (Alpine)
.github/workflows/
  build-images.yml          # no-rootpw pipeline
  build-images-rootpw.yml   # rootpw pipeline
```

## Security notes

- These images are intended for trusted/hobby microVMs. The `-rootpw` images bake a
  well-known password (`root` by default) — expose them only on isolated networks, and
  change the password via seed provisioning or `-pw` dispatch input.
- dropbear is key-only over ssh; password logins only exist at the console/serial.
- The seed disk is mounted read-only and its `userdata` is executed as `root` — only
  attach seed disks you control.
- Images offer **no cloud-init** and **no cloud agent**; do not rely on cloud-vendor
  metadata services.