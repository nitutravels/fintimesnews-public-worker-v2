#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_IP="${NAMS_PUBLIC_IP:-161.118.187.93}"
REMOTE_INSTALLER="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/nams-hybrid-installer/nams-hybrid/install.sh"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"

trap 'code=$?; echo; echo "INSTALLER STOPPED at line $LINENO (exit $code)." >&2; exit $code' ERR

echo "NAMS Hybrid deployment bootstrap v2"
echo "Target VM: ubuntu@$PUBLIC_IP"

if [ ! -f "$KEY" ]; then
  KEY="$(find "$HOME" -maxdepth 4 -type f -name 'nams.key' -print -quit 2>/dev/null || true)"
fi
if [ -z "${KEY:-}" ] || [ ! -f "$KEY" ]; then
  echo "ERROR: nams.key was not found in Oracle Cloud Shell." >&2
  echo "Use Cloud Shell Menu > Upload, upload nams.key, then run this command again." >&2
  exit 1
fi
chmod 600 "$KEY"
echo "SSH key: $KEY"

echo "[1/4] Checking SSH port 22..."
if ! timeout 12 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then
  echo "ERROR: TCP port 22 is not reachable on $PUBLIC_IP." >&2
  echo "Check that the instance is RUNNING and OCI ingress permits TCP 22." >&2
  exit 1
fi

echo "[2/4] Testing SSH authentication..."
ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
SSH_OPTS=(
  -i "$KEY"
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o ConnectionAttempts=1
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
  -o StrictHostKeyChecking=accept-new
)

if ! timeout 40 ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" 'echo "SSH connected to $(hostname)"; sudo -n true'; then
  echo "ERROR: SSH authentication failed or passwordless sudo is unavailable." >&2
  echo "Confirm that nams.key is the private key created for this instance." >&2
  exit 1
fi

echo "[3/4] Downloading the deployment script on the VM..."
ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" \
  "curl -fL --connect-timeout 20 --retry 4 --retry-delay 3 '$REMOTE_INSTALLER' -o /tmp/nams-install.sh && chmod 700 /tmp/nams-install.sh && wc -l /tmp/nams-install.sh"

echo "[4/4] Installing Docker, Lightpanda, Ollama and NAMS..."
echo "This can take 10-25 minutes. Keep Cloud Shell open. Progress will appear below."
ssh -tt "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" \
  "sudo PUBLIC_IP='$PUBLIC_IP' bash -x /tmp/nams-install.sh"

echo
echo "Deployment command completed."
echo "Use the dashboard URL and token printed above."
