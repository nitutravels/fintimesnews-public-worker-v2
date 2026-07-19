#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="nams-hybrid-installer"
REPO="https://github.com/nitutravels/fintimesnews-public-worker-v2"
APP_DIR="/opt/nams-v5"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
MODEL="${OLLAMA_MODEL:-gemma3:1b}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git openssl ufw dnsutils python3

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
fi

PUBLIC_IP="${PUBLIC_IP:-$(curl -fsS --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')}"
DNS_IP="$(dig +short A "$DOMAIN" | tail -1 || true)"
echo "Domain: $DOMAIN"
echo "Server public IP: $PUBLIC_IP"
echo "Current DNS A record: ${DNS_IP:-not resolved}"
if [ -n "$DNS_IP" ] && [ "$DNS_IP" != "$PUBLIC_IP" ]; then
  echo "WARNING: $DOMAIN currently points to $DNS_IP, not $PUBLIC_IP. HTTPS will become ready after DNS is corrected." >&2
fi

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

TOKEN="${ADMIN_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f /opt/nams-hybrid/.env ]; then
  TOKEN="$(awk -F= '/^ADMIN_TOKEN=/{print $2;exit}' /opt/nams-hybrid/.env || true)"
fi
if [ -z "$TOKEN" ] && [ -f "$APP_DIR/.env" ]; then
  TOKEN="$(awk -F= '/^ADMIN_TOKEN=/{print $2;exit}' "$APP_DIR/.env" || true)"
fi
TOKEN="${TOKEN:-$(openssl rand -hex 24)}"

if [ -d /opt/nams-hybrid ]; then
  echo "Stopping and backing up the proof-of-concept deployment..."
  (cd /opt/nams-hybrid && docker compose down --remove-orphans) || true
  BACKUP="/opt/nams-hybrid-backup-$(date +%Y%m%d-%H%M%S)"
  cp -a /opt/nams-hybrid "$BACKUP"
  echo "Old deployment backup: $BACKUP"
fi
if [ -d "$APP_DIR" ]; then
  (cd "$APP_DIR" && docker compose down --remove-orphans) || true
  cp -a "$APP_DIR" "/opt/nams-v5-backup-$(date +%Y%m%d-%H%M%S)"
fi

git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMP/repo"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$TMP/repo/nams-v5/." "$APP_DIR/"
mkdir -p "$APP_DIR/data/lightpanda" "$APP_DIR/data/chromium" "$APP_DIR/assets"

# Ensure the noVNC WebSocket proxy is attached to the Node HTTP upgrade event.
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/nams-v5/app/index.js')
s=p.read_text()
old="app.listen(8080,'0.0.0.0',()=>{log('info','NAMS v5 started',{domain:DOMAIN,model:MODEL});console.log('NAMS v5 ready on 8080');});"
new="const server=app.listen(8080,'0.0.0.0',()=>{log('info','NAMS v5 started',{domain:DOMAIN,model:MODEL});console.log('NAMS v5 ready on 8080');});\nserver.on('upgrade',browserProxy.upgrade);"
if old in s:
    p.write_text(s.replace(old,new))
elif "server.on('upgrade',browserProxy.upgrade);" not in s:
    raise SystemExit('Could not install WebSocket upgrade hook')
PY

cat >"$APP_DIR/.env" <<ENV
TZ=Asia/Kolkata
NAMS_DOMAIN=$DOMAIN
ADMIN_TOKEN=$TOKEN
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

echo "Building the replacement stack..."
cd "$APP_DIR"
docker compose pull caddy lightpanda ollama
docker compose build --no-cache chromium app
docker compose up -d --remove-orphans

echo "Downloading local AI model $MODEL..."
docker compose exec -T ollama ollama pull "$MODEL"

echo "Waiting for application health..."
for i in $(seq 1 90); do
  if docker compose exec -T app curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then break; fi
  if [ $((i % 10)) -eq 0 ]; then docker compose ps; fi
  sleep 5
done
docker compose exec -T app curl -fsS http://127.0.0.1:8080/health

cat >/usr/local/bin/nams-v5-status <<'STATUS'
#!/usr/bin/env bash
cd /opt/nams-v5 && docker compose ps && echo && docker compose logs --tail=120 app caddy chromium lightpanda
STATUS
chmod +x /usr/local/bin/nams-v5-status

cat >/usr/local/bin/nams-v5-token <<'TOKENCMD'
#!/usr/bin/env bash
awk -F= '/^ADMIN_TOKEN=/{print $2}' /opt/nams-v5/.env
TOKENCMD
chmod +x /usr/local/bin/nams-v5-token

# Start the first qualification pass without waiting for the browser UI.
for _ in $(seq 1 30); do
  if curl -fsS --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/health" >/dev/null 2>&1; then
    curl -fsS --resolve "$DOMAIN:443:127.0.0.1" -X POST -H "Authorization: Bearer $TOKEN" "https://$DOMAIN/run/discovery" >/dev/null || true
    break
  fi
  sleep 5
done

echo
echo "NAMS V5 REPLACEMENT COMPLETE"
echo "Dashboard: https://$DOMAIN/?token=$TOKEN"
echo "Token: $TOKEN"
echo "Live verification browser: https://$DOMAIN/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify"
echo "Status command: sudo nams-v5-status"
echo "Old proof-of-concept data was backed up and is no longer serving port 80."
