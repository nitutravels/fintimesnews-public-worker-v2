#!/usr/bin/env bash
set -Eeuo pipefail

NAME="${NAMS_INSTANCE_NAME:-nams-phase1}"
REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
REMOTE_INSTALLER="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/nams-hybrid-installer/nams-hybrid/install.sh"
trap 'c=$?; echo; echo "INSTALLER STOPPED at line $LINENO (exit $c)." >&2; exit $c' ERR

echo "NAMS Hybrid deployment bootstrap v3"
echo "Instance: $NAME | Region: $REGION"

if [ ! -f "$KEY" ]; then
  KEY="$(find "$HOME" -maxdepth 4 -type f -name 'nams.key' -print -quit 2>/dev/null || true)"
fi
if [ -z "${KEY:-}" ] || [ ! -f "$KEY" ]; then
  echo "ERROR: nams.key was not found. Use Cloud Shell Menu > Upload." >&2
  exit 1
fi
chmod 600 "$KEY"

echo "[1/8] Finding the OCI instance across all compartments..."
SEARCH_FILE="$(mktemp)"
if ! oci search resource structured-search \
  --region "$REGION" \
  --query-text "query instance resources where displayName = '$NAME'" \
  --output json >"$SEARCH_FILE"; then
  echo "OCI Resource Search failed. Cloud Shell should already use its pre-authenticated OCI CLI." >&2
  exit 1
fi
INSTANCE_ID="$(python3 - "$SEARCH_FILE" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1]))
data=obj.get('data',obj)
items=data.get('items',[]) if isinstance(data,dict) else []
def g(x,*ks):
    for k in ks:
        if k in x:return x[k]
    return ''
rows=[x for x in items if str(g(x,'lifecycleState','lifecycle-state')).upper() not in ('TERMINATED','TERMINATING')]
rows.sort(key=lambda x:(str(g(x,'lifecycleState','lifecycle-state')).upper()!='RUNNING', str(g(x,'timeCreated','time-created'))), reverse=False)
print(g(rows[0],'identifier','id') if rows else '')
PY
)"
rm -f "$SEARCH_FILE"
if [ -z "$INSTANCE_ID" ]; then
  echo "ERROR: No active instance named '$NAME' was found in $REGION." >&2
  exit 1
fi
echo "Instance OCID found."

STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
echo "[2/8] Instance state: $STATE"
if [ "$STATE" = "STOPPED" ]; then
  echo "Starting the instance..."
  oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action START >/dev/null
fi
for _ in $(seq 1 48); do
  STATE="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
  [ "$STATE" = "RUNNING" ] && break
  echo "Waiting for RUNNING; current state: $STATE"
  sleep 10
done
[ "$STATE" = "RUNNING" ] || { echo "ERROR: Instance did not reach RUNNING." >&2; exit 1; }

VNIC_FILE="$(mktemp)"
oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --all --output json >"$VNIC_FILE"
read -r PUBLIC_IP SUBNET_ID <<EOF
$(python3 - "$VNIC_FILE" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1])); rows=obj.get('data',[])
if not rows: print(' '); raise SystemExit
def g(x,*ks):
    for k in ks:
        if k in x:return x[k]
    return ''
r=rows[0]; print(g(r,'public-ip','publicIp'),g(r,'subnet-id','subnetId'))
PY
)
EOF
rm -f "$VNIC_FILE"
if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ] || [ "$PUBLIC_IP" = "None" ]; then
  echo "ERROR: The primary VNIC has no public IPv4 address." >&2
  exit 1
fi
echo "[3/8] Current public IP: $PUBLIC_IP"

open_port_rules(){
  echo "Repairing subnet security-list ingress for TCP 22 and 80..."
  IDS_FILE="$(mktemp)"
  oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."security-list-ids"' --output json >"$IDS_FILE"
  python3 - "$IDS_FILE" <<'PY' >/tmp/nams-security-list-ids
import json,sys
x=json.load(open(sys.argv[1]))
if isinstance(x,dict): x=x.get('data',x)
for i in x or []: print(i)
PY
  rm -f "$IDS_FILE"
  while IFS= read -r SL; do
    [ -n "$SL" ] || continue
    GET_FILE="$(mktemp)"; RULE_FILE="$(mktemp)"
    oci network security-list get --region "$REGION" --security-list-id "$SL" --output json >"$GET_FILE"
    python3 - "$GET_FILE" "$RULE_FILE" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1])); rules=obj['data'].get('ingress-security-rules',[])
def cv(v):
  if isinstance(v,list): return [cv(x) for x in v]
  if not isinstance(v,dict): return v
  mp={'is-stateless':'isStateless','source-type':'sourceType','tcp-options':'tcpOptions','udp-options':'udpOptions','icmp-options':'icmpOptions','destination-port-range':'destinationPortRange','source-port-range':'sourcePortRange'}
  return {mp.get(k,k):cv(x) for k,x in v.items() if x is not None}
rules=cv(rules)
def has(p):
  for r in rules:
    if str(r.get('protocol'))!='6': continue
    d=(r.get('tcpOptions') or {}).get('destinationPortRange') or {}
    if d and int(d.get('min',-1))<=p<=int(d.get('max',-1)) and r.get('source')=='0.0.0.0/0': return True
  return False
for p,desc in ((22,'SSH'),(80,'NAMS dashboard')):
  if not has(p):
    rules.append({'source':'0.0.0.0/0','sourceType':'CIDR_BLOCK','protocol':'6','isStateless':False,'description':desc,'tcpOptions':{'destinationPortRange':{'min':p,'max':p}}})
json.dump(rules,open(sys.argv[2],'w'))
PY
    oci network security-list update --region "$REGION" --security-list-id "$SL" --ingress-security-rules "file://$RULE_FILE" --force >/dev/null
    rm -f "$GET_FILE" "$RULE_FILE"
  done </tmp/nams-security-list-ids
  rm -f /tmp/nams-security-list-ids
}

echo "[4/8] Checking SSH reachability..."
if ! timeout 12 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then
  open_port_rules
  echo "Waiting for the OCI networking change..."
  READY=0
  for _ in $(seq 1 18); do
    if timeout 5 bash -c "</dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then READY=1; break; fi
    sleep 10
  done
  if [ "$READY" -ne 1 ]; then
    echo "ERROR: TCP 22 is still unreachable on $PUBLIC_IP." >&2
    echo "The remaining cause is likely the route table, public-IP assignment, NSG, or the VM operating-system firewall." >&2
    exit 1
  fi
fi

ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o ConnectionAttempts=2 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)

echo "[5/8] Testing SSH authentication..."
timeout 50 ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" 'echo "SSH connected to $(hostname)"; sudo -n true'

echo "[6/8] Downloading the VM installer..."
ssh "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" "curl -fL --connect-timeout 20 --retry 4 --retry-delay 3 '$REMOTE_INSTALLER' -o /tmp/nams-install.sh && chmod 700 /tmp/nams-install.sh"

echo "[7/8] Installing Docker, Lightpanda, Ollama and NAMS..."
echo "This can take 10-25 minutes. Keep Cloud Shell open."
ssh -tt "${SSH_OPTS[@]}" "ubuntu@$PUBLIC_IP" "sudo PUBLIC_IP='$PUBLIC_IP' bash -x /tmp/nams-install.sh"

echo "[8/8] Deployment completed."
echo "Use the dashboard URL and token printed above."
