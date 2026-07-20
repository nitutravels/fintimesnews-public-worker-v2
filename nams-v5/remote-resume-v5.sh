#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/nams-v5
LOG=/var/log/nams-v5-resume.log
STATUS=/var/lib/nams-v5-resume.status
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
MODEL="${OLLAMA_MODEL:-gemma3:1b}"

mkdir -p /var/lib
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; echo "FAILED:$rc" > "$STATUS"; echo "NAMS v5 resume failed with exit code $rc"; exit $rc' ERR

echo RUNNING > "$STATUS"
echo "NAMS v5 resumable repair started at $(date -Is)"

if [ ! -d "$APP_DIR" ] || [ ! -f "$APP_DIR/docker-compose.yml" ]; then
  echo "Missing $APP_DIR deployment files. Re-running the complete installer first."
  curl -fL --retry 5 --connect-timeout 20 \
    https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/nams-hybrid-installer/nams-v5/install-v5.sh \
    -o /tmp/nams-install-v5.sh
  chmod +x /tmp/nams-install-v5.sh
  NAMS_DOMAIN="$DOMAIN" bash /tmp/nams-install-v5.sh
fi

if [ ! -f "$APP_DIR/.env" ]; then
  echo "Missing $APP_DIR/.env; cannot recover the dashboard configuration." >&2
  exit 2
fi

# The ARM instance has 8 GB RAM. A persistent 4 GB swap file prevents native
# Node modules and Chromium package layers from being killed during builds.
if ! swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  echo "Creating 4 GB build swap..."
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  if ! fallocate -l 4G /swapfile; then
    dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -h

echo "Disk space before build:"
df -h /

systemctl enable --now docker
cd "$APP_DIR"

# Clear only stale build cache and stopped containers. Persistent application,
# Chromium profile, Caddy and Ollama volumes are preserved.
docker container prune -f || true
docker builder prune -af || true

echo "Pulling base services..."
docker compose pull caddy lightpanda ollama

echo "Building Chromium alone with plain, persistent logs..."
COMPOSE_PARALLEL_LIMIT=1 docker compose --progress plain build chromium

echo "Building the NAMS application alone..."
COMPOSE_PARALLEL_LIMIT=1 docker compose --progress plain build app

echo "Starting replacement services..."
docker compose up -d --remove-orphans

echo "Container state after startup:"
docker compose ps

# Wait for Ollama before checking/downloading the free local model.
for _ in $(seq 1 60); do
  if docker compose exec -T ollama ollama list >/tmp/ollama-list.txt 2>/dev/null; then break; fi
  sleep 5
done
if ! grep -q "^${MODEL}[[:space:]]" /tmp/ollama-list.txt 2>/dev/null; then
  echo "Downloading local AI model $MODEL..."
  docker compose exec -T ollama ollama pull "$MODEL"
else
  echo "Local model $MODEL is already present."
fi

echo "Waiting for NAMS application health..."
READY=0
for i in $(seq 1 180); do
  if docker compose exec -T app curl -fsS http://127.0.0.1:8080/health >/tmp/nams-health.json 2>/dev/null; then
    READY=1
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "Still waiting: $((i*5/60)) minutes"
    docker compose ps || true
    docker compose logs --tail=30 app chromium lightpanda || true
  fi
  sleep 5
done

if [ "$READY" -ne 1 ]; then
  echo "Application did not become healthy." >&2
  docker compose ps || true
  docker compose logs --tail=200 app caddy chromium lightpanda ollama || true
  exit 3
fi

TOKEN="$(awk -F= '$1=="ADMIN_TOKEN"{print substr($0,index($0,"=")+1);exit}' "$APP_DIR/.env")"
if [ -z "$TOKEN" ]; then
  echo "ADMIN_TOKEN is missing from $APP_DIR/.env" >&2
  exit 4
fi

# Trigger the first qualification pass directly against the application.
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/run/discovery >/dev/null || true

cat /tmp/nams-health.json
echo SUCCESS > "$STATUS"
echo "NAMS_V5_READY"
echo "DOMAIN=$DOMAIN"
echo "TOKEN=$TOKEN"
echo "DASHBOARD=https://$DOMAIN/?token=$TOKEN"
echo "BROWSER=https://$DOMAIN/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify"
echo "Completed at $(date -Is)"
