#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
INSTANCE_NAME="NAMS-Lightpanda-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/nams-hybrid-installer/nams-v5/install-v5.sh"

valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }

echo "NAMS v5 replacement deployment"
echo "Domain: $DOMAIN"

echo "[1/5] Finding the dedicated OCI instance..."
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$COMPARTMENT_ID" || { echo "Could not find compartment $COMPARTMENT_NAME" >&2; exit 1; }
INSTANCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$INSTANCE_ID" || { echo "Could not find active instance $INSTANCE_NAME" >&2; exit 1; }
STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
if [ "$STATE" = "STOPPED" ]; then
  oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
fi
PUBLIC_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No public IP found" >&2; exit 1; }
echo "Instance IP: $PUBLIC_IP"

if [ ! -f "$KEY" ]; then KEY="$HOME/nams-dedicated.key"; fi
[ -f "$KEY" ] || { echo "SSH key not found in Cloud Shell" >&2; exit 1; }
chmod 600 "$KEY"
ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true

 echo "[2/5] Waiting for SSH..."
for _ in $(seq 1 30); do
  timeout 5 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null && break
  sleep 10
done
timeout 5 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null || { echo "SSH port 22 is not reachable" >&2; exit 1; }

 echo "[3/5] Running replacement installer on the server..."
ssh -tt -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=20 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP" \
  "curl -fL --retry 5 --connect-timeout 20 '$INSTALLER_URL' -o /tmp/nams-v5-install.sh && chmod +x /tmp/nams-v5-install.sh && sudo env NAMS_DOMAIN='$DOMAIN' PUBLIC_IP='$PUBLIC_IP' bash /tmp/nams-v5-install.sh"

 echo "[4/5] Reading the active token..."
TOKEN="$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP" "sudo awk -F= '/^ADMIN_TOKEN=/{print substr(\$0,index(\$0,\"=\")+1)}' /opt/nams-v5/.env")"
[ -n "$TOKEN" ] || { echo "Deployment completed but token could not be read" >&2; exit 1; }

 echo "[5/5] Verifying HTTPS health..."
for _ in $(seq 1 30); do
  curl -fsS --connect-timeout 10 "https://$DOMAIN/health" >/dev/null 2>&1 && break
  sleep 10
done
curl -fsS --connect-timeout 10 "https://$DOMAIN/health" || true

echo
echo "REPLACEMENT DEPLOYED"
echo "Dashboard: https://$DOMAIN/?token=$TOKEN"
echo "Token: $TOKEN"
echo "Live browser: https://$DOMAIN/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify"
