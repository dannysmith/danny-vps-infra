#!/usr/bin/env bash
#
# setup.sh — Provision a fresh Ubuntu 24.04 VPS for danny-vps-infra.
# Run as root. Idempotent (safe to re-run).
#
# Optional env vars:
#   VOLUME_DEVICE   Path to Hetzner Storage Volume (e.g. /dev/disk/by-id/scsi-0HC_Volume_12345).
#                   If unset, the volume mount step is skipped.
#   VOLUME_FORMAT   If set to "1" and VOLUME_DEVICE has no filesystem, format it ext4.
#                   Required for a fresh volume — guards against accidental data loss.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

if ! grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
  echo "Error: This script is intended for Ubuntu." >&2
  exit 1
fi

. /etc/os-release
ARCH=$(dpkg --print-architecture)
echo "==> Running on Ubuntu $VERSION_ID ($VERSION_CODENAME), arch: $ARCH"

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------

echo "==> Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ---------------------------------------------------------------------------
# 2. Create user 'danny' with sudo + SSH keys
# ---------------------------------------------------------------------------

echo "==> Setting up user 'danny'..."
if ! id danny &>/dev/null; then
  adduser --disabled-password --gecos "" danny
  echo "    Created user danny"
else
  echo "    User danny already exists"
fi

usermod -aG sudo danny

if [[ ! -f /etc/sudoers.d/danny ]]; then
  echo "danny ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/danny
  chmod 440 /etc/sudoers.d/danny
  echo "    Configured passwordless sudo"
fi

DANNY_SSH_DIR="/home/danny/.ssh"
mkdir -p "$DANNY_SSH_DIR"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "$DANNY_SSH_DIR/authorized_keys"
  chown -R danny:danny "$DANNY_SSH_DIR"
  chmod 700 "$DANNY_SSH_DIR"
  chmod 600 "$DANNY_SSH_DIR/authorized_keys"
  echo "    Copied SSH keys from root"
fi

# ---------------------------------------------------------------------------
# 3. SSH hardening
# ---------------------------------------------------------------------------

echo "==> Hardening SSH..."
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'SSHEOF'
PermitRootLogin no
PasswordAuthentication no
SSHEOF

systemctl restart ssh
echo "    SSH hardened (root login disabled, password auth disabled)"

# ---------------------------------------------------------------------------
# 4. Timezone
# ---------------------------------------------------------------------------

echo "==> Setting timezone to UTC..."
timedatectl set-timezone UTC

# ---------------------------------------------------------------------------
# 5. Install apt packages
# ---------------------------------------------------------------------------

echo "==> Installing apt packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl wget jq htop tmux git unzip tree \
  ufw fail2ban \
  unattended-upgrades apt-listchanges \
  ca-certificates gnupg

# ---------------------------------------------------------------------------
# 6. Install Docker (from Docker's official repo)
# ---------------------------------------------------------------------------

echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<DOCKEREOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $VERSION_CODENAME
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
DOCKEREOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  echo "    Docker installed"
else
  echo "    Docker already installed"
fi

usermod -aG docker danny

echo "==> Configuring Docker daemon..."
DAEMON_JSON="/etc/docker/daemon.json"
if [[ ! -f "$DAEMON_JSON" ]]; then
  cat > "$DAEMON_JSON" <<'DAEMONJSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DAEMONJSON
  systemctl restart docker
  echo "    Docker daemon configured (log rotation: 10m x 3)"
else
  echo "    Docker daemon.json already exists (skipping)"
fi

# ---------------------------------------------------------------------------
# 7. Create shared Docker network
# ---------------------------------------------------------------------------

echo "==> Creating shared Docker network 'caddy-net'..."
if ! docker network inspect caddy-net &>/dev/null; then
  docker network create caddy-net
  echo "    Created caddy-net"
else
  echo "    caddy-net already exists"
fi

# ---------------------------------------------------------------------------
# 7a. Kernel tuning for QUIC / HTTP/3
# ---------------------------------------------------------------------------
# Caddy enables HTTP/3 by default. quic-go wants ~7.5 MB UDP receive/send
# buffers; Ubuntu's defaults are ~200 KB, which triggers a warning and
# caps throughput. Raise the ceilings so Caddy can size its buffers properly.
# See https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes

echo "==> Configuring kernel UDP buffers for HTTP/3..."
SYSCTL_CONF="/etc/sysctl.d/99-caddy-quic.conf"
cat > "$SYSCTL_CONF" <<'SYSCTLEOF'
# Managed by danny-vps-infra/setup.sh — re-run the script to update.
# Larger UDP buffers for Caddy's HTTP/3 (QUIC) listener.
net.core.rmem_max=7500000
net.core.wmem_max=7500000
SYSCTLEOF
sysctl --system >/dev/null
echo "    UDP buffer ceilings raised to 7.5 MB"

# ---------------------------------------------------------------------------
# 8. Configure UFW
# ---------------------------------------------------------------------------

echo "==> Configuring UFW..."
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 443/udp   # HTTP/3 (QUIC)
ufw --force enable
echo "    UFW configured and enabled"

# ---------------------------------------------------------------------------
# 9. Configure fail2ban
# ---------------------------------------------------------------------------

echo "==> Configuring fail2ban..."
if [[ ! -f /etc/fail2ban/jail.local ]]; then
  cat > /etc/fail2ban/jail.local <<'F2BEOF'
[sshd]
enabled = true
F2BEOF
  echo "    fail2ban SSH jail configured"
fi

systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# 10. Configure unattended-upgrades
# ---------------------------------------------------------------------------

echo "==> Configuring unattended-upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UUEOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
echo "    Unattended-upgrades configured"

# ---------------------------------------------------------------------------
# 11. Mount storage volume at /mnt/data
# ---------------------------------------------------------------------------

echo "==> Configuring storage volume..."
if [[ -z "${VOLUME_DEVICE:-}" ]]; then
  echo "    VOLUME_DEVICE not set — skipping volume mount"
  echo "    (Re-run with VOLUME_DEVICE=/dev/disk/by-id/scsi-0HC_Volume_<id> to mount)"
elif [[ ! -b "$VOLUME_DEVICE" ]]; then
  echo "    Error: VOLUME_DEVICE=$VOLUME_DEVICE is not a block device" >&2
  exit 1
else
  mkdir -p /mnt/data

  if mountpoint -q /mnt/data; then
    echo "    /mnt/data is already mounted — skipping"
  else
    # Check if the device has a filesystem
    if ! blkid "$VOLUME_DEVICE" &>/dev/null; then
      if [[ "${VOLUME_FORMAT:-}" == "1" ]]; then
        echo "    Formatting $VOLUME_DEVICE as ext4..."
        mkfs.ext4 -F "$VOLUME_DEVICE"
      else
        echo "    Error: $VOLUME_DEVICE has no filesystem." >&2
        echo "    Re-run with VOLUME_FORMAT=1 to format it as ext4 (destroys any existing data)." >&2
        exit 1
      fi
    fi

    VOLUME_UUID=$(blkid -s UUID -o value "$VOLUME_DEVICE")
    FSTAB_LINE="UUID=$VOLUME_UUID /mnt/data ext4 discard,nofail,defaults 0 2"
    if ! grep -q "UUID=$VOLUME_UUID" /etc/fstab; then
      echo "$FSTAB_LINE" >> /etc/fstab
      echo "    Added /etc/fstab entry (UUID=$VOLUME_UUID)"
    else
      echo "    /etc/fstab entry already present"
    fi

    mount /mnt/data
    echo "    Mounted $VOLUME_DEVICE at /mnt/data"
  fi

  chown danny:danny /mnt/data
fi

# ---------------------------------------------------------------------------
# 12. Install user-level tools for danny (GitHub CLI, Bun, Claude Code)
# ---------------------------------------------------------------------------

echo "==> Installing external tools..."

# --- GitHub CLI (system-wide via apt) ---
if ! command -v gh &>/dev/null; then
  echo "    Installing GitHub CLI..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/github-cli.gpg
  chmod a+r /etc/apt/keyrings/github-cli.gpg

  cat > /etc/apt/sources.list.d/github-cli.sources <<'GHEOF'
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/github-cli.gpg
GHEOF

  apt-get update
  apt-get install -y gh
  echo "    GitHub CLI installed"
else
  echo "    GitHub CLI already installed"
fi

# --- Bun (as danny) ---
if [[ ! -f /home/danny/.bun/bin/bun ]]; then
  echo "    Installing Bun..."
  sudo -iu danny bash -c 'curl -fsSL https://bun.sh/install | bash'
  echo "    Bun installed"
else
  echo "    Bun already installed"
fi

# --- Claude Code (as danny) ---
if ! sudo -iu danny bash -c 'command -v claude' &>/dev/null; then
  echo "    Installing Claude Code..."
  sudo -iu danny bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  echo "    Claude Code installed"
else
  echo "    Claude Code already installed"
fi

# ---------------------------------------------------------------------------
# 13. Configure bash environment
# ---------------------------------------------------------------------------

echo "==> Configuring bash environment for danny..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/configure-bash.sh" danny

# ---------------------------------------------------------------------------
# 14. Install cron jobs
# ---------------------------------------------------------------------------

echo "==> Installing cron jobs..."
CRON_FILE="/etc/cron.d/danny-vps-infra"
cat > "$CRON_FILE" <<'CRONEOF'
# Managed by danny-vps-infra/setup.sh — re-run the script to update.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Weekly Docker prune (Sunday 04:00 UTC) — removes unused images older than 7d
0 4 * * 0 root docker system prune -af --filter "until=168h" >> /var/log/docker-prune.log 2>&1
CRONEOF
chmod 644 "$CRON_FILE"
echo "    Installed /etc/cron.d/danny-vps-infra (weekly Docker prune)"

# ---------------------------------------------------------------------------
# 15. Summary
# ---------------------------------------------------------------------------

VPS_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "Installed:"
echo "  - Docker:          $(docker --version 2>/dev/null || echo 'check manually')"
echo "  - Docker Compose:  $(docker compose version 2>/dev/null || echo 'check manually')"
echo "  - GitHub CLI:      $(gh --version 2>/dev/null | head -1 || echo 'check manually')"
echo ""
echo "User-level tools (installed for danny):"
echo "  - Bun:             $(sudo -iu danny bash -c 'bun --version' 2>/dev/null || echo 'check manually')"
echo "  - Claude Code:     $(sudo -iu danny bash -c 'claude --version' 2>/dev/null || echo 'check manually')"
echo ""
echo "Security:"
echo "  - SSH:             root login disabled, password auth disabled"
echo "  - UFW:             $(ufw status | head -1)"
echo "  - fail2ban:        $(systemctl is-active fail2ban 2>/dev/null)"
echo "  - Unattended upgrades: $(systemctl is-active unattended-upgrades 2>/dev/null)"
echo ""
echo "Docker:"
echo "  - Network:         $(docker network inspect caddy-net -f '{{.Name}}' 2>/dev/null || echo 'missing')"
echo "  - Log rotation:    10m x 3"
echo ""
echo "Storage:"
if [[ -n "${VOLUME_DEVICE:-}" ]] && mountpoint -q /mnt/data; then
  echo "  - /mnt/data:       mounted ($(df -h /mnt/data | awk 'NR==2{print $2" total, "$4" free"}'))"
else
  echo "  - /mnt/data:       not mounted (set VOLUME_DEVICE and re-run)"
fi
echo ""
echo "⚠  NEXT STEPS:"
echo "  1. TEST SSH as danny before closing this root session:"
echo "     ssh danny@$VPS_IP"
echo "  2. Create DNS A record: server.danny.is → $VPS_IP (on DNSimple)"
echo "  3. Clone this repo to ~/danny-vps-infra as danny, then:"
echo "       cd ~/danny-vps-infra/caddy && docker compose up -d"
echo "  4. Verify: https://server.danny.is → 'Hello from danny-vps-infra'"
echo ""
