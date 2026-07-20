#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
COMPARTMENT_NAME="NituWAGateway"
INSTANCE_NAME="NAMS-Lightpanda-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/ae115249f104390848873bd75923d4c9e6b2ebda/nams-v5/install-v5-fresh-v2.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }

echo
 echo "NAMS v5 in-place diagnosis and repair"
 echo "No VM will be created, terminated, resized or replaced."
 echo

echo "[1/7] Resolving the existing NAMS VM..."
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$COMPARTMENT_ID" || { echo "Compartment not found." >&2; exit 1; }
INSTANCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all --query 'data[?"lifecycle-state"==`RUNNING`] | [0].id' --raw-output 2>/dev/null || true)"
valid_ocid "$INSTANCE_ID" || { echo "Running $INSTANCE_NAME instance not found." >&2; exit 1; }
PUBLIC_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
if ! [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  PUBLIC_IP="$(oci network public-ip list --region "$REGION" --scope REGION --compartment-id "$COMPARTMENT_ID" --lifetime RESERVED --all --query 'data[?"display-name"==`NAMS-v5-Reserved-IP`] | [0]."ip-address"' --raw-output 2>/dev/null || true)"
fi
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "No public IP found." >&2; exit 1; }
echo "Instance: $INSTANCE_NAME"
echo "Public IP: $PUBLIC_IP"

echo "[2/7] Capturing Oracle serial-console history..."
HISTORY_ID="$(oci compute console-history capture --region "$REGION" --instance-id "$INSTANCE_ID" --wait-for-state SUCCEEDED --max-wait-seconds 300 --query 'data.id' --raw-output 2>/dev/null || true)"
if valid_ocid "$HISTORY_ID"; then
  oci compute console-history get-content --region "$REGION" --instance-console-history-id "$HISTORY_ID" --file "$WORK/console.txt" >/dev/null 2>&1 || true
  cp "$WORK/console.txt" "$HOME/nams-v5-latest-console.txt" 2>/dev/null || true
  echo "Console history saved as ~/nams-v5-latest-console.txt"
  echo "Recent installation messages:"
  grep -Eai 'NAMS|cloud-init|docker|npm|failed|error|no space|killed|oom|health|ollama|chromium' "$WORK/console.txt" 2>/dev/null | tail -n 40 || tail -n 40 "$WORK/console.txt" || true
else
  echo "Console history capture was unavailable; continuing with SSH diagnosis."
fi

echo "[3/7] Locating the SSH key..."
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
[ -f "$KEY" ] || KEY="$HOME/nams-dedicated.key"
if [ ! -f "$KEY" ]; then KEY="$(find "$HOME" -maxdepth 3 -type f \( -name 'nams.key' -o -name 'nams-dedicated.key' \) -print -quit 2>/dev/null || true)"; fi
[ -n "${KEY:-}" ] && [ -f "$KEY" ] || { echo "SSH key not found in Cloud Shell." >&2; exit 2; }
chmod 600 "$KEY"
ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=2 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new "ubuntu@$PUBLIC_IP")

if ! timeout 8 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then
  echo "SSH port 22 is not reachable. No rebuild was attempted." >&2
  echo "Read ~/nams-v5-latest-console.txt for the exact cloud-init failure." >&2
  exit 3
fi
if ! "${SSH[@]}" 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
  echo "Port 22 is open, but the available key is not authorized. No rebuild was attempted." >&2
  exit 4
fi

echo "[4/7] Inspecting cloud-init, installation and Docker state..."
"${SSH[@]}" 'sudo bash -s' <<'REMOTE_INSPECT'
set +e
echo "--- cloud-init status ---"
cloud-init status --long 2>&1 || true
echo "--- installer status ---"
cat /var/lib/nams-v5-fresh-install.status 2>/dev/null || echo STATUS_FILE_NOT_YET_CREATED
echo "--- active installation processes ---"
pgrep -af 'nams-install-v5|docker.*build|docker compose|npm install|ollama pull|apt-get|cloud-final' || true
echo "--- disk and memory ---"
df -h /; free -h; swapon --show || true
echo "--- Docker state ---"
cd /opt/nams-v5 2>/dev/null && docker compose ps 2>/dev/null || true
echo "--- recent installer output ---"
tail -n 70 /var/log/nams-v5-fresh-install.log 2>/dev/null || tail -n 70 /var/log/cloud-init-output.log 2>/dev/null || true
REMOTE_INSPECT

if curl -fsS --connect-timeout 8 "http://$PUBLIC_IP/health" > "$WORK/health.json" 2>/dev/null; then
  echo "[5/7] Service is already healthy: $(cat "$WORK/health.json")"
else
  echo "[5/7] Service is not healthy yet. Determining whether installation is active..."
  ACTIVE="$("${SSH[@]}" "pgrep -f 'nams-install-v5|docker.*build|npm install|ollama pull|cloud-final' >/dev/null && echo yes || echo no")"
  if [ "$ACTIVE" = "no" ]; then
    echo "The installer is no longer running. Restarting it on the SAME VM only."
    TOKEN="$("${SSH[@]}" "sudo awk -F= '/^ADMIN_TOKEN=/{print substr(\$0,index(\$0,\"=\")+1);exit}' /opt/nams-v5/.env 2>/dev/null || sudo cat /var/lib/nams-v5-dashboard-token 2>/dev/null || true")"
    [ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 24)"
    "${SSH[@]}" "curl -fL --retry 5 --connect-timeout 20 '$INSTALLER_URL' -o /tmp/nams-install-v5-repair.sh && chmod +x /tmp/nams-install-v5-repair.sh && sudo rm -f /var/lib/nams-v5-fresh-install.status && sudo nohup env ADMIN_TOKEN='$TOKEN' NAMS_DOMAIN='$DOMAIN' bash /tmp/nams-install-v5-repair.sh >/var/log/nams-v5-manual-repair.log 2>&1 </dev/null &"
  else
    echo "The original installer is still active. It will not be duplicated or restarted."
  fi

  echo "[6/7] Monitoring the SAME VM for up to 30 minutes..."
  READY=0
  for i in $(seq 1 60); do
    if curl -fsS --connect-timeout 8 "http://$PUBLIC_IP/health" > "$WORK/health.json" 2>/dev/null; then READY=1; break; fi
    if [ $((i % 2)) -eq 0 ]; then
      echo "Elapsed: $((i/2)) minute(s)"
      "${SSH[@]}" "sudo tail -n 12 /var/log/nams-v5-manual-repair.log 2>/dev/null || sudo tail -n 12 /var/log/nams-v5-fresh-install.log 2>/dev/null || sudo tail -n 12 /var/log/cloud-init-output.log 2>/dev/null || true" || true
    fi
    sleep 30
  done
  if [ "$READY" -ne 1 ]; then
    echo "The existing VM is still not healthy. No additional VM was created." >&2
    echo "Final diagnostics:" >&2
    "${SSH[@]}" "cd /opt/nams-v5 2>/dev/null && sudo docker compose ps && sudo docker compose logs --tail=160 app chromium lightpanda caddy ollama || true; sudo tail -n 160 /var/log/nams-v5-manual-repair.log 2>/dev/null || sudo tail -n 160 /var/log/nams-v5-fresh-install.log 2>/dev/null || true" || true
    exit 5
  fi
fi

echo "[7/7] Reading active dashboard token..."
TOKEN="$("${SSH[@]}" "sudo awk -F= '/^ADMIN_TOKEN=/{print substr(\$0,index(\$0,\"=\")+1);exit}' /opt/nams-v5/.env")"
[ -n "$TOKEN" ] || { echo "Application is healthy but token could not be read." >&2; exit 6; }
echo
echo "NAMS V5 VERIFIED ON THE EXISTING VM"
echo "Health: $(cat "$WORK/health.json")"
echo "Public IP: $PUBLIC_IP"
echo "Dashboard now: http://$PUBLIC_IP/?token=$TOKEN"
echo "Token: $TOKEN"
echo "After DNS points to $PUBLIC_IP: https://$DOMAIN/?token=$TOKEN"
echo
echo "No VM was created or terminated by this repair."
