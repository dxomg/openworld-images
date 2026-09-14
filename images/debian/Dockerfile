# Rootfs for the openworld Debian cloud image.
# Provisioned from the official rolling "stable" slim base. The resulting image
# is exported and projected onto an ext4 .img by scripts/build-rootfs.sh.
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN set -e \
  && apt-get update -qq \
  && apt-get install -y --no-install-recommends \
       systemd-sysv dropbear ifupdown isc-dhcp-client \
  && rm -rf /var/lib/apt/lists/*

# Keep future apt installs docs-free too (mirrors the paths the build strips).
RUN set -e \
  && mkdir -p /etc/dpkg/dpkg.cfg.d \
  && cat > /etc/dpkg/dpkg.cfg.d/nodoc << 'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
EOF

# dropbear is the only ssh server (openssh-server is never installed): the
# postinst leaves NO_START=0 so its service is enabled at boot; -s enforces
# key-only logins. Best-effort systemd-sysusers/systemd-tmpfiles here so the
# exported rootfs is consistent (systemd redoes it at first boot anyway).
# The serial console is provided by openworld-serial-console.service (a plain
# agetty on ttyS0 gated by ConditionPathExists, with NO dev-*.device unit
# dependency - Docker-exported rootfs device units are unreliable in microVMs,
# which is exactly why the stock serial-getty@ttyS0 stalls at an unwaitable
# dev-ttyS0.device job). That generated unit is therefore masked. systemd-udevd
# is explicitly tied to sysinit.target (the package postinst may not have
# enabled it in a Docker build) because udev applies the eth0 rename rule and
# manages the other devices. systemd-journal-catalog-update is masked too: it
# only needs to run when systemd package files are installed/upgraded at
# runtime, which never happens on an immutable image, and it fails otherwise.
RUN set -e \
  && { systemd-sysusers 2>/dev/null || true; } \
  && { systemd-tmpfiles --create 2>/dev/null || true; } \
  && mkdir -p /etc/network /etc/udev/rules.d \
  && mkdir -p /etc/systemd/system/sysinit.target.wants /etc/systemd/system/getty.target.wants \
  && mkdir -p /etc/systemd/system/multi-user.target.wants \
  && ln -sfn /usr/lib/systemd/system/systemd-udevd.service \
       /etc/systemd/system/sysinit.target.wants/systemd-udevd.service \
  && ln -sfn /usr/lib/systemd/system/openworld-serial-console.service \
       /etc/systemd/system/getty.target.wants/openworld-serial-console.service \
  && ln -sfn /usr/lib/systemd/system/openworld-firstboot.service \
       /etc/systemd/system/multi-user.target.wants/openworld-firstboot.service \
  && ln -sf /dev/null /etc/systemd/system/serial-getty@ttyS0.service \
  && ln -sf /dev/null /etc/systemd/system/systemd-journal-catalog-update.service

COPY interfaces /etc/network/interfaces
COPY 99-openworld-eth0.rules /etc/udev/rules.d/99-openworld-eth0.rules
COPY openworld-serial-console.service /usr/lib/systemd/system/openworld-serial-console.service
COPY openworld-firstboot.sh /usr/local/sbin/openworld-firstboot.sh
COPY openworld-firstboot.service /usr/lib/systemd/system/openworld-firstboot.service

RUN set -e \
  && chmod +x /usr/local/sbin/openworld-firstboot.sh \
  && { sed -i 's/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-s"/' \
         /etc/default/dropbear 2>/dev/null \
       || echo 'DROPBEAR_EXTRA_ARGS="-s"' >> /etc/default/dropbear; } \
  && rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/lintian /usr/share/bug

# -- microVM slimming: fixed hardware + immutable image, so the udev hwdb
# (device property DB), journal catalogs, locale data and most terminfo entries
# are dead weight. Core systemd is one multi-call binary, so only the unused
# tool symlinks (systemd-analyze, coredump, sleep, hwdb) go - nothing a boot
# unit invokes.
RUN set -e \
  && rm -f /usr/bin/systemd-analyze /usr/lib/systemd/systemd-analyze \
          /usr/bin/systemd-hwdb /usr/lib/systemd/systemd-hwdb \
          /usr/lib/systemd/systemd-coredump /usr/bin/coredumpctl \
          /usr/lib/systemd/systemd-sleep \
  && rm -rf /usr/lib/systemd/catalog \
  && rm -rf /usr/lib/udev/hwdb.d \
  && rm -f /usr/lib/udev/hwdb.bin /lib/udev/hwdb.bin \
          /usr/share/udev/hwdb.bin /etc/udev/hwdb.bin \
  && rm -rf /usr/share/locale /usr/lib/locale \
  && mkdir -p /tmp/keep/terminfo \
  && for d in /usr/share/terminfo /usr/lib/terminfo /lib/terminfo /etc/terminfo; do \
       [ -d "$d" ] || continue; \
       for e in x/xterm x/xterm-256color l/linux v/vt100 v/vt220 d/dumb s/screen a/ansi; do \
         [ -f "$d/$e" ] || continue; \
         mkdir -p "/tmp/keep/terminfo/$(dirname "$e")"; \
         cp -a "$d/$e" "/tmp/keep/terminfo/$e"; \
       done; \
     done \
  && rm -rf /usr/share/terminfo /usr/lib/terminfo /lib/terminfo /etc/terminfo \
  && mkdir -p /usr/share/terminfo \
  && cp -a /tmp/keep/terminfo/. /usr/share/terminfo/ \
  && rm -rf /tmp/keep \
  && ln -sf /dev/null /etc/systemd/system/systemd-hwdb-update.service \
  && ln -sf /dev/null /etc/systemd/system/systemd-coredump.socket \
  && ln -sf /dev/null /etc/systemd/system/systemd-coredump.service

# Optional: set a root password so the console/login works. Without it root
# stays password-locked (the intended key-only dropbear setup).
ARG OPENWORLD_ROOTPW=
RUN if [ -n "$OPENWORLD_ROOTPW" ]; then \
      printf 'root:%s\n' "$OPENWORLD_ROOTPW" | chpasswd; \
    else \
      echo "note: OPENWORLD_ROOTPW not set; root stays password-locked"; \
    fi

# Optional access: bake a public key into the "openworld" user. Without it the
# image still boots but has no ssh-configured account (dropbear stays key-only).
ARG OPENWORLD_PUBKEY=
RUN set -e \
  && useradd -m -s /bin/bash openworld \
  && if [ -n "$OPENWORLD_PUBKEY" ]; then \
       install -d -m700 -o openworld -g openworld /home/openworld/.ssh \
       && printf '%s\n' "$OPENWORLD_PUBKEY" > /home/openworld/.ssh/authorized_keys \
       && chmod 600 /home/openworld/.ssh/authorized_keys; \
     else \
       echo "note: OPENWORLD_PUBKEY not set; no ssh key baked in"; \
     fi