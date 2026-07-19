#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
REFERENCE_INSTANCE="NituTravelsWAHA-20260719T184923Z"
INSTANCE_NAME="NAMS-Lightpanda-Agent"
NSG_NAME="NAMS-Lightpanda-NSG"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=8
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/39560b7fc04fd6656850924a48b5c874651ca3ee/nams-hybrid/install-dedicated.sh"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
WORK="$(mktemp -d)"
TOKEN="$(openssl rand -hex 24)"
trap 'echo; echo "FAILED at line $LINENO" >&2; rm -rf "$WORK"' ERR
trap 'rm -rf "$WORK"' EXIT

valid_ocid() { [[ "${1:-}" == ocid1.* ]]; }

printf '\nNAMS dedicated Oracle deployment\n'
printf 'Compartment: %s | Region: %s\n' "$COMPARTMENT_NAME" "$REGION"
printf 'New instance: %s (%s, %s OCPU, %s GB)\n\n' "$INSTANCE_NAME" "$SHAPE" "$OCPUS" "$MEMORY_GB"

echo "[1/10] Finding the NituWAGateway compartment..."
COMPARTMENT_ID="$(oci iam compartment list \
  --region "$REGION" \
  --all \
  --compartment-id-in-subtree true \
  --access-level ACCESSIBLE \
  --name "$COMPARTMENT_NAME" \
  --lifecycle-state ACTIVE \
  --query 'data[0].id' \
  --raw-output 2>/dev/null || true)"
if ! valid_ocid "$COMPARTMENT_ID"; then
  echo "Could not resolve compartment $COMPARTMENT_NAME." >&2
  echo "Accessible active compartments:" >&2
  oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --lifecycle-state ACTIVE --query 'data[].name' --output table || true
  exit 1
fi
echo "Compartment OCID resolved."

echo "[2/10] Reading network placement from the existing WAHA instance..."
REFERENCE_ID="$(oci compute instance list \
  --region "$REGION" \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "$REFERENCE_INSTANCE" \
  --all \
  --query 'data[?"lifecycle-state"==`RUNNING`] | [0].id' \
  --raw-output 2>/dev/null || true)"
if ! valid_ocid "$REFERENCE_ID"; then
  REFERENCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --all --query 'data[?"lifecycle-state"==`RUNNING`] | [0].id' --raw-output 2>/dev/null || true)"
fi
if ! valid_ocid "$REFERENCE_ID"; then
  echo "No running reference instance exists in $COMPARTMENT_NAME." >&2
  exit 1
fi
AD="$(oci compute instance get --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data."availability-domain"' --raw-output)"
SUBNET_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data[0]."subnet-id"' --raw-output)"
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
if [ -z "$AD" ] || ! valid_ocid "$SUBNET_ID" || ! valid_ocid "$VCN_ID"; then
  echo "Could not derive availability domain, subnet or VCN from the WAHA instance." >&2
  exit 1
fi
echo "Using the same availability domain and public subnet as WAHA, without modifying WAHA."

echo "[3/10] Creating or reusing a dedicated network security group..."
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$NSG_ID"; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --query 'data.id' --raw-output)"
  cat >"$WORK/nsg-rules.json" <<'JSON'
[
  {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
  {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
  {"direction":"EGRESS","protocol":"all","destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","isStateless":false}
]
JSON
  oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/nsg-rules.json" >/dev/null
fi
echo "Dedicated NSG ready for SSH, HTTP and HTTPS."

echo "[4/10] Selecting the latest compatible Ubuntu 24.04 ARM image..."
IMAGE_ID="$(oci compute image list \
  --region "$REGION" \
  --compartment-id "$COMPARTMENT_ID" \
  --shape "$SHAPE" \
  --operating-system 'Canonical Ubuntu' \
  --operating-system-version '24.04' \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --all \
  --query 'data[0].id' \
  --raw-output 2>/dev/null || true)"
if ! valid_ocid "$IMAGE_ID"; then
  echo "No Ubuntu 24.04 image compatible with $SHAPE was returned." >&2
  exit 1
fi

echo "[5/10] Preparing SSH access and cloud-init..."
if [ ! -f "$KEY" ]; then
  KEY="$HOME/nams-dedicated.key"
  if [ ! -f "$KEY" ]; then
    ssh-keygen -t ed25519 -N '' -f "$KEY" -C nams-dedicated >/dev/null
  fi
fi
chmod 600 "$KEY"
ssh-keygen -y -f "$KEY" >"$WORK/public.key"
cat >"$WORK/cloud-init.yaml" <<CLOUDINIT
#cloud-config
package_update: false
runcmd:
  - [ bash, -lc, "curl -fL --retry 5 --connect-timeout 20 '$INSTALLER_URL' -o /tmp/nams-install-dedicated.sh && chmod +x /tmp/nams-install-dedicated.sh && ADMIN_TOKEN='$TOKEN' bash /tmp/nams-install-dedicated.sh > /var/log/nams-install.log 2>&1" ]
final_message: "NAMS cloud-init completed"
CLOUDINIT

echo "[6/10] Checking whether the dedicated instance already exists..."
INSTANCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
FRESH=0
if ! valid_ocid "$INSTANCE_ID"; then
  echo "[7/10] Launching the new dedicated instance..."
  set +e
  INSTANCE_ID="$(oci compute instance launch \
    --region "$REGION" \
    --availability-domain "$AD" \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$INSTANCE_NAME" \
    --hostname-label nams-lightpanda \
    --shape "$SHAPE" \
    --shape-config '{"ocpus":2,"memoryInGBs":8}' \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --nsg-ids "[\"$NSG_ID\"]" \
    --ssh-authorized-keys-file "$WORK/public.key" \
    --user-data-file "$WORK/cloud-init.yaml" \
    --wait-for-state RUNNING \
    --max-wait-seconds 1200 \
    --query 'data.id' \
    --raw-output)"
  RC=$?
  set -e
  if [ $RC -ne 0 ] || ! valid_ocid "$INSTANCE_ID"; then
    echo "Oracle could not launch the free Ampere instance. The most common reason is temporary host-capacity shortage." >&2
    echo "No existing WAHA resource was changed." >&2
    exit 1
  fi
  FRESH=1
else
  STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
  if [ "$STATE" = "STOPPED" ]; then
    echo "Starting the existing dedicated instance..."
    oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
  fi
fi

echo "[8/10] Resolving the new instance public IP..."
PUBLIC_IP=''
for _ in $(seq 1 40); do
  PUBLIC_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
  if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
  sleep 10
done
if ! [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "The dedicated instance is running but no public IP was assigned." >&2
  exit 1
fi
echo "Dedicated NAMS public IP: $PUBLIC_IP"

if [ "$FRESH" -eq 0 ]; then
  echo "[9/10] Repairing/redeploying the existing dedicated instance..."
  for _ in $(seq 1 30); do
    if timeout 5 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then break; fi
    sleep 10
  done
  ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
  ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP" \
    "curl -fL --retry 5 '$INSTALLER_URL' -o /tmp/nams-install-dedicated.sh && chmod +x /tmp/nams-install-dedicated.sh && sudo env ADMIN_TOKEN='$TOKEN' PUBLIC_IP='$PUBLIC_IP' bash /tmp/nams-install-dedicated.sh"
else
  echo "[9/10] Waiting for cloud-init to install Docker, Lightpanda, Ollama and the AI model..."
fi

READY=0
for i in $(seq 1 90); do
  if curl -fsS --connect-timeout 5 "http://$PUBLIC_IP/health" >/dev/null 2>&1; then READY=1; break; fi
  if [ $((i % 6)) -eq 0 ]; then echo "Still installing... $((i*20/60)) minutes elapsed"; fi
  sleep 20
done

if [ "$READY" -ne 1 ]; then
  echo "The VM was created, but the NAMS health endpoint was not ready within 30 minutes." >&2
  echo "Collecting cloud-init/install logs through SSH..." >&2
  ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
  ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP" \
    "sudo cloud-init status --long || true; sudo tail -n 200 /var/log/nams-install.log 2>/dev/null || true; sudo docker ps -a 2>/dev/null || true" || true
  exit 1
fi

echo "[10/10] Deployment verified."
echo
echo "DEDICATED NAMS INSTALLATION COMPLETE"
echo "Instance: $INSTANCE_NAME"
echo "Public IP: $PUBLIC_IP"
echo "Dashboard: http://$PUBLIC_IP/?token=$TOKEN"
echo "Token: $TOKEN"
echo "SSH key retained at: $KEY"
echo
echo "The existing WAHA instance $REFERENCE_INSTANCE was not modified."
