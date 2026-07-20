#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
INSTANCE_NAME="NAMS-Lightpanda-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
REMOTE_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/18a8cc90811d45eefe72564bb008f83459b5eab1/nams-v5/remote-resume-v5.sh"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"

valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }

echo "NAMS v5 interrupted-install recovery"
echo "Domain: $DOMAIN"

echo "[1/6] Finding the dedicated instance..."
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$COMPARTMENT_ID" || { echo "Could not find compartment $COMPARTMENT_NAME" >&2; exit 1; }
INSTANCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$INSTANCE_ID" || { echo "Could not find active instance $INSTANCE_NAME" >&2; exit 1; }
STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
if [ "$STATE" = "STOPPED" ]; then
  echo "Starting the dedicated instance..."
  oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
elif [ "$STATE" != "RUNNING" ]; then
  echo "Instance state is $STATE; waiting for RUNNING..."
  oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --wait-for-state RUNNING --max-wait-seconds 900 >/dev/null
fi

PUBLIC_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No public IP is assigned to the NAMS instance." >&2; exit 1; }
echo "Public IP: $PUBLIC_IP"

if [ ! -f "$KEY" ]; then KEY="$HOME/nams-dedicated.key"; fi
if [ ! -f "$KEY" ]; then KEY="$(find "$HOME" -maxdepth 3 -type f \( -name 'nams.key' -o -name 'nams-dedicated.key' \) -print -quit 2>/dev/null || true)"; fi
[ -n "${KEY:-}" ] && [ -f "$KEY" ] || { echo "SSH key not found in Cloud Shell." >&2; exit 1; }
chmod 600 "$KEY"
ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o ConnectionAttempts=3 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP")

echo "[2/6] Waiting for SSH..."
for i in $(seq 1 40); do
  if "${SSH[@]}" 'echo SSH_READY' 2>/dev/null | grep -q SSH_READY; then break; fi
  [ "$i" -eq 40 ] && { echo "SSH did not become available." >&2; exit 1; }
  sleep 10
done

echo "[3/6] Installing the resumable repair worker..."
"${SSH[@]}" "curl -fL --retry 5 --connect-timeout 20 '$REMOTE_URL' -o /tmp/nams-v5-resume.sh && chmod +x /tmp/nams-v5-resume.sh"

echo "[4/6] Starting recovery in the VM background..."
"${SSH[@]}" "sudo rm -f /var/lib/nams-v5-resume.status /var/log/nams-v5-resume.log; sudo nohup env NAMS_DOMAIN='$DOMAIN' bash /tmp/nams-v5-resume.sh >/dev/null 2>&1 </dev/null &"

echo "[5/6] Monitoring recovery. It can take 15-35 minutes."
LAST=''
for i in $(seq 1 140); do
  STATUS="$("${SSH[@]}" 'sudo cat /var/lib/nams-v5-resume.status 2>/dev/null || echo STARTING' 2>/dev/null || echo RECONNECTING)"
  if [ "$STATUS" != "$LAST" ] || [ $((i % 3)) -eq 0 ]; then
    echo "Status: $STATUS — $((i*15/60)) minute(s) elapsed"
    "${SSH[@]}" 'sudo tail -n 8 /var/log/nams-v5-resume.log 2>/dev/null || true' 2>/dev/null || true
    LAST="$STATUS"
  fi
  if [ "$STATUS" = "SUCCESS" ]; then break; fi
  if [[ "$STATUS" == FAILED:* ]]; then
    echo "Recovery failed. Full recent diagnostic:" >&2
    "${SSH[@]}" 'sudo tail -n 220 /var/log/nams-v5-resume.log; cd /opt/nams-v5 2>/dev/null && sudo docker compose ps && sudo docker compose logs --tail=120 app chromium lightpanda caddy ollama || true' || true
    exit 1
  fi
  [ "$i" -eq 140 ] && { echo "Recovery did not finish within 35 minutes." >&2; "${SSH[@]}" 'sudo tail -n 220 /var/log/nams-v5-resume.log' || true; exit 1; }
  sleep 15
done

echo "[6/6] Reading the verified dashboard details..."
RESULT="$("${SSH[@]}" "sudo grep -E '^(NAMS_V5_READY|DOMAIN=|TOKEN=|DASHBOARD=|BROWSER=)' /var/log/nams-v5-resume.log | tail -5")"
printf '%s\n' "$RESULT"
TOKEN="$(printf '%s\n' "$RESULT" | sed -n 's/^TOKEN=//p' | tail -1)"
[ -n "$TOKEN" ] || { echo "Recovery completed but no token was returned." >&2; exit 1; }

echo
echo "NAMS V5 IS WORKING"
echo "Dashboard: https://$DOMAIN/?token=$TOKEN"
echo "Token: $TOKEN"
echo "Live browser: https://$DOMAIN/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify"
