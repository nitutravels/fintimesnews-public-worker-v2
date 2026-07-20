#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/nams-v6
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
TOKEN="${ADMIN_TOKEN:-}"
RELEASE_REF="${NAMS_RELEASE_REF:-nams-hybrid-installer}"
APP_IMAGE_TAG="${NAMS_APP_IMAGE_TAG:-latest}"
CHROMIUM_IMAGE_TAG="${NAMS_CHROMIUM_IMAGE_TAG:-latest}"
MODEL="${OLLAMA_MODEL:-gemma3:1b}"
BASE_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${RELEASE_REF}/nams-v6"
CATALOG_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${RELEASE_REF}/nams-v5/config/catalog.json"
LOG=/var/log/nams-v6-install.log
STATUS=/var/lib/nams-v6-install.status

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
mkdir -p /var/lib
: >"$LOG"
exec > >(tee -a "$LOG" /dev/console) 2>&1
trap 'rc=$?; echo "FAILED:$rc" >"$STATUS"; echo "NAMS v6 installation failed at line $LINENO with exit code $rc"; cd "$APP_DIR" 2>/dev/null && docker compose ps && docker compose logs --tail=180 || true; exit $rc' ERR

echo RUNNING >"$STATUS"
echo "NAMS v6 prebuilt installation started: $(date -Is)"
[ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 24)"

export DEBIAN_FRONTEND=noninteractive
for i in $(seq 1 90); do
  if curl -fsS --connect-timeout 5 https://raw.githubusercontent.com/ >/dev/null 2>&1 && getent hosts ghcr.io >/dev/null 2>&1; then break; fi
  [ "$i" -eq 90 ] && { echo "Public network did not become ready." >&2; exit 10; }
  sleep 5
done

apt-get update
apt-get install -y ca-certificates curl gnupg openssl ufw jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" >/etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

mkdir -p "$APP_DIR" "$APP_DIR/data/lightpanda" "$APP_DIR/data/chromium" "$APP_DIR/assets" "$APP_DIR/config"
curl -fL --retry 5 --connect-timeout 20 "$BASE_URL/docker-compose.yml" -o "$APP_DIR/docker-compose.yml"
curl -fL --retry 5 --connect-timeout 20 "$BASE_URL/Caddyfile" -o "$APP_DIR/Caddyfile"
curl -fL --retry 5 --connect-timeout 20 "$CATALOG_URL" -o "$APP_DIR/config/catalog.json"

cat >"$APP_DIR/.env" <<ENV
TZ=Asia/Kolkata
NAMS_DOMAIN=$DOMAIN
ADMIN_TOKEN=$TOKEN
NAMS_APP_IMAGE=ghcr.io/nitutravels/nams-v6-app:$APP_IMAGE_TAG
NAMS_CHROMIUM_IMAGE=ghcr.io/nitutravels/nams-v6-chromium:$CHROMIUM_IMAGE_TAG
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
docker compose config >/tmp/nams-v6-compose-rendered.yml

echo "Pulling certified images; no image will be built on this VM..."
docker compose pull

echo "Starting NAMS v6..."
docker compose up -d --remove-orphans

probe(){ curl -fsS --connect-timeout 5 --max-time 15 -H "X-NAMS-Probe: $TOKEN" "$1"; }

READY=0
for i in $(seq 1 120); do
  if probe http://127.0.0.1/_probe/app/health >/tmp/nams-v6-app-health.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/chromium/json/version >/tmp/nams-v6-chromium.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/novnc/vnc.html >/tmp/nams-v6-novnc.html 2>/dev/null && \
     probe http://127.0.0.1/_probe/lightpanda/json/version >/tmp/nams-v6-lightpanda.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/nams-v6-ollama.json 2>/dev/null; then
    READY=1
    break
  fi
  if [ $((i % 6)) -eq 0 ]; then
    echo "Core readiness wait: $((i/2)) minute(s)"
    docker compose ps || true
    docker compose logs --tail=25 app caddy chromium lightpanda ollama || true
  fi
  sleep 5
done
[ "$READY" -eq 1 ] || { echo "Core services did not become ready." >&2; exit 20; }

grep -q '"ok"' /tmp/nams-v6-app-health.json
grep -q 'webSocketDebuggerUrl' /tmp/nams-v6-chromium.json
grep -qi 'noVNC' /tmp/nams-v6-novnc.html

MODEL_READY=0
for i in $(seq 1 240); do
  if probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/nams-v6-ollama.json 2>/dev/null && jq -e --arg model "$MODEL" '.models[]? | select(.name==$model or .model==$model or (.name|startswith($model+":")))' /tmp/nams-v6-ollama.json >/dev/null; then
    MODEL_READY=1
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "AI model readiness wait: $((i/12)) minute(s)"
    docker compose logs --tail=20 model-loader ollama || true
  fi
  sleep 5
done
[ "$MODEL_READY" -eq 1 ] || { echo "Core stack is running but model $MODEL was not loaded." >&2; exit 21; }

cat >/usr/local/sbin/nams-v6-watchdog <<'WATCHDOG'
#!/usr/bin/env bash
set -u
cd /opt/nams-v6 || exit 1
TOKEN="$(awk -F= '$1=="ADMIN_TOKEN"{print substr($0,index($0,"=")+1);exit}' .env)"
probe(){ curl -fsS --connect-timeout 4 --max-time 10 -H "X-NAMS-Probe: $TOKEN" "$1" >/dev/null; }
failed=()
probe http://127.0.0.1/_probe/app/health || failed+=(app)
probe http://127.0.0.1/_probe/chromium/json/version || failed+=(chromium)
probe http://127.0.0.1/_probe/lightpanda/json/version || failed+=(lightpanda)
probe http://127.0.0.1/_probe/ollama/api/tags || failed+=(ollama)
if [ ${#failed[@]} -gt 0 ]; then
  logger -t nams-v6-watchdog "Restarting unhealthy services: ${failed[*]}"
  docker compose restart "${failed[@]}"
  sleep 20
  docker compose up -d
fi
WATCHDOG
chmod 750 /usr/local/sbin/nams-v6-watchdog

cat >/etc/systemd/system/nams-v6.service <<'UNIT'
[Unit]
Description=NAMS Authority Agent v6
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/nams-v6
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/nams-v6-watchdog.service <<'UNIT'
[Unit]
Description=NAMS v6 health watchdog
After=nams-v6.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nams-v6-watchdog
UNIT

cat >/etc/systemd/system/nams-v6-watchdog.timer <<'UNIT'
[Unit]
Description=Run NAMS v6 watchdog every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable nams-v6.service nams-v6-watchdog.timer
systemctl start nams-v6-watchdog.timer

curl -fsS -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1/run/discovery >/dev/null || true
printf '%s\n' "$TOKEN" >/var/lib/nams-v6-dashboard-token
chmod 600 /var/lib/nams-v6-dashboard-token
echo SUCCESS >"$STATUS"

echo "NAMS_V6_READY"
echo "TOKEN=$TOKEN"
echo "DOMAIN=$DOMAIN"
echo "APP_IMAGE=ghcr.io/nitutravels/nams-v6-app:$APP_IMAGE_TAG"
echo "CHROMIUM_IMAGE=ghcr.io/nitutravels/nams-v6-chromium:$CHROMIUM_IMAGE_TAG"
echo "Completed: $(date -Is)"
