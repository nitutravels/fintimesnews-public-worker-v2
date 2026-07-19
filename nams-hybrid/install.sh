#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/nams-hybrid
MODEL=${OLLAMA_MODEL:-gemma3:1b}
PUBLIC_IP=${PUBLIC_IP:-161.118.187.93}

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

trap 'echo "Installation failed at line $LINENO. Check: cd $APP_DIR && docker compose logs --tail=150" >&2' ERR

. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) echo "This installer supports Ubuntu/Debian only."; exit 1;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg openssl

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<DOCKERREPO
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKERREPO
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

mkdir -p "$APP_DIR" "$APP_DIR/agent" "$APP_DIR/data" "$APP_DIR/config"
chown -R 1000:1000 "$APP_DIR/data"
cd "$APP_DIR"

TOKEN=$(openssl rand -hex 24)
cat >.env <<ENV
TZ=Asia/Kolkata
DASHBOARD_PORT=80
ADMIN_TOKEN=$TOKEN
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_MODEL=$MODEL
LIGHTPANDA_CDP=ws://lightpanda:9222
BUSINESS_NAME=Nitu Travels
BUSINESS_WEBSITE=https://www.nitutravels.in/
TARGET_PAGE=https://www.nitutravels.in/bus-rental-delhi.html
BUSINESS_EMAIL=nitutravels@gmail.com
BUSINESS_PHONE=+91 98188 37830
BUSINESS_WHATSAPP=+91 89010 66699
BUSINESS_ADDRESS=216, A/5 Gautam Nagar, New Delhi, Delhi 110049
SERVICE_FOCUS=bus on hire in Delhi NCR
MAX_DAILY_DISCOVERY=10
MAX_DAILY_SUBMISSIONS=2
AUTO_SUBMIT=true
AUTO_SEND_EMAIL=false
SMTP_HOST=smtp.gmail.com
SMTP_PORT=465
SMTP_USER=
SMTP_APP_PASSWORD=
CRON_DISCOVERY=0 9 * * *
CRON_SUBMIT=0 12 * * *
ENV
chmod 600 .env

cat >docker-compose.yml <<'YAML'
services:
  lightpanda:
    image: lightpanda/browser:nightly
    command: ["serve","--obey-robots","--host","0.0.0.0","--advertise-host","lightpanda","--port","9222","--cdp-max-connections","2","--http-max-concurrent","4","--http-max-host-open","2"]
    restart: unless-stopped
    expose: ["9222"]
  ollama:
    image: ollama/ollama:latest
    restart: unless-stopped
    volumes: ["ollama_data:/root/.ollama"]
    expose: ["11434"]
  agent:
    build: ./agent
    restart: unless-stopped
    depends_on: [lightpanda, ollama]
    env_file: .env
    ports: ["${DASHBOARD_PORT:-80}:8080"]
    volumes:
      - ./data:/app/data
      - ./config:/app/config:ro
volumes:
  ollama_data:
YAML

cat >agent/Dockerfile <<'DOCKERFILE'
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY index.js ./
RUN mkdir -p /app/data /app/config
USER node
EXPOSE 8080
CMD ["node","index.js"]
DOCKERFILE

cat >agent/package.json <<'JSON'
{
  "name":"nams-hybrid-agent",
  "version":"1.1.0",
  "type":"module",
  "dependencies":{
    "express":"^5.1.0",
    "node-cron":"^4.2.1",
    "nodemailer":"^7.0.3",
    "playwright-core":"1.61.0",
    "robots-parser":"^3.0.1"
  }
}
JSON

cat >config/seeds.json <<'JSON'
[
  {"name":"Google Business Profile help","url":"https://support.google.com/business/","category":"local citation reference","enabled":false},
  {"name":"Replace with a permitted editorial opportunity","url":"https://example.com/","category":"travel editorial","enabled":false}
]
JSON

cat >agent/index.js <<'NODE'
import express from 'express';
import cron from 'node-cron';
import { chromium } from 'playwright-core';
import robotsParser from 'robots-parser';
import nodemailer from 'nodemailer';
import fs from 'node:fs';

const DATA='/app/data/state.json';
const now=()=>new Date().toISOString();
function initial(){return {opportunities:[],articles:[],actions:[],checkpoints:[],logs:[]}}
function load(){try{return JSON.parse(fs.readFileSync(DATA,'utf8'))}catch{return initial()}}
function save(s){fs.writeFileSync(DATA,JSON.stringify(s,null,2))}
function log(level,message,details={}){const s=load();s.logs.unshift({id:crypto.randomUUID(),level,message,details,at:now()});s.logs=s.logs.slice(0,200);save(s)}
const lp=process.env.LIGHTPANDA_CDP||'ws://lightpanda:9222';
const ua='NAMSAuthorityBuilder/4.0 (+https://www.nitutravels.in/)';

async function inspect(url){
  const u=new URL(url), robotsUrl=`${u.protocol}//${u.host}/robots.txt`;
  let rt=''; try{rt=await (await fetch(robotsUrl,{signal:AbortSignal.timeout(10000)})).text()}catch{}
  if(!robotsParser(robotsUrl,rt).isAllowed(url,ua))return {allowed:false,reason:'robots_disallow'};
  const b=await chromium.connectOverCDP(lp), c=await b.newContext({userAgent:ua}), p=await c.newPage();
  try{
    await p.goto(url,{waitUntil:'domcontentloaded',timeout:25000});
    const html=await p.content(), text=(await p.locator('body').innerText()).replace(/\s+/g,' ').slice(0,20000);
    const bad=/(buy backlinks|paid link|link exchange|private blog network|guaranteed dofollow)/i.test(text);
    const prohibited=/(automated submissions? (are|is) prohibited|no bots|automated access prohibited)/i.test(text);
    const pay=/(payment required|checkout|buy now)/i.test(text);
    const editorial=/(write for us|submit (an )?article|contribute|guest post|editorial guidelines)/i.test(text);
    const captcha=/(captcha|recaptcha|hcaptcha|turnstile)/i.test(html);
    const otp=/(one.?time password|verification code|send otp)/i.test(text);
    const links=await p.locator('a').evaluateAll(as=>as.map(a=>({t:(a.textContent||'').trim(),h:a.href})));
    const sub=links.find(x=>/(submit|contribut|write-for-us|guest-post)/i.test(x.t+' '+x.h));
    const emails=[...new Set((html.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/ig)||[]))].filter(e=>!/(example|sentry|wixpress|cloudflare)/i.test(e));
    return {allowed:!bad&&!prohibited&&!pay,reason:bad?'spam_or_paid':prohibited?'automation_prohibited':pay?'payment_required':'ok',title:await p.title(),editorial,captcha,otp,submissionUrl:sub?.h||null,email:emails[0]||null,context:text.slice(0,7000)};
  }finally{await p.close();await c.close();await b.close()}
}

async function generate(op){
 const prompt=`Create one original, practical article for this publication. Publication context: ${op.context}. Business facts only: Nitu Travels; service focus ${process.env.SERVICE_FOCUS}; target ${process.env.TARGET_PAGE}. Never invent awards, fleet size, statistics, certifications, prices, reviews or safety claims. One natural branded link maximum. Return strict JSON {"title":"...","body":"markdown","anchor":"..."}.`;
 const r=await fetch(`${process.env.OLLAMA_BASE_URL}/api/generate`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({model:process.env.OLLAMA_MODEL,prompt,stream:false,format:'json'}),signal:AbortSignal.timeout(180000)});
 if(!r.ok)throw new Error(`Ollama ${r.status}`);return JSON.parse((await r.json()).response)
}

async function submit(url,a){
 const b=await chromium.connectOverCDP(lp),c=await b.newContext({userAgent:ua}),p=await c.newPage();
 try{
  await p.goto(url,{waitUntil:'domcontentloaded',timeout:25000});const html=await p.content();
  if(/(captcha|recaptcha|hcaptcha|turnstile)/i.test(html))return {status:'checkpoint',type:'captcha',url};
  const groups=[
   [['name','author'],process.env.BUSINESS_NAME], [['email'],process.env.BUSINESS_EMAIL],
   [['website','url'],process.env.BUSINESS_WEBSITE], [['title','headline','subject'],a.title],
   [['article','content','body','message','description'],a.body]
  ];
  for(const [keys,val] of groups){const es=p.locator('input,textarea');for(let i=0;i<await es.count();i++){const e=es.nth(i);const m=((await e.getAttribute('name'))||'')+' '+((await e.getAttribute('id'))||'')+' '+((await e.getAttribute('placeholder'))||'');if(keys.some(k=>m.toLowerCase().includes(k))){try{await e.fill(val);break}catch{}}}}
  const btn=p.getByRole('button',{name:/submit|send|publish|continue/i}).first();if(await btn.count()===0)return {status:'unsupported',url};
  await btn.click();await p.waitForTimeout(3000);return {status:'submitted',url:p.url(),title:await p.title()};
 }finally{await p.close();await c.close();await b.close()}
}

async function email(to,a){
 if(process.env.AUTO_SEND_EMAIL!=='true')return {status:'email_disabled'};
 if(!process.env.SMTP_USER||!process.env.SMTP_APP_PASSWORD)return {status:'smtp_not_configured'};
 const tx=nodemailer.createTransport({host:process.env.SMTP_HOST||'smtp.gmail.com',port:Number(process.env.SMTP_PORT||465),secure:true,auth:{user:process.env.SMTP_USER,pass:process.env.SMTP_APP_PASSWORD}});
 const info=await tx.sendMail({from:`Nitu Travels <${process.env.SMTP_USER}>`,to,subject:`Original article proposal: ${a.title}`,text:`Hello,\n\nI prepared an original article for your readers.\n\n${a.body}\n\nRegards,\nNitu Travels`});return {status:'sent',messageId:info.messageId}
}

async function seed(){const s=load(), seeds=JSON.parse(fs.readFileSync('/app/config/seeds.json','utf8')).filter(x=>x.enabled!==false);for(const x of seeds.slice(0,Number(process.env.MAX_DAILY_DISCOVERY||10))){try{const d=new URL(x.url).hostname.replace(/^www\./,'');if(!s.opportunities.some(o=>o.domain===d))s.opportunities.push({id:crypto.randomUUID(),domain:d,url:x.url,name:x.name,category:x.category,status:'discovered',createdAt:now()})}catch(e){log('error','invalid seed',{x,error:String(e)})}}save(s)}
async function qualify(){const s=load();for(const o of s.opportunities.filter(x=>x.status==='discovered').slice(0,10)){try{const x=await inspect(o.url),score=(x.allowed?40:0)+(x.editorial?35:0)+(x.email?15:0)+(x.submissionUrl?10:0);Object.assign(o,{title:x.title,score,submissionUrl:x.submissionUrl,email:x.email,status:x.allowed&&score>=55?'qualified':'unsuitable',policy:x.reason,updatedAt:now()})}catch(e){o.status='error';log('error','qualification failed',{id:o.id,error:String(e)})}save(s)}}
async function cycle(){await seed();await qualify();const s=load();for(const o of s.opportunities.filter(x=>x.status==='qualified').slice(0,Number(process.env.MAX_DAILY_SUBMISSIONS||2))){try{const x=await inspect(o.url),a=await generate(x),article={id:crypto.randomUUID(),opportunityId:o.id,...a,createdAt:now()};s.articles.push(article);let r=o.submissionUrl&&process.env.AUTO_SUBMIT==='true'?await submit(o.submissionUrl,a):(o.email?await email(o.email,a):{status:'no_channel'});if(r.status==='checkpoint')s.checkpoints.push({id:crypto.randomUUID(),opportunityId:o.id,type:r.type,url:r.url,status:'open',createdAt:now()});s.actions.unshift({id:crypto.randomUUID(),opportunityId:o.id,articleId:article.id,type:o.submissionUrl?'form':'email',...r,createdAt:now()});o.status=r.status;o.updatedAt=now()}catch(e){o.status='error';log('error','cycle failed',{id:o.id,error:String(e)})}save(s)}}

const app=express();app.use(express.json());
app.use((req,res,next)=>{if(req.path==='/health')return next();const t=req.headers.authorization?.replace(/^Bearer /,'')||req.query.token;if(t!==process.env.ADMIN_TOKEN)return res.status(401).send('Unauthorized');next()});
app.get('/health',(req,res)=>res.json({ok:true}));
app.get('/api/status',(req,res)=>res.json(load()));
app.post('/api/run',async(req,res)=>{cycle().then(()=>{}).catch(e=>log('error','manual cycle',{error:String(e)}));res.json({ok:true,message:'Cycle started'})});
app.post('/api/checkpoints/:id/complete',(req,res)=>{const s=load(),c=s.checkpoints.find(x=>x.id===req.params.id);if(c){c.status='completed';c.answer=req.body?.answer||'';c.completedAt=now();save(s)}res.json({ok:!!c})});
app.get('/',(req,res)=>{const s=load(), counts=Object.entries(s.opportunities.reduce((a,o)=>(a[o.status]=(a[o.status]||0)+1,a),{}));res.type('html').send(`<!doctype html><meta name=viewport content='width=device-width'><style>body{font-family:system-ui;max-width:900px;margin:auto;padding:20px}button{padding:12px}pre{background:#f4f4f4;padding:12px;white-space:pre-wrap}</style><h1>NAMS Hybrid Agent</h1><p>${counts.map(x=>x.join(': ')).join(' | ')||'No opportunities yet'}</p><button onclick="fetch('/api/run?token=${process.env.ADMIN_TOKEN}',{method:'POST'}).then(()=>alert('Cycle started'))">Run cycle now</button><h2>Checkpoints</h2><pre>${JSON.stringify(s.checkpoints.filter(x=>x.status==='open'),null,2)}</pre><h2>Actions</h2><pre>${JSON.stringify(s.actions.slice(0,20),null,2)}</pre><h2>Logs</h2><pre>${JSON.stringify(s.logs.slice(0,20),null,2)}</pre>`)});
cron.schedule(process.env.CRON_DISCOVERY||'0 9 * * *',async()=>{await seed();await qualify()},{timezone:process.env.TZ||'Asia/Kolkata'});
cron.schedule(process.env.CRON_SUBMIT||'0 12 * * *',cycle,{timezone:process.env.TZ||'Asia/Kolkata'});
app.listen(8080,'0.0.0',()=>console.log('NAMS ready'));
NODE

OLD=$(docker ps --filter publish=80 --format '{{.ID}}' || true)
[ -z "$OLD" ] || docker stop $OLD

docker compose pull lightpanda ollama
docker compose build --no-cache agent
docker compose up -d

echo "Downloading local model $MODEL (this can take several minutes)..."
docker compose exec -T ollama ollama pull "$MODEL"

for i in $(seq 1 40); do
  if curl -fsS http://127.0.0.1/health >/dev/null; then break; fi
  sleep 3
done
curl -fsS http://127.0.0.1/health >/dev/null

cat >/usr/local/bin/nams-status <<'STATUS'
#!/usr/bin/env bash
cd /opt/nams-hybrid && docker compose ps && docker compose logs --tail=80
STATUS
chmod +x /usr/local/bin/nams-status

echo
echo "INSTALLATION COMPLETE"
echo "Dashboard: http://${PUBLIC_IP}/?token=${TOKEN}"
echo "Token: ${TOKEN}"
echo "Status command: sudo nams-status"
echo "Configuration: ${APP_DIR}/config/seeds.json"
echo
