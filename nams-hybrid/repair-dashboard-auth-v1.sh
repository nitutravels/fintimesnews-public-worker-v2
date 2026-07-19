#!/usr/bin/env bash
set -Eeuo pipefail

IP="${NAMS_IP:-130.210.15.29}"
DOMAIN="${NAMS_DOMAIN:-marketing.nitutravels.in}"
KEY="${NAMS_SSH_KEY:-$HOME/nams.key}"
REMOTE_SCRIPT="/tmp/nams-repair-auth.sh"

if [ ! -f "$KEY" ]; then
  KEY="$HOME/nams-dedicated.key"
fi
if [ ! -f "$KEY" ]; then
  KEY="$(find "$HOME" -maxdepth 3 -type f \( -name 'nams.key' -o -name 'nams-dedicated.key' \) -print -quit 2>/dev/null || true)"
fi
if [ -z "${KEY:-}" ] || [ ! -f "$KEY" ]; then
  echo "SSH key not found. Upload nams.key or nams-dedicated.key to Oracle Cloud Shell." >&2
  exit 1
fi
chmod 600 "$KEY"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

cat > /tmp/nams-repair-auth-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
APP=/opt/nams-hybrid
cd "$APP"

TOKEN="$(openssl rand -hex 24)"

if grep -q '^ADMIN_TOKEN=' .env; then
  sed -i "s/^ADMIN_TOKEN=.*/ADMIN_TOKEN=$TOKEN/" .env
else
  printf '\nADMIN_TOKEN=%s\n' "$TOKEN" >> .env
fi
chmod 600 .env

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/nams-hybrid/agent/index.js')
s=p.read_text()
old="app.use((req,res,next)=>{if(req.path==='/health')return next();const t=req.headers.authorization?.replace(/^Bearer /,'')||req.query.token;if(t!==process.env.ADMIN_TOKEN)return res.status(401).send('Unauthorized');next()});"
new=r'''app.use((req,res,next)=>{
 if(req.path==='/health') return next();
 const cookies=Object.fromEntries((req.headers.cookie||'').split(';').map(x=>x.trim()).filter(Boolean).map(x=>{const i=x.indexOf('=');return i<0?[x,'']:[x.slice(0,i),decodeURIComponent(x.slice(i+1))]}));
 const bearer=req.headers.authorization?.replace(/^Bearer /,'');
 const supplied=req.query.token||bearer||cookies.nams_token;
 if(supplied!==process.env.ADMIN_TOKEN){
  return res.status(401).type('html').send(`<!doctype html><meta name="viewport" content="width=device-width"><style>body{font-family:system-ui;max-width:420px;margin:60px auto;padding:20px}input,button{width:100%;box-sizing:border-box;padding:14px;margin:8px 0}button{cursor:pointer}</style><h1>NAMS Login</h1><p>Enter the dashboard token printed by the repair command.</p><form method="get"><input name="token" type="password" autocomplete="current-password" required><button type="submit">Open dashboard</button></form>`);
 }
 if(req.query.token===process.env.ADMIN_TOKEN){
  res.setHeader('Set-Cookie',`nams_token=${encodeURIComponent(process.env.ADMIN_TOKEN)}; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax`);
  return res.redirect('/');
 }
 next();
});'''
if old not in s:
    raise SystemExit('Expected authentication middleware was not found; no file was changed.')
p.write_text(s.replace(old,new))
PY

docker compose build --no-cache agent
docker compose up -d --force-recreate agent

for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1/health >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS http://127.0.0.1/health >/dev/null

COOKIE=/tmp/nams-cookie.txt
rm -f "$COOKIE"
curl -fsS -c "$COOKIE" -L "http://127.0.0.1/?token=$TOKEN" | grep -q 'NAMS Hybrid Agent'

printf '%s' "$TOKEN" > /opt/nams-hybrid/dashboard-token.txt
chmod 600 /opt/nams-hybrid/dashboard-token.txt

echo "AUTH_REPAIR_COMPLETE"
echo "TOKEN=$TOKEN"
REMOTE

scp -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new /tmp/nams-repair-auth-remote.sh "ubuntu@$IP:$REMOTE_SCRIPT" >/dev/null
RESULT="$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "ubuntu@$IP" "sudo bash $REMOTE_SCRIPT")"
printf '%s\n' "$RESULT"
TOKEN="$(printf '%s\n' "$RESULT" | sed -n 's/^TOKEN=//p' | tail -1)"
if [ -z "$TOKEN" ]; then
  echo "Repair ran but did not return a token." >&2
  exit 1
fi

echo
echo "DASHBOARD REPAIRED AND VERIFIED"
echo "Open: http://$DOMAIN/"
echo "Token: $TOKEN"
echo "Direct one-time login: http://$DOMAIN/?token=$TOKEN"
echo
echo "After the first successful login, the browser keeps an authentication cookie for 30 days."
