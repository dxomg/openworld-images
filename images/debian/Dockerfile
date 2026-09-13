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

# dropbear is the only ssh server (openssh-server is never installed): the
# postinst leaves NO_START=0 so its service is enabled at boot; -s enforces
# key-only logins. Best-effort systemd-sysusers/systemd-tmpfiles here so the
# exported rootfs is consistent (systemd redoes it at first boot anyway).
RUN set -e \
  && { systemd-sysusers 2>/dev/null || true; } \
  && { systemd-tmpfiles --create 2>/dev/null || true; } \
  && mkdir -p /etc/network /etc/udev/rules.d

COPY interfaces /etc/network/interfaces
COPY 99-openworld-eth0.rules /etc/udev/rules.d/99-openworld-eth0.rules

RUN set -e \
  && { sed -i 's/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-s"/' \
         /etc/default/dropbear 2>/dev/null \
       || echo 'DROPBEAR_EXTRA_ARGS="-s"' >> /etc/default/dropbear; } \
  && rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/lintian /usr/share/bug

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