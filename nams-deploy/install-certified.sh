#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/nams
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
TOKEN="${ADMIN_TOKEN:?ADMIN_TOKEN is required}"
SOURCE_REF="${NAMS_SOURCE_REF:?NAMS_SOURCE_REF is required}"
IMAGE_TAG="${NAMS_IMAGE_TAG:?NAMS_IMAGE_TAG is required}"
MODEL="${OLLAMA_MODEL:-gemma3:1b}"
GHCR_USER="${GHCR_USER:-nitutravels}"
GHCR_TOKEN_B64="${GHCR_TOKEN_B64:-}"
BASE_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${SOURCE_REF}"
LOG=/var/log/nams-install.log
STATUS=/var/lib/nams-install.status

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
mkdir -p /var/lib "$APP_DIR"
: >"$LOG"
exec > >(tee -a "$LOG" /dev/console) 2>&1
PHASE=bootstrap
trap 'rc=$?; printf "FAILED:%s:%s\n" "$PHASE" "$rc" >"$STATUS"; echo "NAMS installation failed in phase $PHASE at line $LINENO with exit code $rc"; cd "$APP_DIR" 2>/dev/null && docker compose ps && docker compose logs --tail=240 || true; exit "$rc"' ERR
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"

retry() {
  local attempts="$1" delay="$2"; shift 2
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then return 1; fi
    echo "Command failed in phase $PHASE; retry $n/$attempts after ${delay}s"
    n=$((n+1)); sleep "$delay"
  done
}

PHASE=network
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
for i in $(seq 1 120); do
  if getent hosts raw.githubusercontent.com >/dev/null 2>&1 && getent hosts ghcr.io >/dev/null 2>&1 && getent hosts download.docker.com >/dev/null 2>&1; then break; fi
  [ "$i" -eq 120 ] && { echo 'DNS/network did not become ready' >&2; exit 10; }
  sleep 5
done

PHASE=packages
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
export DEBIAN_FRONTEND=noninteractive
retry 6 15 apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=5 update
retry 4 15 apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=5 install -y ca-certificates curl gnupg openssl ufw jq
install -m 0755 -d /etc/apt/keyrings
retry 5 10 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" >/etc/apt/sources.list.d/docker.list
retry 6 15 apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=5 update
retry 4 15 apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=5 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

PHASE=configuration
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
mkdir -p "$APP_DIR/data/lightpanda" "$APP_DIR/data/chromium" "$APP_DIR/assets" "$APP_DIR/config"
retry 5 10 curl -fL --connect-timeout 20 "$BASE_URL/nams-v6/docker-compose.yml" -o "$APP_DIR/docker-compose.yml"
retry 5 10 curl -fL --connect-timeout 20 "$BASE_URL/nams-v6/Caddyfile" -o "$APP_DIR/Caddyfile"
retry 5 10 curl -fL --connect-timeout 20 "$BASE_URL/nams-v5/config/catalog.json" -o "$APP_DIR/config/catalog.json"

cat >"$APP_DIR/.env" <<ENV
TZ=Asia/Kolkata
NAMS_DOMAIN=$DOMAIN
ADMIN_TOKEN=$TOKEN
NAMS_APP_IMAGE=ghcr.io/nitutravels/nams-v6-app:$IMAGE_TAG
NAMS_CHROMIUM_IMAGE=ghcr.io/nitutravels/nams-v6-chromium:$IMAGE_TAG
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_MODEL=$MODEL
LIGHTPANDA_CDP=http://lightpanda:9222
CHROMIUM_CDP=http://chromium:9223
BUSINESS_NAME=Nitu Travels
CONTACT_NAME=Ashu Grover
BUSINESS_WEBSITE=https://www.nitutravels.in/
TARGET_PAGE=https://www.nitutravels.in/bus-rental-delhi.html
BUSINESS_EMAIL=nitutravels@gmail.com
BUSINESS_PHONE=+91 98188 37830
BUSINESS_WHATSAPP=+91 89010 66699
BUSINESS_ADDRESS=216, A/5 Gautam Nagar, New Delhi, Delhi 110049
SERVICE_FOCUS=bus on hire in Delhi NCR
MAX_DAILY_DISCOVERY=8
MAX_DAILY_SUBMISSIONS=2
CRON_DISCOVERY=0 9 * * *
CRON_SUBMIT=0 12 * * *
CRON_RECHECK=0 18 * * *
AUTO_SEND_EMAIL=false
SMTP_HOST=smtp.gmail.com
SMTP_PORT=465
SMTP_USER=
SMTP_APP_PASSWORD=
ENV
chmod 600 "$APP_DIR/.env"
cd "$APP_DIR"
docker compose config >/var/lib/nams-compose-rendered.yml

PHASE=image_pull
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
if [ -n "$GHCR_TOKEN_B64" ]; then
  printf '%s' "$GHCR_TOKEN_B64" | base64 -d | docker login ghcr.io -u "$GHCR_USER" --password-stdin
fi
retry 4 20 docker compose pull
if [ -n "$GHCR_TOKEN_B64" ]; then
  docker logout ghcr.io >/dev/null 2>&1 || true
  rm -f /root/.docker/config.json
fi

PHASE=start
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
docker compose up -d --remove-orphans

probe() { curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "$1"; }
PHASE=core_verify
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
READY=0
for i in $(seq 1 180); do
  if probe http://127.0.0.1/_probe/app/health >/tmp/app-health.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/chromium/json/version >/tmp/chromium.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/novnc/vnc.html >/tmp/novnc.html 2>/dev/null && \
     probe http://127.0.0.1/_probe/lightpanda/json/version >/tmp/lightpanda.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/ollama.json 2>/dev/null; then READY=1; break; fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "Core verification: $((i/12)) minute(s) elapsed"
    docker compose ps || true
    docker compose logs --tail=30 app caddy chromium lightpanda ollama || true
  fi
  sleep 5
done
[ "$READY" -eq 1 ] || { echo 'Core services did not become healthy' >&2; exit 20; }
grep -q '"ok"' /tmp/app-health.json
grep -q 'webSocketDebuggerUrl' /tmp/chromium.json
grep -qi 'noVNC' /tmp/novnc.html

PHASE=model_verify
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
MODEL_READY=0
for i in $(seq 1 360); do
  if probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/ollama.json 2>/dev/null && jq -e --arg model "$MODEL" '.models[]? | select(.name==$model or .model==$model or (.name|startswith($model+":")))' /tmp/ollama.json >/dev/null; then MODEL_READY=1; break; fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "AI model verification: $((i/12)) minute(s) elapsed"
    docker compose logs --tail=30 model-loader ollama || true
  fi
  sleep 5
done
[ "$MODEL_READY" -eq 1 ] || { echo "Model $MODEL was not loaded" >&2; exit 21; }

PHASE=persistence
printf 'RUNNING:%s\n' "$PHASE" >"$STATUS"
cat >/usr/local/sbin/nams-watchdog <<'WATCHDOG'
#!/usr/bin/env bash
set -u
cd /opt/nams || exit 1
TOKEN="$(awk -F= '$1=="ADMIN_TOKEN"{print substr($0,index($0,"=")+1);exit}' .env)"
probe(){ curl -fsS --connect-timeout 4 --max-time 10 -H "X-NAMS-Probe: $TOKEN" "$1" >/dev/null; }
failed=()
probe http://127.0.0.1/_probe/app/health || failed+=(app)
probe http://127.0.0.1/_probe/chromium/json/version || failed+=(chromium)
probe http://127.0.0.1/_probe/lightpanda/json/version || failed+=(lightpanda)
probe http://127.0.0.1/_probe/ollama/api/tags || failed+=(ollama)
if [ ${#failed[@]} -gt 0 ]; then
  logger -t nams-watchdog "Restarting unhealthy services: ${failed[*]}"
  docker compose restart "${failed[@]}" || true
  sleep 20
  docker compose up -d
fi
WATCHDOG
chmod 750 /usr/local/sbin/nams-watchdog
cat >/etc/systemd/system/nams.service <<'UNIT'
[Unit]
Description=NAMS Authority Agent
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/nams
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/nams-watchdog.service <<'UNIT'
[Unit]
Description=NAMS health watchdog
After=nams.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nams-watchdog
UNIT
cat >/etc/systemd/system/nams-watchdog.timer <<'UNIT'
[Unit]
Description=Run NAMS watchdog every five minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable nams.service nams-watchdog.timer
systemctl start nams-watchdog.timer

curl -fsS -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1/run/discovery >/dev/null || true
printf '%s\n' "$TOKEN" >/var/lib/nams-dashboard-token
chmod 600 /var/lib/nams-dashboard-token
printf 'SUCCESS\n' >"$STATUS"
echo NAMS_READY
echo "TOKEN=$TOKEN"
echo "DOMAIN=$DOMAIN"
echo "IMAGE_TAG=$IMAGE_TAG"
echo "Completed=$(date -Is)"
