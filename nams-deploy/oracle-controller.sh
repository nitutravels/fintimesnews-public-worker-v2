#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
TENANCY_OCID="${OCI_TENANCY_OCID:?OCI_TENANCY_OCID is required}"
COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-}"
COMPARTMENT_NAME="${OCI_COMPARTMENT_NAME:-NituWAGateway}"
REFERENCE_INSTANCE="${OCI_REFERENCE_INSTANCE:-NituTravelsWAHA-20260719T184923Z}"
TARGET_NAME="${OCI_TARGET_INSTANCE:-NAMS-Lightpanda-Agent}"
NSG_NAME="${OCI_NSG_NAME:-NAMS-Lightpanda-NSG}"
RESERVED_IP_HINT="${OCI_RESERVED_IP:-161.118.166.225}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
SOURCE_REF="${NAMS_SOURCE_REF:?NAMS_SOURCE_REF is required}"
IMAGE_TAG="${NAMS_IMAGE_TAG:?NAMS_IMAGE_TAG is required}"
DEPLOY_REF="${NAMS_DEPLOY_REF:?NAMS_DEPLOY_REF is required}"
GHCR_USER="${GHCR_USER:-nitutravels}"
GHCR_TOKEN="${GHCR_TOKEN:?GHCR_TOKEN is required}"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=8
WORK="${RUNNER_TEMP:-/tmp}/nams-oracle-${GITHUB_RUN_ID:-manual}"
DIAG="$WORK/diagnostics"
RESULT="${NAMS_RESULT_FILE:-nams-deployment-result.json}"
TOKEN="$(openssl rand -hex 24)"
PHASE=preflight
OLD_TERMINATED=0
OLD_BOOT_VOLUME_ID=''
OLD_AD=''
NEW_ID=''
NEW_IP=''
RESERVED_IP_ID=''
RESERVED_IP_ADDRESS=''
CUTOVER_DONE=0
mkdir -p "$DIAG"

log(){ printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }
json_result(){
  jq -n \
    --arg status "$1" --arg phase "$PHASE" --arg instance_id "${NEW_ID:-}" \
    --arg public_ip "${RESERVED_IP_ADDRESS:-${NEW_IP:-}}" --arg domain "$DOMAIN" \
    --arg token "${TOKEN:-}" --arg image_tag "$IMAGE_TAG" --arg source_ref "$SOURCE_REF" \
    --arg old_boot_volume_id "${OLD_BOOT_VOLUME_ID:-}" --arg message "${2:-}" \
    '{status:$status,phase:$phase,instance_id:$instance_id,public_ip:$public_ip,domain:$domain,token:$token,image_tag:$image_tag,source_ref:$source_ref,old_boot_volume_id:$old_boot_volume_id,message:$message}' >"$RESULT"
}
instance_state(){ oci compute instance get --region "$REGION" --instance-id "$1" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true; }
poll_state(){
  local id="$1" target="$2" loops="${3:-180}" state=''
  for _ in $(seq 1 "$loops"); do
    state="$(instance_state "$id")"
    [ "$state" = "$target" ] && return 0
    sleep 10
  done
  log "Timed out waiting for $id to reach $target; current state=$state"
  return 1
}
instance_vnic_id(){ oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0].id' --raw-output; }
instance_public_ip(){ oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0]."public-ip"' --raw-output; }
instance_private_ip_id(){
  local vnic
  vnic="$(instance_vnic_id "$1")"
  oci network private-ip list --region "$REGION" --vnic-id "$vnic" --all --query 'data[0].id' --raw-output
}
capture_console(){
  local id="$1" label="$2" history state
  valid_ocid "$id" || return 0
  history="$(oci compute console-history capture --region "$REGION" --instance-id "$id" --query 'data.id' --raw-output 2>/dev/null || true)"
  valid_ocid "$history" || return 0
  for _ in $(seq 1 60); do
    state="$(oci compute console-history get --region "$REGION" --instance-console-history-id "$history" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    [ "$state" = SUCCEEDED ] && break
    [ "$state" = FAILED ] && return 0
    sleep 5
  done
  oci compute console-history get-content --region "$REGION" --instance-console-history-id "$history" --file "$DIAG/${label}-console.txt" >/dev/null 2>&1 || true
}
ensure_rule(){
  local port="$1" rules
  rules="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
  if ! jq -e --argjson p "$port" '.data[]? | select(.direction=="INGRESS" and .protocol=="6" and .source=="0.0.0.0/0") | .["tcp-options"]["destination-port-range"] | select(.min <= $p and .max >= $p)' <<<"$rules" >/dev/null; then
    cat >"$WORK/rule-${port}.json" <<JSON
[{"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":$port,"max":$port}}}]
JSON
    oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/rule-${port}.json" >/dev/null
  fi
}
rollback_old(){
  [ "$OLD_TERMINATED" -eq 1 ] || return 0
  valid_ocid "$OLD_BOOT_VOLUME_ID" || return 0
  log 'Attempting rollback from preserved boot volume after classified deployment failure'
  local rollback_id rollback_ip rollback_private ephemeral
  rollback_id="$(oci compute instance launch --region "$REGION" \
    --availability-domain "$OLD_AD" --compartment-id "$COMPARTMENT_OCID" \
    --display-name "${TARGET_NAME}-rollback" --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --source-boot-volume-id "$OLD_BOOT_VOLUME_ID" --subnet-id "$SUBNET_ID" \
    --assign-public-ip true --nsg-ids "[\"$NSG_ID\"]" --query 'data.id' --raw-output 2>/dev/null || true)"
  valid_ocid "$rollback_id" || { log 'Rollback launch could not be completed'; return 0; }
  poll_state "$rollback_id" RUNNING 180 || return 0
  rollback_ip="$(instance_public_ip "$rollback_id" 2>/dev/null || true)"
  if valid_ocid "$RESERVED_IP_ID"; then
    rollback_private="$(instance_private_ip_id "$rollback_id" 2>/dev/null || true)"
    if valid_ocid "$rollback_private"; then
      ephemeral="$(oci network public-ip get --region "$REGION" --private-ip-id "$rollback_private" --query 'data.id' --raw-output 2>/dev/null || true)"
      if valid_ocid "$ephemeral" && [ "$ephemeral" != "$RESERVED_IP_ID" ]; then oci network public-ip delete --region "$REGION" --public-ip-id "$ephemeral" --force >/dev/null 2>&1 || true; sleep 8; fi
      oci network public-ip update --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --private-ip-id "$rollback_private" --force >/dev/null 2>&1 || true
      log "Rollback compute restored; reserved IP reassignment requested: $RESERVED_IP_ADDRESS"
    fi
  else
    log "Rollback compute restored on ephemeral IP: $rollback_ip"
  fi
}
on_error(){
  local rc=$?
  set +e
  log "Deployment failed in phase $PHASE with exit code $rc"
  capture_console "$NEW_ID" candidate
  oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --all --output json >"$DIAG/instances.json" 2>/dev/null || true
  oci network public-ip list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --scope REGION --all --output json >"$DIAG/public-ips.json" 2>/dev/null || true
  if valid_ocid "$NEW_ID" && [ "$CUTOVER_DONE" -eq 0 ]; then
    oci compute instance terminate --region "$REGION" --instance-id "$NEW_ID" --preserve-boot-volume true --force >/dev/null 2>&1 || true
  fi
  rollback_old
  json_result failed "Deployment failed in phase $PHASE; diagnostics were captured without retrying the same failure"
  tar -czf nams-deployment-diagnostics.tgz -C "$WORK" diagnostics 2>/dev/null || true
  exit "$rc"
}
trap on_error ERR

PHASE=preflight
log 'Validating OCI credentials and repository release inputs'
oci iam region-subscription list --region "$REGION" --tenancy-id "$TENANCY_OCID" --all >/dev/null
for image in "ghcr.io/nitutravels/nams-v6-app:$IMAGE_TAG" "ghcr.io/nitutravels/nams-v6-chromium:$IMAGE_TAG"; do
  docker buildx imagetools inspect "$image" >"$DIAG/$(basename "$image" | tr ':' '-').manifest.txt"
  grep -q 'linux/arm64' "$DIAG/$(basename "$image" | tr ':' '-').manifest.txt"
done

PHASE=placement
log 'Resolving compartment and network placement from the WAHA instance'
if ! valid_ocid "$COMPARTMENT_OCID"; then
  COMPARTMENT_OCID="$(oci iam compartment list --region "$REGION" --compartment-id "$TENANCY_OCID" --compartment-id-in-subtree true --access-level ACCESSIBLE --all --output json | jq -r --arg n "$COMPARTMENT_NAME" '[.data[]|select(.name==$n and .["lifecycle-state"]=="ACTIVE")|.id][0]//empty')"
fi
valid_ocid "$COMPARTMENT_OCID"
REFERENCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --display-name "$REFERENCE_INSTANCE" --all --output json | jq -r '[.data[]|select(.["lifecycle-state"]=="RUNNING")|.id][0]//empty')"
valid_ocid "$REFERENCE_ID"
AD="$(oci compute instance get --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data."availability-domain"' --raw-output)"
SUBNET_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data[0]."subnet-id"' --raw-output)"
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
valid_ocid "$SUBNET_ID"; valid_ocid "$VCN_ID"

PHASE=network_security
log 'Creating or validating the dedicated NAMS network security group'
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$NSG_ID"; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --query 'data.id' --raw-output)"
fi
ensure_rule 22; ensure_rule 80; ensure_rule 443
RULES="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
if ! jq -e '.data[]? | select(.direction=="EGRESS" and .protocol=="all" and .destination=="0.0.0.0/0")' <<<"$RULES" >/dev/null; then
  cat >"$WORK/egress.json" <<'JSON'
[{"direction":"EGRESS","protocol":"all","destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","isStateless":false}]
JSON
  oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/egress.json" >/dev/null
fi

PHASE=image_selection
log 'Selecting the latest compatible Ubuntu 24.04 ARM image'
IMAGE_ID="$(oci compute image list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --shape "$SHAPE" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --sort-by TIMECREATED --sort-order DESC --all --query 'data[0].id' --raw-output)"
valid_ocid "$IMAGE_ID"

PHASE=inventory
log 'Capturing the current NAMS instance, boot volume and reserved IP'
mapfile -t OLD_IDS < <(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --display-name "$TARGET_NAME" --all --output json | jq -r '.data[]|select(.["lifecycle-state"]!="TERMINATED")|.id')
if [ ${#OLD_IDS[@]} -gt 0 ]; then
  OLD_ID="${OLD_IDS[0]}"
  OLD_AD="$(oci compute instance get --region "$REGION" --instance-id "$OLD_ID" --query 'data."availability-domain"' --raw-output)"
  OLD_BOOT_VOLUME_ID="$(oci compute boot-volume-attachment list --region "$REGION" --availability-domain "$OLD_AD" --compartment-id "$COMPARTMENT_OCID" --instance-id "$OLD_ID" --all --query 'data[0]."boot-volume-id"' --raw-output 2>/dev/null || true)"
  OLD_PRIVATE_ID="$(instance_private_ip_id "$OLD_ID" 2>/dev/null || true)"
  if valid_ocid "$OLD_PRIVATE_ID"; then
    CURRENT_PUBLIC_JSON="$(oci network public-ip get --region "$REGION" --private-ip-id "$OLD_PRIVATE_ID" --output json 2>/dev/null || true)"
    if [ -n "$CURRENT_PUBLIC_JSON" ] && [ "$(jq -r '.data.lifetime//empty' <<<"$CURRENT_PUBLIC_JSON")" = RESERVED ]; then
      RESERVED_IP_ID="$(jq -r '.data.id' <<<"$CURRENT_PUBLIC_JSON")"
      RESERVED_IP_ADDRESS="$(jq -r '.data["ip-address"]' <<<"$CURRENT_PUBLIC_JSON")"
    fi
  fi
fi
if ! valid_ocid "$RESERVED_IP_ID"; then
  RESERVED_JSON="$(oci network public-ip list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --scope REGION --lifetime RESERVED --all --output json | jq -c --arg ip "$RESERVED_IP_HINT" '[.data[]|select(.["ip-address"]==$ip or .["display-name"]=="NAMS-Reserved-IP")][0]//empty')"
  if [ -n "$RESERVED_JSON" ]; then
    RESERVED_IP_ID="$(jq -r '.id' <<<"$RESERVED_JSON")"
    RESERVED_IP_ADDRESS="$(jq -r '.["ip-address"]' <<<"$RESERVED_JSON")"
  fi
fi

PHASE=cloud_init
log 'Generating deterministic cloud-init with short-lived GHCR credentials'
GHCR_TOKEN_B64="$(printf '%s' "$GHCR_TOKEN" | base64 -w0)"
BOOTSTRAP=$(cat <<BOOT
#!/usr/bin/env bash
set -Eeuo pipefail
curl -fL --retry 8 --connect-timeout 20 'https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${DEPLOY_REF}/nams-deploy/install-certified.sh' -o /root/install-certified.sh
chmod 700 /root/install-certified.sh
env ADMIN_TOKEN='${TOKEN}' NAMS_DOMAIN='${DOMAIN}' NAMS_SOURCE_REF='${SOURCE_REF}' NAMS_IMAGE_TAG='${IMAGE_TAG}' GHCR_USER='${GHCR_USER}' GHCR_TOKEN_B64='${GHCR_TOKEN_B64}' bash /root/install-certified.sh
BOOT
)
BOOTSTRAP_B64="$(printf '%s' "$BOOTSTRAP" | base64 -w0)"
cat >"$WORK/cloud-init.yaml" <<CLOUD
#cloud-config
package_update: false
write_files:
  - path: /root/nams-bootstrap.sh
    permissions: '0700'
    encoding: b64
    content: ${BOOTSTRAP_B64}
runcmd:
  - [ bash, -lc, '/root/nams-bootstrap.sh' ]
final_message: 'NAMS certified installation finished'
CLOUD

PHASE=retire_old_compute
if [ ${#OLD_IDS[@]} -gt 0 ]; then
  log 'Preserving the old boot volume and retiring only the broken NAMS compute instance'
  for old in "${OLD_IDS[@]}"; do
    oci compute instance terminate --region "$REGION" --instance-id "$old" --preserve-boot-volume true --force >/dev/null
  done
  for old in "${OLD_IDS[@]}"; do poll_state "$old" TERMINATED 270; done
  OLD_TERMINATED=1
else
  log 'No active old NAMS compute instance exists; nothing destructive is required'
fi

PHASE=launch
log 'Launching the certified replacement at the final 2 OCPU / 8 GB shape'
NEW_ID="$(oci compute instance launch --region "$REGION" --availability-domain "$AD" --compartment-id "$COMPARTMENT_OCID" --display-name "$TARGET_NAME" --hostname-label nams-agent --shape "$SHAPE" --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip true --nsg-ids "[\"$NSG_ID\"]" --user-data-file "$WORK/cloud-init.yaml" --query 'data.id' --raw-output)"
valid_ocid "$NEW_ID"
poll_state "$NEW_ID" RUNNING 180
for _ in $(seq 1 60); do NEW_IP="$(instance_public_ip "$NEW_ID" 2>/dev/null || true)"; [[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break; sleep 5; done
[[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
log "Replacement running on temporary IP $NEW_IP"

PHASE=certify_candidate
log 'Waiting for cloud-init and certifying the complete stack'
CERTIFIED=0
for i in $(seq 1 360); do
  if curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "http://$NEW_IP/_probe/app/health" >"$DIAG/app-health.json" 2>/dev/null && \
     curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "http://$NEW_IP/_probe/chromium/json/version" >"$DIAG/chromium.json" 2>/dev/null && \
     curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "http://$NEW_IP/_probe/novnc/vnc.html" >"$DIAG/novnc.html" 2>/dev/null && \
     curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "http://$NEW_IP/_probe/lightpanda/json/version" >"$DIAG/lightpanda.json" 2>/dev/null && \
     curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "http://$NEW_IP/_probe/ollama/api/tags" >"$DIAG/ollama.json" 2>/dev/null && \
     curl -fsS --connect-timeout 5 --max-time 20 -H "Authorization: Bearer $TOKEN" "http://$NEW_IP/" >"$DIAG/dashboard.html" 2>/dev/null; then
    if grep -q '"ok"' "$DIAG/app-health.json" && grep -q webSocketDebuggerUrl "$DIAG/chromium.json" && grep -qi noVNC "$DIAG/novnc.html" && grep -q NAMS "$DIAG/dashboard.html" && jq -e '.models|length>0' "$DIAG/ollama.json" >/dev/null; then CERTIFIED=1; break; fi
  fi
  if [ $((i % 12)) -eq 0 ]; then log "Candidate certification: $((i/6)) minute(s) elapsed"; fi
  sleep 10
done
[ "$CERTIFIED" -eq 1 ] || { log 'Candidate failed certification'; exit 40; }

PHASE=cutover
log 'Candidate passed. Moving or creating the reserved public IP'
NEW_PRIVATE_ID="$(instance_private_ip_id "$NEW_ID")"
valid_ocid "$NEW_PRIVATE_ID"
EPHEMERAL_ID="$(oci network public-ip get --region "$REGION" --private-ip-id "$NEW_PRIVATE_ID" --query 'data.id' --raw-output 2>/dev/null || true)"
if valid_ocid "$EPHEMERAL_ID" && [ "$EPHEMERAL_ID" != "$RESERVED_IP_ID" ]; then
  oci network public-ip delete --region "$REGION" --public-ip-id "$EPHEMERAL_ID" --force >/dev/null
  sleep 10
fi
if valid_ocid "$RESERVED_IP_ID"; then
  oci network public-ip update --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --private-ip-id "$NEW_PRIVATE_ID" --force >/dev/null
else
  RESERVED_IP_ID="$(oci network public-ip create --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --lifetime RESERVED --display-name NAMS-Reserved-IP --private-ip-id "$NEW_PRIVATE_ID" --query 'data.id' --raw-output)"
fi
RESERVED_IP_ADDRESS="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --query 'data."ip-address"' --raw-output)"
for _ in $(seq 1 60); do ASSIGNED="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --query 'data."assigned-entity-id"' --raw-output 2>/dev/null || true)"; [ "$ASSIGNED" = "$NEW_PRIVATE_ID" ] && break; sleep 5; done
[ "$ASSIGNED" = "$NEW_PRIVATE_ID" ]

PHASE=final_verify
log "Performing final verification through reserved IP $RESERVED_IP_ADDRESS"
for _ in $(seq 1 60); do
  if curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "http://$RESERVED_IP_ADDRESS/_probe/app/health" >/dev/null 2>&1 && curl -fsS --connect-timeout 5 --max-time 20 -H "Authorization: Bearer $TOKEN" "http://$RESERVED_IP_ADDRESS/" | grep -q NAMS; then CUTOVER_DONE=1; break; fi
  sleep 5
done
[ "$CUTOVER_DONE" -eq 1 ]

PHASE=complete
json_result success 'Certified images deployed, complete stack verified, reserved IP cutover completed'
tar -czf nams-deployment-diagnostics.tgz -C "$WORK" diagnostics
log 'NAMS INSTALLATION COMPLETED AND VERIFIED'
echo "Dashboard: http://$RESERVED_IP_ADDRESS/?token=$TOKEN"
echo "Domain: https://$DOMAIN/?token=$TOKEN"
echo "Token: $TOKEN"
echo "Reserved IP: $RESERVED_IP_ADDRESS"
echo "Rollback boot volume: ${OLD_BOOT_VOLUME_ID:-none}"
