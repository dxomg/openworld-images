# Rootfs for the openworld Alpine cloud image.
# Provisioned from the official rolling base. The resulting image is exported
# and projected onto an ext4 .img by scripts/build-rootfs.sh.
FROM alpine:latest

# The base/minirootfs hands /sbin/init to openrc via /etc/inittab; install it
# plus netifrc (networking) and dropbear, and add a serial getty on ttyS0 so a
# VM always has a login prompt.
RUN mkdir -p /etc/network \
  && apk add --no-cache openrc dropbear netifrc \
  && printf 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100\n' >> /etc/inittab \
  && mkdir -p /run/openrc \
  && touch /run/openrc/softlevel \
  && rc-update add devfs sysinit \
  && rc-update add sysfs sysinit

# Overwrite any init script the dropbear apk ships: this one forces key-only
# logins (-s) and generates host keys on first start.
COPY images/alpine/interfaces /etc/network/interfaces
COPY images/alpine/dropbear.init /etc/init.d/dropbear
COPY images/openworld-provision.sh /usr/local/sbin/openworld-provision.sh
COPY images/openworld-provision.init /etc/init.d/openworld-provision
COPY images/openworld.conf /etc/openworld.conf

RUN set -e \
  && chmod +x /etc/init.d/dropbear \
  && chmod +x /usr/local/sbin/openworld-provision.sh /etc/init.d/openworld-provision \
  && rc-update add networking default \
  && rc-update add dropbear default \
  && rc-update add openworld-provision default \
  && rm -rf /var/cache/apk/* /usr/share/doc /usr/share/man /usr/share/info

# Optional: set a root password so the console/login works. Without it root
# stays password-locked (the intended key-only dropbear setup).
ARG OPENWORLD_ROOTPW=
RUN if [ -n "$OPENWORLD_ROOTPW" ]; then \
      printf 'root:%s\n' "$OPENWORLD_ROOTPW" | chpasswd; \
    else \
      echo "note: OPENWORLD_ROOTPW not set; root stays password-locked"; \
    fi

# Optional access: bake a public key into the "openworld" user.
ARG OPENWORLD_PUBKEY=
RUN if [ -n "$OPENWORLD_PUBKEY" ]; then \
      adduser -D -h /home/openworld openworld; \
      install -d -m700 -o openworld -g openworld /home/openworld/.ssh; \
      printf '%s\n' "$OPENWORLD_PUBKEY" > /home/openworld/.ssh/authorized_keys; \
      chmod 600 /home/openworld/.ssh/authorized_keys; \
    else \
      echo "note: OPENWORLD_PUBKEY not set; no ssh key baked in"; \
    fi