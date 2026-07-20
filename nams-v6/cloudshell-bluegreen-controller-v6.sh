#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
WAHA_NAME="NituTravelsWAHA-20260719T184923Z"
CURRENT_NAME="NAMS-Lightpanda-Agent"
CANARY_NAME="NAMS-v6-Canary"
NSG_NAME="NAMS-Lightpanda-NSG"
SHAPE="VM.Standard.A1.Flex"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
RESERVED_IP_ADDRESS="${NAMS_RESERVED_IP:-161.118.166.225}"
RELEASE_SHA="c74d8660d516e9330a9ad4f24742b10c43c487c4"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${RELEASE_SHA}/nams-v6/install-prebuilt-v6.sh"
APP_REPOSITORY="nitutravels/nams-v6-app"
CHROMIUM_REPOSITORY="nitutravels/nams-v6-chromium"
TOKEN="$(openssl rand -hex 24)"
WORK="$(mktemp -d)"
PHASE="preflight"
CURRENT_ID=""
CANARY_ID=""
OLD_BOOT_VOLUME_ID=""
PUBLIC_IP_ID=""
SUBNET_ID=""
AD=""
NSG_ID=""
KEY=""

trap 'rm -rf "$WORK"' EXIT
valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }
log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

poll_instance_state(){
  local id="$1" wanted="$2" limit="${3:-120}" state=''
  for _ in $(seq 1 "$limit"); do
    state="$(oci compute instance get --region "$REGION" --instance-id "$id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    [ "$state" = "$wanted" ] && return 0
    sleep 10
  done
  echo "Instance $id did not reach $wanted; last state: $state" >&2
  return 1
}

instance_vnic_id(){ oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0].id' --raw-output; }
instance_public_ip(){ oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0]."public-ip"' --raw-output; }
instance_private_ip_id(){
  local vnic
  vnic="$(instance_vnic_id "$1")"
  oci network private-ip list --region "$REGION" --vnic-id "$vnic" --query 'data[?"is-primary"==`true`] | [0].id' --raw-output
}

verify_ghcr_arm64(){
  local repository="$1" tag="$2" token manifest
  token="$(curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${repository}:pull" | jq -r '.token // empty')"
  [ -n "$token" ] || return 1
  manifest="$(curl -fsS \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/${repository}/manifests/${tag}")"
  jq -e '.manifests[]? | select(.platform.os=="linux" and .platform.architecture=="arm64")' <<<"$manifest" >/dev/null
}

probe(){
  local ip="$1" path="$2"
  curl -fsS --connect-timeout 6 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "http://${ip}${path}"
}

verify_full_stack(){
  local ip="$1" max_minutes="${2:-45}" attempts output
  attempts=$((max_minutes*2))
  for i in $(seq 1 "$attempts"); do
    if probe "$ip" '/_probe/app/health' >"$WORK/app-health.json" 2>/dev/null && \
       probe "$ip" '/_probe/chromium/json/version' >"$WORK/chromium.json" 2>/dev/null && \
       probe "$ip" '/_probe/novnc/vnc.html' >"$WORK/novnc.html" 2>/dev/null && \
       probe "$ip" '/_probe/lightpanda/json/version' >"$WORK/lightpanda.json" 2>/dev/null && \
       probe "$ip" '/_probe/ollama/api/tags' >"$WORK/ollama.json" 2>/dev/null && \
       grep -q '"ok"' "$WORK/app-health.json" && \
       grep -q 'webSocketDebuggerUrl' "$WORK/chromium.json" && \
       grep -qi 'noVNC' "$WORK/novnc.html" && \
       jq -e '.models[]? | select(.name=="gemma3:1b" or .model=="gemma3:1b" or (.name|startswith("gemma3:1b:")))' "$WORK/ollama.json" >/dev/null; then
      return 0
    fi
    if [ $((i % 4)) -eq 0 ]; then log "Readiness check: $((i/2)) minute(s) elapsed"; fi
    sleep 30
  done
  return 1
}

restore_current_shape(){
  [ -n "$CURRENT_ID" ] && valid_ocid "$CURRENT_ID" || return 0
  local state
  state="$(oci compute instance get --region "$REGION" --instance-id "$CURRENT_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
  [ "$state" = "TERMINATED" ] && return 0
  if [ "$state" != "STOPPED" ]; then
    oci compute instance action --region "$REGION" --instance-id "$CURRENT_ID" --action STOP --force >/dev/null 2>&1 || true
    poll_instance_state "$CURRENT_ID" STOPPED 90 || true
  fi
  oci compute instance update --region "$REGION" --instance-id "$CURRENT_ID" --shape "$SHAPE" --shape-config '{"ocpus":2,"memoryInGBs":8}' --force >/dev/null 2>&1 || true
  oci compute instance action --region "$REGION" --instance-id "$CURRENT_ID" --action START >/dev/null 2>&1 || true
  poll_instance_state "$CURRENT_ID" RUNNING 120 || true
}

rollback_before_cutover(){
  log "Canary failed before cutover. Removing only the canary and restoring the original VM size."
  if [ -n "$CANARY_ID" ] && valid_ocid "$CANARY_ID"; then
    oci compute instance terminate --region "$REGION" --instance-id "$CANARY_ID" --preserve-boot-volume false --force >/dev/null 2>&1 || true
  fi
  restore_current_shape
}

rollback_from_boot_volume(){
  log "Final cutover failed. Recreating the prior VM automatically from its preserved boot volume."
  if [ -n "$CANARY_ID" ] && valid_ocid "$CANARY_ID"; then
    oci compute instance terminate --region "$REGION" --instance-id "$CANARY_ID" --preserve-boot-volume false --force >/dev/null 2>&1 || true
    poll_instance_state "$CANARY_ID" TERMINATED 180 || true
  fi
  if ! valid_ocid "$OLD_BOOT_VOLUME_ID"; then
    echo "Rollback boot volume was not available." >&2
    return 1
  fi
  local rollback_id rollback_private
  rollback_id="$(oci compute instance launch \
    --region "$REGION" --availability-domain "$AD" --compartment-id "$COMPARTMENT_ID" \
    --display-name "$CURRENT_NAME" --shape "$SHAPE" --shape-config '{"ocpus":2,"memoryInGBs":8}' \
    --source-boot-volume-id "$OLD_BOOT_VOLUME_ID" --subnet-id "$SUBNET_ID" --assign-public-ip false \
    --nsg-ids "[\"$NSG_ID\"]" --ssh-authorized-keys-file "$WORK/public.key" \
    --query 'data.id' --raw-output)"
  poll_instance_state "$rollback_id" RUNNING 180
  rollback_private="$(instance_private_ip_id "$rollback_id")"
  if valid_ocid "$PUBLIC_IP_ID" && valid_ocid "$rollback_private"; then
    oci network public-ip update --region "$REGION" --public-ip-id "$PUBLIC_IP_ID" --private-ip-id "$rollback_private" --force >/dev/null
  fi
  echo "The previous VM was restored from its preserved boot volume." >&2
}

on_error(){
  local rc=$?
  echo >&2
  echo "Controller failed in phase: $PHASE (exit $rc)" >&2
  case "$PHASE" in
    preflight) ;;
    canary|canary_verify) rollback_before_cutover || true ;;
    cutover|final_verify) rollback_from_boot_volume || true ;;
  esac
  echo "No WAHA resource was modified." >&2
  exit "$rc"
}
trap on_error ERR

log "NAMS v6 deterministic blue-green controller"
log "No VM build occurs; only certified container images are pulled."

log "1/14 Preflight: verifying immutable release files..."
for path in nams-v6/install-prebuilt-v6.sh nams-v6/docker-compose.yml nams-v6/Caddyfile nams-v5/config/catalog.json; do
  curl -fsS --connect-timeout 15 "https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${RELEASE_SHA}/${path}" >/dev/null
 done

log "2/14 Preflight: verifying published ARM64 images before touching OCI..."
verify_ghcr_arm64 "$APP_REPOSITORY" "$RELEASE_SHA"
verify_ghcr_arm64 "$CHROMIUM_REPOSITORY" "$RELEASE_SHA"

log "3/14 Resolving compartment, WAHA placement and current NAMS VM..."
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output)"
valid_ocid "$COMPARTMENT_ID"
WAHA_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$WAHA_NAME" --all --query 'data[?"lifecycle-state"==`RUNNING`] | [0].id' --raw-output)"
valid_ocid "$WAHA_ID"
AD="$(oci compute instance get --region "$REGION" --instance-id "$WAHA_ID" --query 'data."availability-domain"' --raw-output)"
SUBNET_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$WAHA_ID" --query 'data[0]."subnet-id"' --raw-output)"
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
CURRENT_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$CURRENT_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$CURRENT_ID"

log "4/14 Preparing SSH key and dedicated NSG..."
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
[ -f "$KEY" ] || KEY="$HOME/nams-dedicated.key"
if [ ! -f "$KEY" ]; then
  KEY="$HOME/nams-v6.key"
  ssh-keygen -t ed25519 -N '' -f "$KEY" -C nams-v6 >/dev/null
fi
chmod 600 "$KEY"
ssh-keygen -y -f "$KEY" >"$WORK/public.key"
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$NSG_ID"; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --query 'data.id' --raw-output)"
  cat >"$WORK/rules.json" <<'JSON'
[
 {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
 {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
 {"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
 {"direction":"EGRESS","protocol":"all","destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK"}
]
JSON
  oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/rules.json" >/dev/null
fi

log "5/14 Resolving reserved public IP and rollback boot volume..."
CURRENT_PRIVATE_ID="$(instance_private_ip_id "$CURRENT_ID")"
PUBLIC_JSON="$(oci network public-ip list --region "$REGION" --scope REGION --compartment-id "$COMPARTMENT_ID" --lifetime RESERVED --all)"
PUBLIC_IP_ID="$(jq -r --arg ip "$RESERVED_IP_ADDRESS" '.data[] | select(."ip-address"==$ip) | .id' <<<"$PUBLIC_JSON" | head -1)"
if ! valid_ocid "$PUBLIC_IP_ID"; then
  PUBLIC_IP_ID="$(jq -r --arg private "$CURRENT_PRIVATE_ID" '.data[] | select(."assigned-entity-id"==$private) | .id' <<<"$PUBLIC_JSON" | head -1)"
fi
valid_ocid "$PUBLIC_IP_ID"
OLD_BOOT_VOLUME_ID="$(oci compute boot-volume-attachment list --region "$REGION" --availability-domain "$AD" --compartment-id "$COMPARTMENT_ID" --instance-id "$CURRENT_ID" --query 'data[0]."boot-volume-id"' --raw-output)"
valid_ocid "$OLD_BOOT_VOLUME_ID"

log "6/14 Selecting latest Ubuntu 24.04 ARM image..."
IMAGE_ID="$(oci compute image list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --shape "$SHAPE" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --sort-by TIMECREATED --sort-order DESC --all --query 'data[0].id' --raw-output)"
valid_ocid "$IMAGE_ID"

PHASE=canary
log "7/14 Shrinking the original NAMS VM to 1 OCPU/6 GB temporarily, preserving it for rollback..."
oci compute instance action --region "$REGION" --instance-id "$CURRENT_ID" --action STOP --force >/dev/null
poll_instance_state "$CURRENT_ID" STOPPED 120
oci compute instance update --region "$REGION" --instance-id "$CURRENT_ID" --shape "$SHAPE" --shape-config '{"ocpus":1,"memoryInGBs":6}' --force >/dev/null
oci compute instance action --region "$REGION" --instance-id "$CURRENT_ID" --action START >/dev/null
poll_instance_state "$CURRENT_ID" RUNNING 120

log "8/14 Removing any abandoned canary from an earlier attempt..."
OLD_CANARY_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$CANARY_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
if valid_ocid "$OLD_CANARY_ID"; then
  oci compute instance terminate --region "$REGION" --instance-id "$OLD_CANARY_ID" --preserve-boot-volume false --force >/dev/null
  poll_instance_state "$OLD_CANARY_ID" TERMINATED 180
fi

log "9/14 Preparing deterministic cloud-init with immutable image tags..."
cat >"$WORK/cloud-init.yaml" <<CLOUDINIT
#cloud-config
package_update: false
write_files:
  - path: /usr/local/sbin/nams-v6-bootstrap
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      curl -fL --retry 8 --connect-timeout 20 '$INSTALLER_URL' -o /tmp/nams-v6-install.sh
      chmod +x /tmp/nams-v6-install.sh
      env ADMIN_TOKEN='$TOKEN' NAMS_DOMAIN='$DOMAIN' NAMS_RELEASE_REF='$RELEASE_SHA' NAMS_APP_IMAGE_TAG='$RELEASE_SHA' NAMS_CHROMIUM_IMAGE_TAG='$RELEASE_SHA' bash /tmp/nams-v6-install.sh
runcmd:
  - [ bash, -lc, '/usr/local/sbin/nams-v6-bootstrap' ]
final_message: 'NAMS v6 cloud-init complete'
CLOUDINIT

log "10/14 Launching a 1 OCPU/6 GB canary while the original VM remains available..."
CANARY_ID="$(oci compute instance launch \
  --region "$REGION" --availability-domain "$AD" --compartment-id "$COMPARTMENT_ID" \
  --display-name "$CANARY_NAME" --hostname-label nams-v6-canary --shape "$SHAPE" \
  --shape-config '{"ocpus":1,"memoryInGBs":6}' --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" \
  --assign-public-ip true --nsg-ids "[\"$NSG_ID\"]" --ssh-authorized-keys-file "$WORK/public.key" \
  --user-data-file "$WORK/cloud-init.yaml" --query 'data.id' --raw-output)"
valid_ocid "$CANARY_ID"
poll_instance_state "$CANARY_ID" RUNNING 180
CANARY_IP=''
for _ in $(seq 1 60); do
  CANARY_IP="$(instance_public_ip "$CANARY_ID" 2>/dev/null || true)"
  [[ "$CANARY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  sleep 5
done
[[ "$CANARY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]

PHASE=canary_verify
log "11/14 Certifying app, Chromium, noVNC, Lightpanda, Ollama and the model on canary IP $CANARY_IP..."
verify_full_stack "$CANARY_IP" 45

PHASE=cutover
log "12/14 Canary passed. Preserving old boot volume, terminating old compute and resizing canary to 2 OCPU/8 GB..."
oci compute instance terminate --region "$REGION" --instance-id "$CURRENT_ID" --preserve-boot-volume true --force >/dev/null
poll_instance_state "$CURRENT_ID" TERMINATED 180
oci compute instance action --region "$REGION" --instance-id "$CANARY_ID" --action STOP --force >/dev/null
poll_instance_state "$CANARY_ID" STOPPED 120
oci compute instance update --region "$REGION" --instance-id "$CANARY_ID" --shape "$SHAPE" --shape-config '{"ocpus":2,"memoryInGBs":8}' --display-name "$CURRENT_NAME" --force >/dev/null
oci compute instance action --region "$REGION" --instance-id "$CANARY_ID" --action START >/dev/null
poll_instance_state "$CANARY_ID" RUNNING 120

PHASE=final_verify
log "13/14 Re-certifying after final resize, then moving the reserved IP..."
CANARY_IP="$(instance_public_ip "$CANARY_ID")"
verify_full_stack "$CANARY_IP" 15
NEW_PRIVATE_ID="$(instance_private_ip_id "$CANARY_ID")"
valid_ocid "$NEW_PRIVATE_ID"
# The canary currently has an ephemeral public IP. Removing it is required before moving a reserved IP.
EPHEMERAL_ID="$(oci network public-ip get --region "$REGION" --private-ip-id "$NEW_PRIVATE_ID" --query 'data.id' --raw-output 2>/dev/null || true)"
if valid_ocid "$EPHEMERAL_ID" && [ "$EPHEMERAL_ID" != "$PUBLIC_IP_ID" ]; then
  oci network public-ip delete --region "$REGION" --public-ip-id "$EPHEMERAL_ID" --force >/dev/null 2>&1 || true
  sleep 10
fi
oci network public-ip update --region "$REGION" --public-ip-id "$PUBLIC_IP_ID" --private-ip-id "$NEW_PRIVATE_ID" --force >/dev/null
for _ in $(seq 1 60); do
  ASSIGNED="$(oci network public-ip get --region "$REGION" --public-ip-id "$PUBLIC_IP_ID" --query 'data."assigned-entity-id"' --raw-output 2>/dev/null || true)"
  [ "$ASSIGNED" = "$NEW_PRIVATE_ID" ] && break
  sleep 5
done
[ "$ASSIGNED" = "$NEW_PRIVATE_ID" ]
verify_full_stack "$RESERVED_IP_ADDRESS" 10

PHASE=complete
log "14/14 Deployment certified and cutover completed."
echo
echo "NAMS V6 VERIFIED"
echo "Reserved IP: $RESERVED_IP_ADDRESS"
echo "Dashboard: http://$RESERVED_IP_ADDRESS/?token=$TOKEN"
echo "Token: $TOKEN"
echo "Domain after its A record points to $RESERVED_IP_ADDRESS: https://$DOMAIN/?token=$TOKEN"
echo "Rollback boot volume retained: $OLD_BOOT_VOLUME_ID"
echo "WAHA instance was not modified."
