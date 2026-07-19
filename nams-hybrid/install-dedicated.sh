#!/usr/bin/env bash
set -Eeuo pipefail

BASE_INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/nams-hybrid-installer/nams-hybrid/install.sh"
TMP=/tmp/nams-base-install.sh

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl ufw

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

curl -fL --retry 5 --connect-timeout 20 "$BASE_INSTALLER_URL" -o "$TMP"
chmod +x "$TMP"

# Make the base installer accept the token supplied by the provisioning script.
sed -i 's/^TOKEN=$(openssl rand -hex 24)$/TOKEN=${ADMIN_TOKEN:-$(openssl rand -hex 24)}/' "$TMP"

PUBLIC_IP="${PUBLIC_IP:-$(curl -fsS --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')}"
ADMIN_TOKEN="${ADMIN_TOKEN:-$(openssl rand -hex 24)}"
export PUBLIC_IP ADMIN_TOKEN

bash "$TMP"
