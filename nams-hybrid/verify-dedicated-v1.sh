#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
INSTANCE_NAME="NAMS-Lightpanda-Agent"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"

valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }

printf '\nNAMS dedicated deployment verification\n\n'

echo "[1/6] Resolving compartment..."
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$COMPARTMENT_ID"; then
  echo "Could not resolve compartment $COMPARTMENT_NAME." >&2
  exit 1
fi

echo "[2/6] Finding instance $INSTANCE_NAME..."
INSTANCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$INSTANCE_ID"; then
  echo "No active instance named $INSTANCE_NAME was found." >&2
  echo "The provisioning command did not complete successfully or the instance has another name." >&2
  echo "Instances currently visible in $COMPARTMENT_NAME:" >&2
  oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --all --query 'data[].["display-name","lifecycle-state"]' --output table || true
  exit 1
fi

STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
echo "State: $STATE"
if [ "$STATE" = "STOPPED" ]; then
  echo "Starting instance..."
  oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
fi

echo "[3/6] Resolving public IP..."
PUBLIC_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
if ! [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Instance exists but has no public IPv4 address." >&2
  exit 1
fi
echo "Public IP: $PUBLIC_IP"

echo "[4/6] Checking HTTP health endpoint..."
if curl -fsS --connect-timeout 8 "http://$PUBLIC_IP/health" >/tmp/nams-health.json 2>/dev/null; then
  echo "Health: OK ($(cat /tmp/nams-health.json))"
else
  echo "Health: NOT READY"
fi

if [ ! -f "$KEY" ]; then
  KEY="$HOME/nams-dedicated.key"
fi
if [ ! -f "$KEY" ]; then
  echo "SSH key not found. Expected $HOME/nams.key or $HOME/nams-dedicated.key." >&2
  exit 1
fi
chmod 600 "$KEY"
ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true

echo "[5/6] Reading service status and dashboard token from the VM..."
SSH_OUTPUT="$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP" '
set -e
TOKEN=$(sudo awk -F= '\''$1=="ADMIN_TOKEN"{print substr($0,index($0,"=")+1)}'\'' /opt/nams-hybrid/.env 2>/dev/null || true)
echo "TOKEN=$TOKEN"
echo "--- DOCKER STATUS ---"
cd /opt/nams-hybrid && sudo docker compose ps || true
echo "--- INSTALL STATUS ---"
sudo cloud-init status --long || true
echo "--- RECENT INSTALL LOG ---"
sudo tail -n 60 /var/log/nams-install.log 2>/dev/null || true
' 2>&1)"
printf '%s\n' "$SSH_OUTPUT"
TOKEN="$(printf '%s\n' "$SSH_OUTPUT" | awk -F= '/^TOKEN=/{print substr($0,index($0,"=")+1); exit}')"

echo "[6/6] Result"
if curl -fsS --connect-timeout 8 "http://$PUBLIC_IP/health" >/dev/null 2>&1 && [ -n "$TOKEN" ]; then
  echo
  echo "DEPLOYMENT VERIFIED"
  echo "Dashboard: http://$PUBLIC_IP/?token=$TOKEN"
  echo "Token: $TOKEN"
else
  echo
  echo "The instance exists, but installation is not yet healthy."
  echo "Use the log output above to identify the failed installation step."
  exit 1
fi
