#!/usr/bin/env bash
set -Eeuo pipefail

IP="${NAMS_IP:-130.210.15.29}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"

if [ ! -f "$KEY" ]; then KEY="$HOME/nams-dedicated.key"; fi
if [ ! -f "$KEY" ]; then
  KEY="$(find "$HOME" -maxdepth 3 -type f \( -name 'nams.key' -o -name 'nams-dedicated.key' \) -print -quit 2>/dev/null || true)"
fi
if [ -z "${KEY:-}" ] || [ ! -f "$KEY" ]; then
  echo "SSH key not found in Oracle Cloud Shell." >&2
  exit 1
fi
chmod 600 "$KEY"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

TOKEN="$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "ubuntu@$IP" 'sudo bash -s' <<'REMOTE'
set -e
TOKEN=""
if [ -s /opt/nams-hybrid/dashboard-token.txt ]; then
  TOKEN="$(tr -d '\r\n' </opt/nams-hybrid/dashboard-token.txt)"
fi
if [ -z "$TOKEN" ] && [ -f /opt/nams-hybrid/.env ]; then
  TOKEN="$(sed -n 's/^ADMIN_TOKEN=//p' /opt/nams-hybrid/.env | tail -1 | tr -d '\r\n')"
fi
if [ -z "$TOKEN" ]; then
  CID="$(docker ps --filter name=nams-hybrid-agent --format '{{.ID}}' | head -1)"
  if [ -n "$CID" ]; then
    TOKEN="$(docker inspect "$CID" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^ADMIN_TOKEN=//p' | tail -1 | tr -d '\r\n')"
  fi
fi
printf '%s' "$TOKEN"
REMOTE
)"

if [ -z "$TOKEN" ]; then
  echo "No dashboard token could be read from the VM." >&2
  exit 1
fi

echo
echo "CURRENT DASHBOARD TOKEN"
echo "$TOKEN"
echo
echo "OPEN THIS EXACT URL"
echo "http://$DOMAIN/?token=$TOKEN"
echo
echo "Use HTTP for now, not HTTPS."
