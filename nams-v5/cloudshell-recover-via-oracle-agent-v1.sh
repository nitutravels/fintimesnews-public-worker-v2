#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
INSTANCE_NAME="NAMS-Lightpanda-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
REMOTE_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/18a8cc90811d45eefe72564bb008f83459b5eab1/nams-v5/remote-resume-v5.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }

echo "NAMS v5 Oracle Agent recovery"
echo "This bypasses the stuck SSH step."

echo "[1/9] Resolving the dedicated instance..."
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$COMPARTMENT_ID" || { echo "Compartment $COMPARTMENT_NAME was not found." >&2; exit 1; }
INSTANCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$INSTANCE_ID" || { echo "Instance $INSTANCE_NAME was not found." >&2; exit 1; }
STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
if [ "$STATE" = "STOPPED" ]; then
  oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
elif [ "$STATE" != "RUNNING" ]; then
  oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --wait-for-state RUNNING --max-wait-seconds 900 >/dev/null
fi
PUBLIC_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
echo "Instance: $INSTANCE_NAME | Public IP: $PUBLIC_IP"

echo "[2/9] Enabling Oracle Compute Instance Run Command..."
AGENT_CONFIG='{"areAllPluginsDisabled":false,"isManagementDisabled":false,"isMonitoringDisabled":false,"pluginsConfig":[{"name":"Compute Instance Run Command","desiredState":"ENABLED"}]}'
oci compute instance update --region "$REGION" --instance-id "$INSTANCE_ID" --agent-config "$AGENT_CONFIG" --force >/dev/null

PLUGIN='UNKNOWN'
for i in $(seq 1 60); do
  PLUGIN="$(oci instance-agent plugin get --region "$REGION" --compartment-id "$COMPARTMENT_ID" --instanceagent-id "$INSTANCE_ID" --plugin-name 'Compute Instance Run Command' --query 'data.status' --raw-output 2>/dev/null || echo STARTING)"
  echo "Run Command plugin: $PLUGIN"
  [ "$PLUGIN" = "RUNNING" ] && break
  sleep 10
done
[ "$PLUGIN" = "RUNNING" ] || { echo "Oracle Run Command plugin did not become RUNNING within 10 minutes." >&2; exit 1; }

echo "[3/9] Selecting the Cloud Shell SSH key..."
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
[ -f "$KEY" ] || KEY="$HOME/nams-dedicated.key"
if [ ! -f "$KEY" ]; then
  KEY="$(find "$HOME" -maxdepth 3 -type f \( -name 'nams.key' -o -name 'nams-dedicated.key' \) -print -quit 2>/dev/null || true)"
fi
[ -n "${KEY:-}" ] && [ -f "$KEY" ] || { echo "No NAMS private SSH key exists in Cloud Shell." >&2; exit 1; }
chmod 600 "$KEY"
PUBKEY="$(ssh-keygen -y -f "$KEY")"

echo "[4/9] Ensuring the OCI network security group permits SSH..."
VNIC_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0].id' --raw-output 2>/dev/null || true)"
NSG_ID=""
if valid_ocid "$VNIC_ID"; then
  NSG_ID="$(oci network vnic get --region "$REGION" --vnic-id "$VNIC_ID" --query 'data."nsg-ids"[0]' --raw-output 2>/dev/null || true)"
fi
if valid_ocid "$NSG_ID"; then
  oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all > "$WORK/nsg.json"
  HAS22="$(python3 - "$WORK/nsg.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])).get('data',[])
ok=False
for r in rows:
    if r.get('direction')!='INGRESS' or str(r.get('protocol'))!='6': continue
    p=((r.get('tcp-options') or {}).get('destination-port-range') or {})
    lo,hi=p.get('min'),p.get('max')
    if lo is not None and hi is not None and lo<=22<=hi: ok=True
print('yes' if ok else 'no')
PY
)"
  if [ "$HAS22" != "yes" ]; then
    cat > "$WORK/ssh-rule.json" <<'JSON'
[{"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]
JSON
    oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/ssh-rule.json" >/dev/null
    echo "Added TCP 22 to the NAMS NSG."
  else
    echo "TCP 22 already permitted by the NAMS NSG."
  fi
else
  echo "No NSG was attached; continuing because the existing subnet security list may provide SSH."
fi

echo "[5/9] Sending a repair command through Oracle Cloud Agent..."
cat > "$WORK/repair.sh" <<EOF
#!/bin/bash
set -Eeuo pipefail
sudo install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
sudo touch /home/ubuntu/.ssh/authorized_keys
sudo grep -qxF '$PUBKEY' /home/ubuntu/.ssh/authorized_keys || echo '$PUBKEY' | sudo tee -a /home/ubuntu/.ssh/authorized_keys >/dev/null
sudo chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
sudo chmod 600 /home/ubuntu/.ssh/authorized_keys
sudo ufw allow 22/tcp >/dev/null 2>&1 || true
sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true
curl -fL --retry 5 --connect-timeout 20 '$REMOTE_URL' -o /tmp/nams-v5-resume.sh
chmod +x /tmp/nams-v5-resume.sh
sudo pkill -f '[n]ams-v5-resume.sh' >/dev/null 2>&1 || true
sudo rm -f /var/lib/nams-v5-resume.status /var/log/nams-v5-resume.log
sudo nohup env NAMS_DOMAIN='$DOMAIN' bash /tmp/nams-v5-resume.sh >/dev/null 2>&1 </dev/null &
echo RECOVERY_STARTED
EOF
python3 - "$WORK/repair.sh" "$WORK/content.json" <<'PY'
import json,sys
text=open(sys.argv[1]).read()
json.dump({'source':{'sourceType':'TEXT','text':text},'output':{'outputType':'TEXT'}},open(sys.argv[2],'w'))
PY
python3 - "$INSTANCE_ID" "$WORK/target.json" <<'PY'
import json,sys
json.dump({'instanceId':sys.argv[1]},open(sys.argv[2],'w'))
PY
COMMAND_ID="$(oci instance-agent command create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --content "file://$WORK/content.json" --target "file://$WORK/target.json" --timeout-in-seconds 600 --display-name 'NAMS v5 SSH and recovery repair' --query 'data.id' --raw-output)"
valid_ocid "$COMMAND_ID" || { echo "Oracle did not create the repair command." >&2; exit 1; }

echo "[6/9] Waiting for Oracle Agent command execution..."
CMD_STATE='ACCEPTED'
for i in $(seq 1 90); do
  CMD_STATE="$(oci instance-agent command-execution get --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo ACCEPTED)"
  echo "Repair command: $CMD_STATE"
  case "$CMD_STATE" in
    SUCCEEDED) break ;;
    FAILED|TIMED_OUT|CANCELED)
      oci instance-agent command-execution get --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json || true
      exit 1 ;;
  esac
  sleep 10
done
[ "$CMD_STATE" = "SUCCEEDED" ] || { echo "Repair command did not complete." >&2; exit 1; }
OUTPUT="$(oci instance-agent command-execution get --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'data.content.text' --raw-output 2>/dev/null || true)"
echo "$OUTPUT"

echo "[7/9] Confirming repaired SSH access..."
ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o ConnectionAttempts=3 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP")
for i in $(seq 1 30); do
  if "${SSH[@]}" 'echo SSH_REPAIRED' 2>/dev/null | grep -q SSH_REPAIRED; then break; fi
  echo "Waiting for SSH after repair..."
  [ "$i" -eq 30 ] && { echo "Oracle Agent repaired the VM, but TCP 22 is still unreachable. The recovery worker is running in the VM; wait 20 minutes and rerun this command to retrieve status." >&2; exit 1; }
  sleep 10
done

echo "[8/9] Monitoring the background NAMS build..."
for i in $(seq 1 140); do
  STATUS="$("${SSH[@]}" 'sudo cat /var/lib/nams-v5-resume.status 2>/dev/null || echo STARTING' 2>/dev/null || echo RECONNECTING)"
  echo "Status: $STATUS — $((i*15/60)) minute(s) elapsed"
  "${SSH[@]}" 'sudo tail -n 8 /var/log/nams-v5-resume.log 2>/dev/null || true' 2>/dev/null || true
  [ "$STATUS" = "SUCCESS" ] && break
  if [[ "$STATUS" == FAILED:* ]]; then
    "${SSH[@]}" 'sudo tail -n 220 /var/log/nams-v5-resume.log; cd /opt/nams-v5 2>/dev/null && sudo docker compose ps && sudo docker compose logs --tail=120 app chromium lightpanda caddy ollama || true' || true
    exit 1
  fi
  [ "$i" -eq 140 ] && { echo "Recovery did not finish within 35 minutes." >&2; exit 1; }
  sleep 15
done

echo "[9/9] Reading verified access details..."
RESULT="$("${SSH[@]}" "sudo grep -E '^(NAMS_V5_READY|DOMAIN=|TOKEN=|DASHBOARD=|BROWSER=)' /var/log/nams-v5-resume.log | tail -5")"
printf '%s\n' "$RESULT"
TOKEN="$(printf '%s\n' "$RESULT" | sed -n 's/^TOKEN=//p' | tail -1)"
[ -n "$TOKEN" ] || { echo "Build completed but no token was returned." >&2; exit 1; }

echo
echo "NAMS V5 IS WORKING"
echo "Dashboard: https://$DOMAIN/?token=$TOKEN"
echo "Token: $TOKEN"
echo "Live browser: https://$DOMAIN/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify"
