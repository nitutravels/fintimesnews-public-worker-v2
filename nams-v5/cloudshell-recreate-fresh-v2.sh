#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
INSTANCE_NAME="NAMS-Lightpanda-Agent"
REFERENCE_INSTANCE="NituTravelsWAHA-20260719T184923Z"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
SHAPE="VM.Standard.A1.Flex"
RESERVED_IP_NAME="NAMS-v5-Reserved-IP"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/ae115249f104390848873bd75923d4c9e6b2ebda/nams-v5/install-v5-fresh-v2.sh"
TOKEN="$(openssl rand -hex 24)"
WORK="$(mktemp -d)"
trap 'rc=$?; echo; echo "FAILED at line $LINENO (exit $rc)" >&2; rm -rf "$WORK"; exit $rc' ERR
trap 'rm -rf "$WORK"' EXIT
valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }

echo
echo "NAMS clean rebuild v2"
echo "The old VM has neither working SSH nor a running Oracle Run Command plugin."
echo "Only the broken $INSTANCE_NAME VM will be replaced; WAHA will not be modified."

echo "[1/12] Resolving compartment and placement..."
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$COMPARTMENT_ID" || { echo "Could not resolve compartment $COMPARTMENT_NAME." >&2; exit 1; }
OLD_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
REF_ID="$OLD_ID"
if ! valid_ocid "$REF_ID"; then REF_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$REFERENCE_INSTANCE" --all --query 'data[?"lifecycle-state"==`RUNNING`] | [0].id' --raw-output 2>/dev/null || true)"; fi
valid_ocid "$REF_ID" || { echo "No placement reference instance was found." >&2; exit 1; }
AD="$(oci compute instance get --region "$REGION" --instance-id "$REF_ID" --query 'data."availability-domain"' --raw-output)"
VNIC_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$REF_ID" --query 'data[0].id' --raw-output)"
SUBNET_ID="$(oci network vnic get --region "$REGION" --vnic-id "$VNIC_ID" --query 'data."subnet-id"' --raw-output)"
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name 'NAMS-Lightpanda-NSG' --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$SUBNET_ID" && valid_ocid "$VCN_ID" || { echo "Could not derive subnet/VCN." >&2; exit 1; }

echo "[2/12] Ensuring dedicated NSG rules..."
if ! valid_ocid "$NSG_ID"; then NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name 'NAMS-Lightpanda-NSG' --query 'data.id' --raw-output)"; fi
oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all > "$WORK/nsg.json"
python3 - "$WORK/nsg.json" "$WORK/missing-rules.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])).get('data',[])
def has_port(port):
    for r in rows:
        if r.get('direction')!='INGRESS' or str(r.get('protocol'))!='6': continue
        p=((r.get('tcp-options') or {}).get('destination-port-range') or {})
        lo,hi=p.get('min'),p.get('max')
        if lo is not None and hi is not None and lo<=port<=hi: return True
    return False
rules=[]
for port in (22,80,443):
    if not has_port(port): rules.append({'direction':'INGRESS','protocol':'6','source':'0.0.0.0/0','sourceType':'CIDR_BLOCK','isStateless':False,'tcpOptions':{'destinationPortRange':{'min':port,'max':port}}})
if not any(r.get('direction')=='EGRESS' and str(r.get('protocol'))=='all' for r in rows): rules.append({'direction':'EGRESS','protocol':'all','destination':'0.0.0.0/0','destinationType':'CIDR_BLOCK','isStateless':False})
json.dump(rules,open(sys.argv[2],'w'))
PY
if [ "$(cat "$WORK/missing-rules.json")" != "[]" ]; then oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/missing-rules.json" >/dev/null; fi

echo "[3/12] Selecting Ubuntu 24.04 ARM image..."
IMAGE_ID="$(oci compute image list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --shape "$SHAPE" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --sort-by TIMECREATED --sort-order DESC --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$IMAGE_ID" || { echo "No compatible Ubuntu image was returned." >&2; exit 1; }

echo "[4/12] Preparing key and cloud-init..."
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"; [ -f "$KEY" ] || KEY="$HOME/nams-dedicated.key"
if [ ! -f "$KEY" ]; then KEY="$HOME/nams-dedicated.key"; ssh-keygen -t ed25519 -N '' -f "$KEY" -C nams-dedicated >/dev/null; fi
chmod 600 "$KEY"; ssh-keygen -y -f "$KEY" > "$WORK/public.key"
cat > "$WORK/cloud-init.yaml" <<CLOUDINIT
#cloud-config
package_update: false
runcmd:
  - [ bash, -lc, "for i in \\$(seq 1 120); do curl -fsS --connect-timeout 5 https://raw.githubusercontent.com/ >/dev/null 2>&1 && break; sleep 10; done; curl -fL --retry 10 --retry-delay 10 --connect-timeout 20 '$INSTALLER_URL' -o /tmp/nams-install-v5.sh; chmod +x /tmp/nams-install-v5.sh; ADMIN_TOKEN='$TOKEN' NAMS_DOMAIN='$DOMAIN' bash /tmp/nams-install-v5.sh" ]
final_message: "NAMS v5 cloud-init finished"
CLOUDINIT

if valid_ocid "$OLD_ID"; then
  echo "[5/12] Terminating the broken NAMS VM to release free-tier OCPUs..."
  oci compute instance terminate --region "$REGION" --instance-id "$OLD_ID" --preserve-boot-volume false --force --wait-for-state TERMINATED --max-wait-seconds 1200 >/dev/null
  sleep 30
else echo "[5/12] No active broken NAMS VM exists."; fi

echo "[6/12] Launching clean replacement..."
INSTANCE_ID="$(oci compute instance launch --region "$REGION" --availability-domain "$AD" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --hostname-label nams-lightpanda --shape "$SHAPE" --shape-config '{"ocpus":2,"memoryInGBs":8}' --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip false --nsg-ids "[\"$NSG_ID\"]" --ssh-authorized-keys-file "$WORK/public.key" --user-data-file "$WORK/cloud-init.yaml" --boot-volume-size-in-gbs 50 --wait-for-state RUNNING --max-wait-seconds 1500 --query 'data.id' --raw-output)"
valid_ocid "$INSTANCE_ID" || { echo "Launch failed, possibly temporary Ampere capacity shortage." >&2; exit 1; }

echo "[7/12] Waiting for primary private IP..."
PRIVATE_IP_ID=''
for _ in $(seq 1 60); do
  NEW_VNIC="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0].id' --raw-output 2>/dev/null || true)"
  if valid_ocid "$NEW_VNIC"; then PRIVATE_IP_ID="$(oci network private-ip list --region "$REGION" --vnic-id "$NEW_VNIC" --all --query 'data[?"is-primary"==`true`] | [0].id' --raw-output 2>/dev/null || true)"; fi
  valid_ocid "$PRIVATE_IP_ID" && break; sleep 10
done
valid_ocid "$PRIVATE_IP_ID" || { echo "Primary private IP not created." >&2; exit 1; }

echo "[8/12] Assigning a movable reserved public IP..."
PUBLIC_IP_ID="$(oci network public-ip list --region "$REGION" --scope REGION --compartment-id "$COMPARTMENT_ID" --lifetime RESERVED --all --query 'data[?"display-name"==`NAMS-v5-Reserved-IP`] | [0].id' --raw-output 2>/dev/null || true)"
if valid_ocid "$PUBLIC_IP_ID"; then
  oci network public-ip update --region "$REGION" --public-ip-id "$PUBLIC_IP_ID" --private-ip-id "$PRIVATE_IP_ID" --force --wait-for-state ASSIGNED --max-wait-seconds 600 >/dev/null
else
  PUBLIC_IP_ID="$(oci network public-ip create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --lifetime RESERVED --display-name "$RESERVED_IP_NAME" --private-ip-id "$PRIVATE_IP_ID" --wait-for-state ASSIGNED --max-wait-seconds 600 --query 'data.id' --raw-output)"
fi
PUBLIC_IP="$(oci network public-ip get --region "$REGION" --public-ip-id "$PUBLIC_IP_ID" --query 'data."ip-address"' --raw-output)"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Reserved public IP assignment failed." >&2; exit 1; }
echo "New reserved public IP: $PUBLIC_IP"

echo "[9/12] Waiting for cloud-init installation; no SSH or Oracle Agent is used..."
READY=0
for i in $(seq 1 160); do
  if curl -fsS --connect-timeout 8 "http://$PUBLIC_IP/health" >/tmp/nams-rebuild-health.json 2>/dev/null; then READY=1; break; fi
  if [ $((i % 4)) -eq 0 ]; then echo "Still installing: $((i*15/60)) minute(s) elapsed"; fi
  sleep 15
done
if [ "$READY" -ne 1 ]; then
  echo "[10/12] Not healthy after 40 minutes. Attempting serial-console capture..." >&2
  HISTORY_ID="$(oci compute console-history capture --region "$REGION" --instance-id "$INSTANCE_ID" --wait-for-state SUCCEEDED --max-wait-seconds 600 --query 'data.id' --raw-output 2>/dev/null || true)"
  if valid_ocid "$HISTORY_ID"; then oci compute console-history get-content --region "$REGION" --instance-console-history-id "$HISTORY_ID" --file "$HOME/nams-v5-console-history.txt" || true; tail -n 200 "$HOME/nams-v5-console-history.txt" || true; fi
  echo "Replacement remains at $PUBLIC_IP for diagnosis." >&2; exit 1
fi

echo "[10/12] Health verified: $(cat /tmp/nams-rebuild-health.json)"
echo "[11/12] Checking DNS..."
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
if [ "$DNS_IP" = "$PUBLIC_IP" ]; then echo "$DOMAIN already points to the replacement."; else echo "DNS CHANGE REQUIRED: change A record 'seo' to $PUBLIC_IP (current: ${DNS_IP:-not resolved})"; fi

echo "[12/12] Clean rebuild complete."
echo
echo "NAMS V5 CLEAN REBUILD WORKING"
echo "Immediate dashboard: http://$PUBLIC_IP/?token=$TOKEN"
echo "Token: $TOKEN"
echo "Reserved IP: $PUBLIC_IP"
echo "After DNS update: https://$DOMAIN/?token=$TOKEN"
echo "Live browser after DNS update: https://$DOMAIN/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify"
echo "SSH key: $KEY"
echo "WAHA was not modified."
