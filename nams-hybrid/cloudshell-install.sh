#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE_NAME="${NAMS_INSTANCE_NAME:-nams-phase1}"
REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
REMOTE_INSTALLER="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/nams-hybrid-installer/nams-hybrid/install.sh"

trap 'echo; echo "FAILED at line $LINENO" >&2' ERR

echo "[1/7] Reading OCI tenancy configuration..."
CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
TENANCY_ID="${OCI_TENANCY:-${OCI_CLI_TENANCY:-}}"
if [ -z "$TENANCY_ID" ] && [ -f "$CONFIG_FILE" ]; then
  TENANCY_ID="$(awk -F= 'tolower($1)=="tenancy" {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CONFIG_FILE")"
fi
if [ -z "$TENANCY_ID" ]; then
  echo "Could not determine the tenancy OCID from $CONFIG_FILE." >&2
  exit 1
fi

echo "[2/7] Locating OCI instance: $INSTANCE_NAME"
INSTANCES_JSON="$(oci compute instance list --region "$REGION" --compartment-id "$TENANCY_ID" --display-name "$INSTANCE_NAME" --all)"
INSTANCE_ID="$(printf '%s' "$INSTANCES_JSON" | python3 -c 'import json,sys; rows=json.load(sys.stdin).get("data",[]); rows=[x for x in rows if x.get("lifecycle-state")!="TERMINATED"]; print(rows[0]["id"] if rows else "")')"
if [ -z "$INSTANCE_ID" ]; then
  echo "No non-terminated instance named $INSTANCE_NAME was found in the root compartment." >&2
  echo "Available non-terminated instances:" >&2
  oci compute instance list --region "$REGION" --compartment-id "$TENANCY_ID" --all --query 'data[?"lifecycle-state"!=`TERMINATED`].["display-name","lifecycle-state"]' --output table || true
  exit 1
fi

STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
echo "Instance state: $STATE"
if [ "$STATE" = "STOPPED" ]; then
  echo "[3/7] Starting the instance..."
  oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action START >/dev/null
fi

for _ in $(seq 1 36); do
  STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
  [ "$STATE" = "RUNNING" ] && break
  echo "Waiting for RUNNING state; current state: $STATE"
  sleep 10
done
if [ "$STATE" != "RUNNING" ]; then
  echo "Instance did not reach RUNNING state." >&2
  exit 1
fi

echo "[4/7] Resolving the current public IP..."
PUBLIC_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)"
if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ] || [ "$PUBLIC_IP" = "None" ]; then
  echo "The instance has no public IPv4 address." >&2
  exit 1
fi
echo "Current public IP: $PUBLIC_IP"

KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
if [ ! -f "$KEY" ]; then
  KEY="$(find "$HOME" -maxdepth 3 -type f -name 'nams.key' -print -quit 2>/dev/null || true)"
fi
if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
  echo "SSH key nams.key was not found in Cloud Shell. Upload it using Cloud Shell Menu > Upload." >&2
  exit 1
fi
chmod 600 "$KEY"

echo "[5/7] Waiting for SSH on $PUBLIC_IP:22..."
SSH_READY=0
for _ in $(seq 1 18); do
  if timeout 5 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then SSH_READY=1; break; fi
  sleep 10
done
if [ "$SSH_READY" -ne 1 ]; then
  echo "SSH port 22 is not reachable at $PUBLIC_IP. Check the OCI security-list ingress rule for TCP 22 and the subnet route." >&2
  exit 1
fi

ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true

echo "[6/7] Connecting to the VM and running the installer with visible output..."
ssh -tt \
  -i "$KEY" \
  -o BatchMode=yes \
  -o ConnectTimeout=20 \
  -o ConnectionAttempts=2 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=4 \
  -o StrictHostKeyChecking=accept-new \
  "ubuntu@$PUBLIC_IP" \
  "set -Eeuo pipefail; echo 'Connected to:' \$(hostname); curl -fL --connect-timeout 20 --retry 3 '$REMOTE_INSTALLER' -o /tmp/nams-install.sh; chmod +x /tmp/nams-install.sh; sudo bash -x /tmp/nams-install.sh"

echo "[7/7] Deployment command completed."
echo "Open the dashboard URL printed by the remote installer."
