# openworld-provision usage guide

Full documentation for the tiny-cloud-style first-boot provisioner that ships in every
`openworld-images` disk image (Debian, Ubuntu, Alpine). It replaces cloud-init with a
single POSIX `sh` script that runs once on first boot and configures the instance from a
datasource.

- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Datasource selection](#datasource-selection)
- [`user-data` formats](#user-data-formats)
- [`meta-data` format](#meta-data-format)
- [Datasource 1: `cidata` (seed disk / ISO)](#datasource-1-cidata-seed-disk--iso)
- [Datasource 2: `imds` (metadata service)](#datasource-2-imds-metadata-service)
- [Behaviour & lifecycle](#behaviour--lifecycle)
- [Verifying and troubleshooting](#verifying-and-troubleshooting)
- [Baking values in at build time](#baking-values-in-at-build-time)

---

## How it works

On first boot the image runs `openworld-provision.sh` as a one-shot unit **before dropbear
starts listening**, so keys and passwords are in place before any SSH connection can be
made:

- **systemd** (Debian/Ubuntu): a `oneshot` service, `After=local-fs.target`,
  `Before=dropbear.service`.
- **OpenRC** (Alpine): an init script in the default runlevel, `need localmount` and
  `before dropbear`.

The provisioner picks one datasource, reads `user-data` (and `meta-data`), applies it to
the live system, then stamps a sentinel file and disables itself so it never runs again.

The pieces that make this up live in the image at:

```
/usr/local/sbin/openworld-provision.sh   the provisioner (the whole mechanism)
/etc/openworld.conf                      optional defaults (all commented)
```

Files in the repo that produce them:

```
images/openworld-provision.sh            provisioner source
images/openworld.conf                    sample /etc/openworld.conf
images/openworld-provision.service       systemd unit (Debian/Ubuntu)
images/openworld-provision.init          OpenRC init (Alpine)
```

---

## Configuration

The provisioner reads exactly one knob, `OPENWORLD_CLOUD`, to decide which datasource to
use; everything else is delivered per-instance through `user-data`/`meta-data` or baked in
at build time. Optional defaults can be set in `/etc/openworld.conf`.

### Precedence

```
kernel command line / environment  >  /etc/openworld.conf  >  built-in defaults
```

Anything already exported in the environment wins over `/etc/openworld.conf`. `user-data`
is applied last, so its values win over both (this is how an instance gets its own
identity even when the image was built with generic defaults).

### `/etc/openworld.conf`

All keys are optional and commented out by default:

```sh
# Datasource: auto (cidata, then imds) | cidata | imds | none
#OPENWORLD_CLOUD=auto

# Metadata service base URL for the imds datasource
# (default http://169.254.169.254; IPv6 [fd00:ec2::254] is also tried)
#OPENWORLD_IMDS=http://169.254.169.254

# Default account to configure (used when user-data gives no OPENWORLD_USER)
#OPENWORLD_USER=root

# Grow the root filesystem to fill the disk on first boot (best effort)
#OPENWORLD_RESIZE=1
```

A full list of every supported variable is in the [`user-data` formats](#user-data-formats)
section.

---

## Datasource selection

`OPENWORLD_CLOUD` (from env or the conf file) chooses the datasource:

| Value    | Behaviour                                                        |
|----------|------------------------------------------------------------------|
| `auto`   | Try `cidata`, then `imds` (default)                              |
| `cidata` | Only use a seed disk/ISO; never talk to a metadata service       |
| `imds`   | Only query the metadata service                                  |
| `none`   | Do nothing; exit and retry next boot                            |

If no datasource can be reached, provisioning is skipped (boot proceeds normally, no
sentinel is written) and the provisioner runs again on the next boot. It retries once
within the same boot after a 3-second wait — long enough for DHCP to finish on first boot.

> If you run on a network you do not control, pin `OPENWORLD_CLOUD=cidata` (or `none`) so
> the image never queries external/ambiguous metadata endpoints.

---

## `user-data` formats

The provisioner accepts three formats, detected by the first line of `user-data`:

1. **Shell variable format** — any text containing `OPENWORLD_` is sourced as a tiny shell
   script. This is the most complete format.
2. **Cloud-config subset** — files starting with `#cloud-config`.
3. **`#!` script** — anything starting with `#!` is made executable and run as root.

### 1. Shell variable format

`user-data` may set any of these variables:

| Variable              | Meaning                                                                 |
|-----------------------|-------------------------------------------------------------------------|
| `OPENWORLD_USER`      | Account to configure (default `root`)                                   |
| `OPENWORLD_PASSWORD`  | Set this account's password via `chpasswd`                              |
| `OPENWORLD_PUBKEY`    | Public key line(s) added to `$user`'s `authorized_keys`                 |
| `OPENWORLD_HOSTNAME`  | New hostname — applied live (`hostname`/`hostnamectl`) *and* persisted  |
| `OPENWORLD_NETWORK`   | `static` or `dhcp` (default: keep the baked DHCP config)                |
| `OPENWORLD_ADDRESS`   | Static IPv4 address (only with `OPENWORLD_NETWORK=static`)              |
| `OPENWORLD_NETMASK`   | Netmask (default `255.255.255.0`)                                       |
| `OPENWORLD_GATEWAY`   | Default gateway                                                         |
| `OPENWORLD_DNS`       | Space-separated nameservers; writes `resolv.conf`  and the interfaces   |
| `OPENWORLD_ETH`       | Interface to configure (default `eth0`)                                 |
| `OPENWORLD_CLOUD`     | Datasource override for this boot (`auto`/`cidata`/`imds`/`none`)       |
| `OPENWORLD_IMDS`      | Metadata service base URL (only relevant while the datasource is imds)  |
| `OPENWORLD_RESIZE`    | `1` grow the root filesystem to fill the disk (default `1`, best-effort)|

Example:

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

> Quote values that contain spaces (`OPENWORLD_PUBKEY`, `OPENWORLD_DNS`), otherwise shell
> word-splitting will corrupt them. Multiple `OPENWORLD_PUBKEY` lines are fine — each line
> is written to `authorized_keys` as-is.

### 2. Cloud-config subset

A minimal `#cloud-config` is accepted so standard NoCloud/OpenStack seeds work:

```yaml
#cloud-config
hostname: mybox
fqdn: mybox.example.net        # wins over hostname if both are present
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@laptop
user: cbuser                     # or: default_user: cbuser
```

Supported keys:

| Key                   | Effect                                        |
|-----------------------|-----------------------------------------------|
| `hostname:`           | sets the hostname                              |
| `fqdn:`               | sets the hostname (wins if both given)         |
| `ssh_authorized_keys:`| list of `- key` lines appended to `authorized_keys` |
| `user:` / `default_user:` | account to configure                      |

Anything else is ignored. For richer provisioning, use the shell-variable format or a
`#!` script.

### 3. `#!` script

Any `user-data` beginning with `#!` is executed verbatim as root:

```sh
#!/bin/sh
set -e
apk add --no-cache tmux   # Alpine
# apt-get install -y tmux  # Debian/Ubuntu
echo "hello from first boot" > /etc/banner
```

---

## `meta-data` format

`meta-data` is optional and, when present, can carry the NoCloud hostname:

```
instance-id: iid-myvm-0001
local-hostname: mybox
```

`local-hostname:` (or `hostname:`) is used as the hostname *unless* `user-data` sets
`OPENWORLD_HOSTNAME`, in which case `user-data` wins. Placeholder values (`localhost`,
`unknown`, `localhost.localdomain`) are treated as unset.

---

## Datasource 1: `cidata` (seed disk / ISO)

A tiny secondary disk or ISO carrying `user-data` / `meta-data`. The filesystem must be
labelled `cidata` (the legacy `OPENWORLD` label is still scanned). ext4, FAT and ISO9660
all work.

### Create a seed disk

```sh
truncate -s 1M seed.img
mkfs.ext4 -L cidata seed.img

mkdir seed
printf 'instance-id: iid-local-1\nlocal-hostname: mybox\n' > seed/meta-data
cat > seed/user-data <<'EOF'
OPENWORLD_USER=root
OPENWORLD_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host'
EOF

# write the files into the filesystem image
mkdir mnt && sudo mount -o loop seed.img mnt
sudo cp seed/meta-data seed/user-data mnt/
sudo umount mnt
```

### Create a seed ISO (read-only, no root needed on Linux)

```sh
genisoimage -quiet -J -V cidata -o seed.iso seed/
# or
xorriso -as mkisofs -V cidata -o seed.iso seed/
```

### What gets scanned

The provisioner mounts, in order: `/dev/disk/by-label/{cidata,OPENWORLD}`, then the usual
second-disk device names — `/dev/vdb`, `/dev/vdb1`, `/dev/sdb`, `/dev/sdb1`, `/dev/xvdb`,
`/dev/xvdb1`, `/dev/nvme0n1p1`, `/dev/vdc`, `/dev/vdc1`, `/dev/sr0` — until it finds a
volume containing `user-data`, `userdata`, or `meta-data`. A `cidata` label is the most
robust because it survives kernel/virtio naming differences. Every volume is mounted
read-only.

### Boot with it

**QEMU** — attach the seed as a second drive:

```sh
qemu-system-x86_64 \
  -machine accel=kvm -m 512 -smp 2 \
  -kernel vmlinux -append "console=ttyS0" \
  -drive file=debian-trixie-amd64.img,if=virtio,format=raw \
  -drive file=seed.iso,if=virtio,format=raw \
  -nographic
```

**Firecracker** — add the seed as a second non-root drive (an ISO needs `is_read_only:
true`):

```json
"drives": [
  { "drive_id": "root", "path_on_host": "/srv/debian-trixie-amd64.img", "is_root_device": true },
  { "drive_id": "seed", "path_on_host": "/srv/seed.iso", "is_root_device": false, "is_read_only": true }
]
```

### Cloud Hypervisor

```sh
cloud-hypervisor --kernel vmlinux --cmdline "console=ttyS0" \
  --disk path=debian-trixie-amd64.img path=seed.iso \
  --console off --serial tty
```

---

## Datasource 2: `imds` (metadata service)

When `OPENWORLD_CLOUD` allows it and no cidata volume turns up, the provisioner queries an
EC2-compatible metadata service instead of needing a seed disk.

- **Default endpoint:** `http://169.254.169.254` (override with `OPENWORLD_IMDS`).
- **Fallback endpoint:** IPv6 link-local `http://[fd00:ec2::254]` (Firecracker MMDS).

It is EC2-, OpenStack- and Firecracker-MMDS-compatible and reads:

| Source                                             | Provides                       |
|----------------------------------------------------|--------------------------------|
| `/latest/meta-data/instance-id`                    | probe (is the service there?)  |
| `/latest/meta-data/local-hostname`                 | hostname                        |
| `/latest/meta-data/public-keys/0/openssh-key`      | ssh key                        |
| `/latest/user-data`                                | arbitrary user-data            |
| `/openstack/latest/meta_data.json`                 | hostname + `ssh-rsa` key (OpenStack, when EC2 key path is empty) |
| `/openstack/latest/user_data`                      | user-data (OpenStack fallback)  |

The fetched `user-data` can be any of the three formats above. Only the first candidate of
each value is used.

### Emulating it locally (for testing)

Anything that answers those paths over HTTP works. A minimal way to test on your own
network is to run an HTTP server — the image calls the service over plain HTTP, so any
listener accessible at the configured URL works (put a route/NAT in front of a real
metadata IP, or point `OPENWORLD_IMDS` at your test server):

```sh
mkdir -p mds/latest/meta-data mds/latest/meta-data/public-keys/0
echo iid-test-1                > mds/latest/meta-data/instance-id
echo imdsbox                   > mds/latest/meta-data/local-hostname
echo 'ssh-ed25519 AAAA... u@h' > mds/latest/meta-data/public-keys/0/openssh-key
cat > mds/latest/user-data <<'EOF'
OPENWORLD_USER=cloudu
EOF
python3 -m http.server 8008 --directory mds
```

Then boot with `OPENWORLD_IMDS=http://<server-ip>:8008` in the environment or the conf
file — or a router rule making `169.254.169.254` (`169.254.169.254:80`) reach the server.

### Firecracker MMDS

Firecracker's in-guest metadata service leans on the IPv6 fallback. Configure a tap
network with `allow_mmds_requests: true` and provide a response for `/latest/...`; the
image finds it at `http://[fd00:ec2::254]`. (You do **not** want the default `/latest/`
prefix conflicts — the provisioner uses the straight `/latest/...` paths so keep your MMDS
responses at those paths.)

---

## Behaviour & lifecycle

- **Runs once.** Successful provisioning stamps `/var/lib/openworld/provisioned` and
  disables the unit (`systemctl disable openworld-provision.service` or
  `rc-update del openworld-provision`). Later host-side changes are never overwritten;
  to re-provision, flash the root image again.
- **Ordered before dropbear**, so keys/passwords exist before ssh can be connected to.
- **Networking is re-raised** (`ifdown`/`ifup`) when static config is applied, so the
  address is already live when dropbear starts. DHCP default is left untouched if no
  `OPENWORLD_NETWORK` is given.
- **Root filesystem grow.** With `OPENWORLD_RESIZE=1` (default) the root filesystem is
  grown to fill the disk via `resize2fs`/`blockdev`, best-effort (skipped cleanly where
  those tools are absent). Note the shipped images are shrunk to minimum size, so the grow
  is what makes the filesystem actually fill a larger disk — e.g. a 10G disk created from
  a ~60M image.
- **Hostname** is set live and persisted to `/etc/hostname` + the `127.0.1.1` line of
  `/etc/hosts`.
- **No datasource found**: logs a message, leaves the system untouched (no sentinel, no
  self-disable), and runs again next boot.
- **Retry once within the boot** after 3s (gives DHCP time to finish on first boot).

---

## Verifying and troubleshooting

Check whether provisioning ran and what it did:

```sh
# systemd (Debian/Ubuntu)
systemctl status openworld-provision
journalctl -u openworld-provision

# OpenRC (Alpine)
rc-service openworld-provision status
# log goes to the console; check /var/log/rc.log or dmesg on OpenRC
```

Signs of a successful run:

```sh
ls /var/lib/openworld/provisioned            # sentinel present
systemctl is-enabled openworld-provision     # disabled (not enabled)
# or on Alpine: rc-update show | grep openworld   -> not listed
cat /etc/hostname /etc/hosts
cat /root/.ssh/authorized_keys
cat /etc/network/interfaces /etc/resolv.conf
```

The provisioner logs each step to the journal/console prefixed `[openworld-provision]`
(`loaded /etc/openworld.conf`, `provisioning complete`, etc.). A second boot should show
it doing nothing (sentinel) — `systemctl status` will still show the oneshot as active/
exited with `RemainAfterExit=yes`; on Alpine the init script exits immediately.

Common issues:

| Symptom                            | Fix                                           |
|------------------------------------|-----------------------------------------------|
| No auth key after boot             | seed/`user-data` unquoted pubkey (spaces split); check `journalctl -u openworld-provision` |
| Static network not active          | ensure `OPENWORLD_NETWORK=static` **and** `OPENWORLD_ADDRESS` set |
| Provisioner ran but no cloud bank  | datasource unreachable: pin `OPENWORLD_CLOUD`, check the seed device name / labels |
| Repeated runs                      | sentinel missing after a failed run — it only self-disables after a successful apply |

---

## Baking values in at build time

Values can also be baked into the image rather than delivered per-VM, via
`scripts/build-rootfs.sh`:

```sh
OPENWORLD_PUBKEY='ssh-ed25519 AAAA... user@host' \
OPENWORLD_ROOTPW='s3cret' \
bash scripts/build-rootfs.sh debian
```

This sets the `openworld` SSH key and a root password at image build time (the two
workflows do the same via their `ssh_pubkey` / `root_password` dispatch inputs). Per-VM
values such as hostname or static networking are still best delivered through the seed
disk / metadata service so one image can boot many instances differently.