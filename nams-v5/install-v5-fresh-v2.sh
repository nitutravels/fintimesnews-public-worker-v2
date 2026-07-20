#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="nams-hybrid-installer"
REPO="https://github.com/nitutravels/fintimesnews-public-worker-v2"
APP_DIR="/opt/nams-v5"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
TOKEN="${ADMIN_TOKEN:-}"
MODEL="${OLLAMA_MODEL:-gemma3:1b}"
LOG="/var/log/nams-v5-fresh-install.log"
STATUS="/var/lib/nams-v5-fresh-install.status"
TMP="$(mktemp -d)"

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
mkdir -p /var/lib
: > "$LOG"
exec > >(tee -a "$LOG" /dev/console) 2>&1
trap 'rc=$?; echo "FAILED:$rc" > "$STATUS"; echo "NAMS fresh install failed with exit code $rc"; if [ -d "$APP_DIR" ]; then cd "$APP_DIR"; docker compose ps || true; docker compose logs --tail=160 app chromium lightpanda caddy ollama || true; fi; exit $rc' ERR
trap 'rm -rf "$TMP"' EXIT

echo RUNNING > "$STATUS"
echo "NAMS fresh install started at $(date -Is)"
[ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 24)"

export DEBIAN_FRONTEND=noninteractive
for i in $(seq 1 60); do
  if curl -fsS --connect-timeout 5 https://raw.githubusercontent.com/ >/dev/null 2>&1; then break; fi
  echo "Waiting for public network before package installation ($i/60)..."
  sleep 10
done

apt-get update
apt-get install -y ca-certificates curl git openssl ufw dnsutils python3

if ! swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  echo "Creating persistent 4 GB swap for ARM Docker builds..."
  rm -f /swapfile
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -h

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
if ! docker compose version >/dev/null 2>&1; then apt-get install -y docker-compose-plugin; fi

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

rm -rf "$APP_DIR"
git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMP/repo"
mkdir -p "$APP_DIR"
cp -a "$TMP/repo/nams-v5/." "$APP_DIR/"
mkdir -p "$APP_DIR/data/lightpanda" "$APP_DIR/data/chromium" "$APP_DIR/assets"

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/nams-v5/app/index.js')
s=p.read_text()
old="app.listen(8080,'0.0.0.0',()=>{log('info','NAMS v5 started',{domain:DOMAIN,model:MODEL});console.log('NAMS v5 ready on 8080');});"
new="const server=app.listen(8080,'0.0.0.0',()=>{log('info','NAMS v5 started',{domain:DOMAIN,model:MODEL});console.log('NAMS v5 ready on 8080');});\nserver.on('upgrade',browserProxy.upgrade);"
if old in s:
    p.write_text(s.replace(old,new))
elif "server.on('upgrade',browserProxy.upgrade);" not in s:
    raise SystemExit('Could not install noVNC WebSocket upgrade hook')
PY

cat > "$APP_DIR/Caddyfile" <<'CADDY'
{
  auto_https disable_redirects
}

:80 {
  encode zstd gzip
  reverse_proxy app:8080
  header {
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
  }
}

{$NAMS_DOMAIN:seo.nitutravels.in} {
  encode zstd gzip
  reverse_proxy app:8080
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
  }
}
CADDY

cat > "$APP_DIR/.env" <<ENV
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

cd "$APP_DIR"
echo "Pulling public service images..."
docker compose pull caddy lightpanda ollama

echo "Building Chromium sequentially..."
COMPOSE_PARALLEL_LIMIT=1 docker compose --progress plain build chromium

echo "Building the NAMS application sequentially..."
COMPOSE_PARALLEL_LIMIT=1 docker compose --progress plain build app

echo "Starting the stack..."
docker compose up -d --remove-orphans

echo "Waiting for Ollama..."
for _ in $(seq 1 90); do
  if docker compose exec -T ollama ollama list >/tmp/nams-ollama-list 2>/dev/null; then break; fi
  sleep 5
done
if ! grep -q "^${MODEL}[[:space:]]" /tmp/nams-ollama-list 2>/dev/null; then
  docker compose exec -T ollama ollama pull "$MODEL"
fi

echo "Waiting for NAMS health..."
READY=0
for i in $(seq 1 240); do
  if docker compose exec -T app curl -fsS http://127.0.0.1:8080/health >/tmp/nams-health.json 2>/dev/null; then READY=1; break; fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "Health wait: $((i*5/60)) minute(s)"
    docker compose ps || true
    docker compose logs --tail=25 app chromium lightpanda || true
  fi
  sleep 5
done
[ "$READY" -eq 1 ] || { echo "Application did not become healthy." >&2; exit 3; }

cat > /usr/local/bin/nams-v5-status <<'STATUSCMD'
#!/usr/bin/env bash
cd /opt/nams-v5 && docker compose ps && echo && docker compose logs --tail=160 app caddy chromium lightpanda ollama
STATUSCMD
chmod +x /usr/local/bin/nams-v5-status
cat > /usr/local/bin/nams-v5-token <<'TOKENCMD'
#!/usr/bin/env bash
awk -F= '/^ADMIN_TOKEN=/{print substr($0,index($0,"=")+1);exit}' /opt/nams-v5/.env
TOKENCMD
chmod +x /usr/local/bin/nams-v5-token

curl -fsS -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1/run/discovery >/dev/null || true
cat /tmp/nams-health.json
printf '%s\n' "$TOKEN" > /var/lib/nams-v5-dashboard-token
chmod 600 /var/lib/nams-v5-dashboard-token
echo SUCCESS > "$STATUS"
echo "NAMS_FRESH_READY"
echo "TOKEN=$TOKEN"
echo "DOMAIN=$DOMAIN"
echo "Completed at $(date -Is)"
