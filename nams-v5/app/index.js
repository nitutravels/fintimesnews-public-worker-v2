import express from 'express';
import cookieParser from 'cookie-parser';
import Database from 'better-sqlite3';
import cron from 'node-cron';
import nodemailer from 'nodemailer';
import robotsParser from 'robots-parser';
import { chromium } from 'playwright-core';
import { createProxyMiddleware } from 'http-proxy-middleware';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const app = express();
app.use(express.json({ limit: '3mb' }));
app.use(express.urlencoded({ extended: true, limit: '3mb' }));
app.use(cookieParser());

const DOMAIN = process.env.NAMS_DOMAIN || 'seo.nitutravels.in';
const TOKEN = process.env.ADMIN_TOKEN;
const DATA_DIR = '/app/data';
const DB_PATH = `${DATA_DIR}/nams-v5.sqlite`;
const CATALOG_PATH = '/app/config/catalog.json';
const ASSET_DIR = '/app/assets';
const LP_CDP = process.env.LIGHTPANDA_CDP || 'http://lightpanda:9222';
const CHROME_CDP = process.env.CHROMIUM_CDP || 'http://chromium:9223';
const OLLAMA = process.env.OLLAMA_BASE_URL || 'http://ollama:11434';
const MODEL = process.env.OLLAMA_MODEL || 'gemma3:1b';
const USER_AGENT = `NAMSAuthorityAgent/5.0 (+https://${DOMAIN}/)`;

fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(ASSET_DIR, { recursive: true });

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.exec(`
CREATE TABLE IF NOT EXISTS opportunities(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 name TEXT NOT NULL,
 domain TEXT NOT NULL UNIQUE,
 landing_url TEXT NOT NULL,
 submission_url TEXT,
 category TEXT,
 mode TEXT DEFAULT 'browser',
 priority INTEGER DEFAULT 50,
 expected_verification INTEGER DEFAULT 0,
 policy_status TEXT DEFAULT 'unchecked',
 status TEXT DEFAULT 'discovered',
 score INTEGER DEFAULT 0,
 public_email TEXT,
 notes TEXT,
 last_error TEXT,
 created_at TEXT DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS articles(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 opportunity_id INTEGER NOT NULL,
 title TEXT NOT NULL,
 body TEXT NOT NULL,
 anchor TEXT,
 target_url TEXT,
 asset_path TEXT,
 status TEXT DEFAULT 'generated',
 created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS submissions(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 opportunity_id INTEGER NOT NULL,
 article_id INTEGER,
 status TEXT NOT NULL,
 proof_url TEXT,
 live_url TEXT,
 link_rel TEXT,
 evidence TEXT,
 error TEXT,
 submitted_at TEXT,
 checked_at TEXT,
 created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS checkpoints(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 opportunity_id INTEGER NOT NULL,
 type TEXT NOT NULL,
 prompt TEXT NOT NULL,
 url TEXT,
 status TEXT DEFAULT 'open',
 created_at TEXT DEFAULT CURRENT_TIMESTAMP,
 completed_at TEXT
);
CREATE TABLE IF NOT EXISTS credentials(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 domain TEXT UNIQUE,
 username TEXT,
 password TEXT,
 created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS runs(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 kind TEXT,
 status TEXT,
 summary TEXT,
 started_at TEXT DEFAULT CURRENT_TIMESTAMP,
 finished_at TEXT
);
CREATE TABLE IF NOT EXISTS logs(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 level TEXT,
 message TEXT,
 details TEXT,
 created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
`);

const q = {
 counts: db.prepare(`SELECT status, COUNT(*) n FROM opportunities GROUP BY status`),
 openCheckpoints: db.prepare(`SELECT c.*,o.name,o.domain FROM checkpoints c JOIN opportunities o ON o.id=c.opportunity_id WHERE c.status='open' ORDER BY c.id DESC`),
 recentOpps: db.prepare(`SELECT * FROM opportunities ORDER BY priority DESC,id DESC LIMIT 30`),
 recentSubs: db.prepare(`SELECT s.*,o.name,o.domain,a.title FROM submissions s JOIN opportunities o ON o.id=s.opportunity_id LEFT JOIN articles a ON a.id=s.article_id ORDER BY s.id DESC LIMIT 30`),
 recentRuns: db.prepare(`SELECT * FROM runs ORDER BY id DESC LIMIT 20`),
 recentLogs: db.prepare(`SELECT * FROM logs ORDER BY id DESC LIMIT 30`),
 oppById: db.prepare(`SELECT * FROM opportunities WHERE id=?`),
 articleForOpp: db.prepare(`SELECT * FROM articles WHERE opportunity_id=? ORDER BY id DESC LIMIT 1`),
 openCheckpointForOpp: db.prepare(`SELECT * FROM checkpoints WHERE opportunity_id=? AND status='open' ORDER BY id DESC LIMIT 1`)
};

function log(level, message, details = {}) {
  db.prepare(`INSERT INTO logs(level,message,details) VALUES(?,?,?)`).run(level, message, JSON.stringify(details));
}
function esc(v = '') { return String(v).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function fmt(v) { return v ? new Date(v).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) : ''; }
function statusClass(s='') { return `s-${s.replace(/[^a-z0-9_-]/gi,'-')}`; }
function createCheckpoint(oppId, type, prompt, url) {
  const existing = q.openCheckpointForOpp.get(oppId);
  if (existing) return existing.id;
  return db.prepare(`INSERT INTO checkpoints(opportunity_id,type,prompt,url) VALUES(?,?,?,?)`).run(oppId,type,prompt,url).lastInsertRowid;
}
function closeCheckpoints(oppId) {
  db.prepare(`UPDATE checkpoints SET status='completed',completed_at=CURRENT_TIMESTAMP WHERE opportunity_id=? AND status='open'`).run(oppId);
}
function setOpp(id, fields) {
  const keys = Object.keys(fields);
  if (!keys.length) return;
  db.prepare(`UPDATE opportunities SET ${keys.map(k=>`${k}=?`).join(',')},updated_at=CURRENT_TIMESTAMP WHERE id=?`).run(...keys.map(k=>fields[k]),id);
}
function beginRun(kind) { return db.prepare(`INSERT INTO runs(kind,status) VALUES(?,'running')`).run(kind).lastInsertRowid; }
function endRun(id,status,summary='') { db.prepare(`UPDATE runs SET status=?,summary=?,finished_at=CURRENT_TIMESTAMP WHERE id=?`).run(status,summary,id); }

function syncCatalog() {
  const catalog = JSON.parse(fs.readFileSync(CATALOG_PATH,'utf8'));
  const stmt = db.prepare(`INSERT INTO opportunities(name,domain,landing_url,category,mode,priority,expected_verification,notes)
    VALUES(@name,@domain,@landing_url,@category,@mode,@priority,@expected_verification,@notes)
    ON CONFLICT(domain) DO UPDATE SET name=excluded.name,landing_url=excluded.landing_url,category=excluded.category,mode=excluded.mode,priority=excluded.priority,expected_verification=excluded.expected_verification,notes=excluded.notes`);
  const tx = db.transaction(rows => rows.forEach(r => stmt.run({...r,expected_verification:r.expected_verification?1:0})));
  tx(catalog);
  return catalog.length;
}
syncCatalog();

let lpBrowser;
let chromeBrowser;
async function getLightpanda() {
  if (!lpBrowser || !lpBrowser.isConnected()) lpBrowser = await chromium.connectOverCDP(LP_CDP);
  return lpBrowser;
}
async function getChromium() {
  if (!chromeBrowser || !chromeBrowser.isConnected()) chromeBrowser = await chromium.connectOverCDP(CHROME_CDP);
  return chromeBrowser;
}
async function chromiumContext() {
  const b = await getChromium();
  return b.contexts()[0] || await b.newContext({ userAgent: USER_AGENT });
}

async function inspectOpportunity(opp) {
  const url = opp.landing_url;
  const u = new URL(url);
  const robotsUrl = `${u.protocol}//${u.host}/robots.txt`;
  let robotsText = '';
  try { robotsText = await (await fetch(robotsUrl, { signal: AbortSignal.timeout(12000) })).text(); } catch {}
  const robots = robotsParser(robotsUrl, robotsText);
  if (!robots.isAllowed(url, USER_AGENT)) return { allowed:false, reason:'robots_disallow', score:0 };

  const browser = await getLightpanda();
  const context = await browser.newContext({ userAgent: USER_AGENT });
  const page = await context.newPage();
  try {
    await page.goto(url, { waitUntil:'domcontentloaded', timeout:30000 });
    const html = await page.content();
    const text = (await page.locator('body').innerText().catch(()=>'' )).replace(/\s+/g,' ').slice(0,30000);
    const links = await page.locator('a').evaluateAll(as => as.map(a => ({ text:(a.textContent||'').trim(), href:a.href })));
    const emails = [...new Set((html.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/ig)||[]))].filter(e=>!/(example|sentry|cloudflare|wixpress)/i.test(e));
    const paid = /(payment required|paid placement|buy backlinks|pricing for guest post|sponsored post fee|checkout)/i.test(text);
    const exchange = /(link exchange|article exchange|reciprocal link|mutual promotion)/i.test(text);
    const prohibited = /(automated submissions? (are|is) prohibited|automated access prohibited|no bots|do not use automated)/i.test(text);
    const aiRejected = /(AI content (is )?(not accepted|rejected|prohibited)|do not submit AI|AI-generated content is rejected)/i.test(text);
    const editorial = /(write for us|guest post|submit (an )?article|contribute|author bio|editorial guidelines)/i.test(text);
    const listing = /(claim your (business|listing)|add your business|add a place|manage your listing|business connect)/i.test(text);
    const captcha = /(recaptcha|hcaptcha|turnstile|captcha)/i.test(html);
    const otp = /(one.?time password|verification code|send otp|verify phone)/i.test(text);
    const login = /(sign in|log in|create account|register)/i.test(text);
    const candidate = links.find(x => /(get started|claim|add (a )?(business|place)|manage listing|sign up|register|submit|contribut|write for us)/i.test(`${x.text} ${x.href}`));
    let score = 20;
    if (listing || editorial) score += 35;
    if (candidate) score += 15;
    if (emails.length) score += 10;
    if (opp.category?.toLowerCase().includes('citation')) score += 15;
    if (paid || exchange || prohibited || aiRejected) score = 0;
    return {
      allowed: score >= 50,
      reason: paid?'paid_required':exchange?'link_exchange':prohibited?'automation_prohibited':aiRejected?'ai_content_prohibited':'ok',
      score, title:await page.title(), submissionUrl:candidate?.href || opp.landing_url,
      email:emails[0] || null, captcha, otp, login, editorial, listing,
      text:text.slice(0,9000)
    };
  } finally {
    await page.close().catch(()=>{});
    await context.close().catch(()=>{});
  }
}

async function runDiscoveryAndQualification() {
  const runId = beginRun('discovery_qualification');
  let qualified=0, unsuitable=0, errors=0;
  try {
    syncCatalog();
    const rows = db.prepare(`SELECT * FROM opportunities WHERE status IN ('discovered','error','unsuitable') ORDER BY priority DESC LIMIT ?`).all(Number(process.env.MAX_DAILY_DISCOVERY||10));
    for (const opp of rows) {
      try {
        const x = await inspectOpportunity(opp);
        const status = x.allowed ? 'qualified' : 'unsuitable';
        setOpp(opp.id,{submission_url:x.submissionUrl||opp.landing_url,public_email:x.email,policy_status:x.reason,score:x.score,status,last_error:null});
        status==='qualified'?qualified++:unsuitable++;
      } catch (e) {
        errors++; setOpp(opp.id,{status:'error',last_error:String(e)}); log('error','Opportunity inspection failed',{id:opp.id,error:String(e)});
      }
    }
    endRun(runId,'completed',`${qualified} qualified, ${unsuitable} unsuitable, ${errors} errors`);
  } catch(e) { endRun(runId,'failed',String(e)); throw e; }
}

async function generateArticle(opp, inspection) {
  const existing = q.articleForOpp.get(opp.id);
  if (existing) return existing;
  const prompt = `You are preparing an original editorial contribution for a legitimate Delhi passenger transport business.
Publication or directory: ${opp.name} (${opp.domain})
Category: ${opp.category}
Page context: ${inspection.text || ''}
Business facts only:
- Nitu Travels
- Website: https://www.nitutravels.in/
- Relevant page: https://www.nitutravels.in/bus-rental-delhi.html
- Address: 216, A/5 Gautam Nagar, New Delhi, Delhi 110049
- Phone: +91 98188 37830
- WhatsApp: +91 89010 66699
- Service focus: bus on hire in Delhi NCR
Rules:
- Never invent awards, years, fleet size, certifications, statistics, reviews, prices, client names or safety claims.
- Create useful practical information independent of the link.
- No keyword stuffing.
- Mention Nitu Travels at most once.
- Use at most one natural branded or descriptive link suggestion.
- Return strict JSON: {"title":"...","body":"markdown, 800-1200 words for editorial or 120-250 words for listing description","anchor":"..."}.`;
  const response = await fetch(`${OLLAMA}/api/generate`,{
    method:'POST',headers:{'content-type':'application/json'},
    body:JSON.stringify({model:MODEL,prompt,stream:false,format:'json'}),
    signal:AbortSignal.timeout(240000)
  });
  if (!response.ok) throw new Error(`Ollama returned ${response.status}`);
  const generated = JSON.parse((await response.json()).response);
  const assetName = `nitu-travels-${opp.id}.svg`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630"><rect width="1200" height="630" fill="#f6f7fb"/><rect x="70" y="70" width="1060" height="490" rx="32" fill="#ffffff" stroke="#d9dee8"/><text x="120" y="210" font-family="Arial,sans-serif" font-size="60" font-weight="700" fill="#172033">${esc(generated.title).slice(0,70)}</text><text x="120" y="430" font-family="Arial,sans-serif" font-size="34" fill="#176b5b">Nitu Travels · Delhi NCR group transport</text><text x="120" y="500" font-family="Arial,sans-serif" font-size="24" fill="#4d5666">Original informational contribution</text></svg>`;
  fs.writeFileSync(path.join(ASSET_DIR,assetName),svg);
  const id = db.prepare(`INSERT INTO articles(opportunity_id,title,body,anchor,target_url,asset_path) VALUES(?,?,?,?,?,?)`).run(opp.id,generated.title,generated.body,generated.anchor||'Nitu Travels','https://www.nitutravels.in/bus-rental-delhi.html',path.join(ASSET_DIR,assetName)).lastInsertRowid;
  return db.prepare(`SELECT * FROM articles WHERE id=?`).get(id);
}

function fieldMetadata(el) {
  return Promise.all(['name','id','placeholder','aria-label','type'].map(a=>el.getAttribute(a))).then(v=>v.filter(Boolean).join(' ').toLowerCase());
}
async function findPersistentPage(opp) {
  const context = await chromiumContext();
  const pages = context.pages();
  const match = pages.find(p => { try { return new URL(p.url()).hostname.includes(opp.domain.replace(/^www\./,'')); } catch { return false; } });
  return match || await context.newPage();
}
async function fillByKeys(page, selector, keys, value) {
  if (!value) return false;
  const els = page.locator(selector);
  for (let i=0;i<await els.count();i++) {
    const el = els.nth(i);
    const meta = await fieldMetadata(el);
    if (keys.some(k=>meta.includes(k))) {
      try { if (await el.isVisible()) { await el.fill(String(value)); return true; } } catch {}
    }
  }
  return false;
}
async function detectBlocker(page) {
  const html = await page.content();
  const text = (await page.locator('body').innerText().catch(()=>'' )).replace(/\s+/g,' ').slice(0,25000);
  if (/(recaptcha|hcaptcha|turnstile|captcha)/i.test(html)) return {type:'captcha',prompt:'Complete the CAPTCHA in the live browser, then tap Resume.'};
  if (/(enter otp|one.?time password|verification code|verify phone|code sent to)/i.test(text)) return {type:'otp',prompt:'Enter the phone or email verification code in the live browser, then tap Resume.'};
  if (/(scan (the )?qr|approve sign.?in|two.factor authentication|security key)/i.test(text)) return {type:'login_verification',prompt:'Complete the account verification in the live browser, then tap Resume.'};
  return null;
}
async function ensureCredential(domain) {
  let c = db.prepare(`SELECT * FROM credentials WHERE domain=?`).get(domain);
  if (!c) {
    const password = `Nt!${crypto.randomBytes(10).toString('base64url')}7`;
    db.prepare(`INSERT INTO credentials(domain,username,password) VALUES(?,?,?)`).run(domain,process.env.BUSINESS_EMAIL,password);
    c = db.prepare(`SELECT * FROM credentials WHERE domain=?`).get(domain);
  }
  return c;
}
async function fillForm(page, opp, article) {
  const cred = await ensureCredential(opp.domain);
  await fillByKeys(page,'input,textarea',['business name','company name','place name','organisation','organization'],process.env.BUSINESS_NAME);
  await fillByKeys(page,'input,textarea',['full name','contact name','author name'],process.env.CONTACT_NAME||'Ashu Grover');
  await fillByKeys(page,'input,textarea',['email'],process.env.BUSINESS_EMAIL);
  await fillByKeys(page,'input,textarea',['phone','mobile','telephone'],process.env.BUSINESS_PHONE);
  await fillByKeys(page,'input,textarea',['whatsapp'],process.env.BUSINESS_WHATSAPP);
  await fillByKeys(page,'input,textarea',['website','site url','business url'],process.env.BUSINESS_WEBSITE);
  await fillByKeys(page,'input,textarea',['address','street'],process.env.BUSINESS_ADDRESS);
  await fillByKeys(page,'input,textarea',['city'], 'New Delhi');
  await fillByKeys(page,'input,textarea',['state','province'], 'Delhi');
  await fillByKeys(page,'input,textarea',['postal','pincode','zip'], '110049');
  await fillByKeys(page,'input[type=password]',['password'],cred.password);
  await fillByKeys(page,'input,textarea',['title','headline','subject'],article.title);
  await fillByKeys(page,'textarea,input',['description','about','summary','message','article','content','body'],article.body);

  const editors = page.locator('[contenteditable="true"]');
  if (await editors.count()) {
    for(let i=0;i<await editors.count();i++) { const e=editors.nth(i); try { if(await e.isVisible()){ await e.fill(article.body); break; } } catch{} }
  }

  const selects = page.locator('select');
  for(let i=0;i<await selects.count();i++) {
    const s=selects.nth(i); const meta=await fieldMetadata(s);
    try {
      const opts=await s.locator('option').allTextContents();
      const wanted = opts.find(o=>/bus|transport|travel|tour|rental|wedding|event/i.test(o));
      if(wanted && /(category|business type|service)/i.test(meta)) await s.selectOption({label:wanted});
    } catch{}
  }

  const files = page.locator('input[type=file]');
  if (await files.count() && article.asset_path && fs.existsSync(article.asset_path)) {
    for(let i=0;i<await files.count();i++) { try { await files.nth(i).setInputFiles(article.asset_path); break; } catch{} }
  }

  const terms = page.locator('input[type=checkbox]');
  for(let i=0;i<await terms.count();i++) {
    const e=terms.nth(i); const meta=await fieldMetadata(e);
    const id=await e.getAttribute('id');
    let label=''; if(id) label=await page.locator(`label[for="${id}"]`).innerText().catch(()=> '');
    if(/terms|privacy|agreement|authori[sz]e|consent/i.test(`${meta} ${label}`)) return {termsConsent:true};
  }
  return {termsConsent:false};
}
async function submitCurrentPage(page, opp, article) {
  const blocker = await detectBlocker(page);
  if (blocker) {
    createCheckpoint(opp.id,blocker.type,blocker.prompt,page.url());
    setOpp(opp.id,{status:'waiting_verification'});
    return {status:'waiting_verification',proof_url:page.url(),evidence:blocker.prompt};
  }
  const filled = await fillForm(page,opp,article);
  if (filled.termsConsent) {
    createCheckpoint(opp.id,'terms_consent','This site requires account-owner acceptance of terms. Review and accept them in the live browser, then tap Resume.',page.url());
    setOpp(opp.id,{status:'waiting_verification'});
    return {status:'waiting_verification',proof_url:page.url(),evidence:'Terms consent required'};
  }
  const afterFillBlocker = await detectBlocker(page);
  if (afterFillBlocker) {
    createCheckpoint(opp.id,afterFillBlocker.type,afterFillBlocker.prompt,page.url());
    setOpp(opp.id,{status:'waiting_verification'});
    return {status:'waiting_verification',proof_url:page.url(),evidence:afterFillBlocker.prompt};
  }

  const buttons = page.getByRole('button',{name:/submit|publish|send|continue|next|save|claim|add place|register|create account|get started/i});
  if (!await buttons.count()) {
    createCheckpoint(opp.id,'unsupported_form','The generic adapter could not identify the next button. The live browser is open at the prepared page.',page.url());
    setOpp(opp.id,{status:'waiting_verification'});
    return {status:'waiting_verification',proof_url:page.url(),evidence:'No supported submit/continue button'};
  }
  await buttons.first().click().catch(()=>{});
  await page.waitForTimeout(3500);
  const postBlocker=await detectBlocker(page);
  if(postBlocker){createCheckpoint(opp.id,postBlocker.type,postBlocker.prompt,page.url());setOpp(opp.id,{status:'waiting_verification'});return {status:'waiting_verification',proof_url:page.url(),evidence:postBlocker.prompt};}
  const text=(await page.locator('body').innerText().catch(()=>'' )).replace(/\s+/g,' ').slice(0,20000);
  const errors=/(required field|please enter|invalid|error occurred|something went wrong|fix the errors)/i.test(text);
  const success=/(thank you|submitted successfully|submission received|place added successfully|pending review|verification sent|check your email|listing created)/i.test(text);
  if(errors && !success) return {status:'validation_error',proof_url:page.url(),error:text.slice(0,1000)};
  return {status:success?'submitted':'pending_confirmation',proof_url:page.url(),evidence:text.slice(0,1200)};
}

async function processOpportunity(opp, resume=false) {
  const inspection = await inspectOpportunity(opp);
  if (!inspection.allowed) { setOpp(opp.id,{status:'unsuitable',policy_status:inspection.reason,score:inspection.score}); return; }
  const article = await generateArticle(opp,inspection);
  const page = await findPersistentPage(opp);
  if (!resume || page.url()==='about:blank') await page.goto(opp.submission_url||inspection.submissionUrl||opp.landing_url,{waitUntil:'domcontentloaded',timeout:45000});
  const result = await submitCurrentPage(page,opp,article);
  const sid = db.prepare(`INSERT INTO submissions(opportunity_id,article_id,status,proof_url,evidence,error,submitted_at) VALUES(?,?,?,?,?,?,CASE WHEN ? IN ('submitted','pending_confirmation') THEN CURRENT_TIMESTAMP ELSE NULL END)`).run(opp.id,article.id,result.status,result.proof_url||page.url(),result.evidence||null,result.error||null,result.status).lastInsertRowid;
  if(result.status==='submitted'||result.status==='pending_confirmation'){closeCheckpoints(opp.id);setOpp(opp.id,{status:result.status,last_error:null});}
  else if(result.status==='validation_error') setOpp(opp.id,{status:'error',last_error:result.error});
  return sid;
}

async function runSubmissionCycle() {
  const runId=beginRun('submission'); let completed=0,waiting=0,errors=0;
  try {
    const rows=db.prepare(`SELECT * FROM opportunities WHERE status='qualified' ORDER BY priority DESC LIMIT ?`).all(Number(process.env.MAX_DAILY_SUBMISSIONS||2));
    for(const opp of rows){
      try{await processOpportunity(opp,false);const fresh=q.oppById.get(opp.id);fresh.status==='waiting_verification'?waiting++:completed++;}
      catch(e){errors++;setOpp(opp.id,{status:'error',last_error:String(e)});log('error','Submission flow failed',{id:opp.id,error:String(e)});}
    }
    endRun(runId,'completed',`${completed} processed, ${waiting} waiting verification, ${errors} errors`);
  } catch(e){endRun(runId,'failed',String(e));throw e;}
}

async function recheckSubmissions() {
  const runId=beginRun('recheck');let live=0,pending=0,failed=0;
  try {
    const rows=db.prepare(`SELECT s.*,o.domain FROM submissions s JOIN opportunities o ON o.id=s.opportunity_id WHERE s.status IN ('submitted','pending_confirmation','live') ORDER BY s.id DESC LIMIT 20`).all();
    for(const s of rows){
      try{
        const url=s.live_url||s.proof_url;
        if(!url){pending++;continue;}
        const r=await fetch(url,{redirect:'follow',signal:AbortSignal.timeout(20000),headers:{'user-agent':USER_AGENT}});
        const html=await r.text();
        const target='https://www.nitutravels.in/bus-rental-delhi.html';
        const has=html.includes(target)||html.includes('nitutravels.in');
        const rel=(html.match(/href=["'][^"']*nitutravels\.in[^"']*["'][^>]*rel=["']([^"']+)/i)||[])[1]||null;
        db.prepare(`UPDATE submissions SET status=?,live_url=?,link_rel=?,checked_at=CURRENT_TIMESTAMP WHERE id=?`).run(has?'live':s.status,r.url,rel,s.id);
        if(has){live++;setOpp(s.opportunity_id,{status:'live'});}else pending++;
      }catch(e){failed++;db.prepare(`UPDATE submissions SET error=?,checked_at=CURRENT_TIMESTAMP WHERE id=?`).run(String(e),s.id);}
    }
    endRun(runId,'completed',`${live} live, ${pending} pending, ${failed} errors`);
  }catch(e){endRun(runId,'failed',String(e));throw e;}
}

let running=false;
async function fullCycle(){if(running)return;running=true;try{await runDiscoveryAndQualification();await runSubmissionCycle();await recheckSubmissions();}finally{running=false;}}
function runAsync(fn){if(running)return false;running=true;Promise.resolve().then(fn).catch(e=>log('error','Background job failed',{error:String(e)})).finally(()=>running=false);return true;}

function auth(req,res,next){
  if(req.path==='/health')return next();
  const supplied=req.query.token||req.headers.authorization?.replace(/^Bearer /,'')||req.cookies.nams_token;
  if(supplied!==TOKEN){
    return res.status(401).type('html').send(`<!doctype html><meta name="viewport" content="width=device-width"><style>body{font-family:system-ui;max-width:440px;margin:70px auto;padding:24px}input,button{width:100%;box-sizing:border-box;padding:14px;margin:8px 0;border:1px solid #ccd2dc;border-radius:10px}button{background:#176b5b;color:white;font-weight:700}</style><h1>NAMS Authority Agent</h1><p>Enter the secure dashboard token.</p><form><input name="token" type="password" required><button>Sign in</button></form>`);
  }
  if(req.query.token===TOKEN){res.cookie('nams_token',TOKEN,{httpOnly:true,sameSite:'lax',secure:true,maxAge:30*24*3600*1000});return res.redirect('/');}
  next();
}
app.use(auth);

const browserProxy=createProxyMiddleware({target:'http://chromium:6080',changeOrigin:true,ws:true,pathRewrite:{'^/browser':''}});
app.use('/browser',browserProxy);

const css=`
:root{--ink:#172033;--muted:#667085;--green:#176b5b;--bg:#f4f6fa;--line:#e3e7ee}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font-family:Inter,system-ui,Arial}.wrap{max-width:1220px;margin:auto;padding:22px}.top{display:flex;align-items:center;justify-content:space-between;gap:20px}.nav a{margin-left:14px;color:var(--green);text-decoration:none;font-weight:650}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin:22px 0}.card,.panel{background:white;border:1px solid var(--line);border-radius:16px;padding:18px;box-shadow:0 4px 18px rgba(30,45,70,.05)}.num{font-size:34px;font-weight:800;color:var(--green)}.muted{color:var(--muted)}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.btn,button{display:inline-block;background:var(--green);color:white;border:0;border-radius:10px;padding:11px 15px;text-decoration:none;font-weight:700;cursor:pointer;margin:3px}.btn.secondary{background:#eef3f2;color:var(--green)}table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:10px;border-bottom:1px solid var(--line);vertical-align:top}.badge{display:inline-block;padding:5px 8px;border-radius:99px;background:#edf0f5;font-size:12px}.s-live,.s-submitted{background:#dff5e8;color:#166534}.s-qualified{background:#e0f2fe;color:#075985}.s-waiting_verification{background:#fff2cc;color:#854d0e}.s-error,.s-unsuitable{background:#fee2e2;color:#991b1b}pre{white-space:pre-wrap;background:#f7f8fa;padding:12px;border-radius:10px;max-height:280px;overflow:auto}@media(max-width:800px){.grid{grid-template-columns:1fr}.top{align-items:flex-start;flex-direction:column}.nav a{margin:0 10px 0 0}.wrap{padding:14px}table{font-size:12px}}
`;
function layout(title,body){return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${esc(title)} · NAMS</title><style>${css}</style></head><body><div class="wrap"><div class="top"><div><h2 style="margin:0">NAMS Authority Agent <span class="muted" style="font-size:14px">v5</span></h2><div class="muted">Nitu Travels · compliant citations and editorial workflow</div></div><div class="nav"><a href="/">Dashboard</a><a href="/opportunities">Opportunities</a><a href="/checkpoints">Verification</a><a href="/ledger">Ledger</a><a href="/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify" target="_blank">Live browser</a></div></div>${body}</div></body></html>`;}
function postButton(action,label,secondary=false){return `<form method="post" action="${action}" style="display:inline"><button class="${secondary?'secondary':''}">${esc(label)}</button></form>`;}

app.get('/health',(req,res)=>res.json({ok:true,version:'5.0.0',running}));
app.get('/',(req,res)=>{
  const counts=Object.fromEntries(q.counts.all().map(x=>[x.status,x.n]));
  const checkpoints=q.openCheckpoints.all();const runs=q.recentRuns.all();const subs=q.recentSubs.all().slice(0,8);
  const cards=['discovered','qualified','waiting_verification','submitted','live','error'].map(k=>`<div class="card"><div class="num">${counts[k]||0}</div><div>${k.replaceAll('_',' ')}</div></div>`).join('');
  const cp=checkpoints.length?checkpoints.map(c=>`<tr><td>${esc(c.name)}</td><td><span class="badge ${statusClass(c.type)}">${esc(c.type)}</span></td><td>${esc(c.prompt)}</td><td><a class="btn secondary" target="_blank" href="/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify">Open browser</a>${postButton(`/checkpoints/${c.id}/resume`,'Resume')}</td></tr>`).join(''):`<tr><td colspan="4" class="muted">No verification tasks.</td></tr>`;
  const recent=subs.length?subs.map(s=>`<tr><td>${esc(s.name)}</td><td>${esc(s.title||'')}</td><td><span class="badge ${statusClass(s.status)}">${esc(s.status)}</span></td><td>${s.live_url?`<a href="${esc(s.live_url)}" target="_blank">Open</a>`:esc(s.proof_url||'')}</td></tr>`).join(''):`<tr><td colspan="4" class="muted">No submissions yet.</td></tr>`;
  res.send(layout('Dashboard',`<div class="cards">${cards}</div><div class="panel"><h3>Agent controls</h3>${postButton('/run/full','Run full cycle now')}${postButton('/run/discovery','Discover and qualify',true)}${postButton('/run/submissions','Prepare and submit',true)}${postButton('/run/recheck','Recheck links',true)}<p class="muted">Scheduler: discovery 09:00, submissions 12:00 and link recheck 18:00 Asia/Kolkata. Maximum ${esc(process.env.MAX_DAILY_SUBMISSIONS||'2')} new submissions daily.</p></div><div class="grid" style="margin-top:18px"><div class="panel"><h3>Verification queue</h3><table><tr><th>Opportunity</th><th>Type</th><th>Action needed</th><th></th></tr>${cp}</table></div><div class="panel"><h3>Recent runs</h3><table><tr><th>Run</th><th>Status</th><th>Result</th></tr>${runs.map(r=>`<tr><td>${esc(r.kind)}<br><span class="muted">${fmt(r.started_at)}</span></td><td>${esc(r.status)}</td><td>${esc(r.summary||'')}</td></tr>`).join('')}</table></div></div><div class="panel" style="margin-top:18px"><h3>Recent submission ledger</h3><table><tr><th>Site</th><th>Content</th><th>Status</th><th>URL</th></tr>${recent}</table></div>`));
});
app.get('/opportunities',(req,res)=>{
  const rows=q.recentOpps.all();
  res.send(layout('Opportunities',`<div class="panel"><h3>Qualified opportunity catalog</h3><p class="muted">The catalog starts with official local-listing platforms and one Delhi wedding editorial opportunity. Every target is re-inspected before use.</p><table><tr><th>Priority</th><th>Opportunity</th><th>Category</th><th>Policy</th><th>Status</th><th>Score</th></tr>${rows.map(o=>`<tr><td>${o.priority}</td><td><b>${esc(o.name)}</b><br><a href="${esc(o.landing_url)}" target="_blank">${esc(o.domain)}</a><br><span class="muted">${esc(o.notes||'')}</span></td><td>${esc(o.category||'')}</td><td>${esc(o.policy_status)}</td><td><span class="badge ${statusClass(o.status)}">${esc(o.status)}</span>${o.last_error?`<br><span class="muted">${esc(o.last_error).slice(0,200)}</span>`:''}</td><td>${o.score}</td></tr>`).join('')}</table></div>`));
});
app.get('/checkpoints',(req,res)=>{
  const rows=q.openCheckpoints.all();
  res.send(layout('Verification',`<div class="panel"><h3>CAPTCHA, OTP and consent checkpoints</h3><p>Open the persistent browser, complete the displayed verification, then tap Resume. The agent continues in the same browser profile.</p><a class="btn" target="_blank" href="/browser/vnc.html?autoconnect=1&resize=scale&path=browser/websockify">Open live browser</a><table style="margin-top:15px"><tr><th>Site</th><th>Type</th><th>Instruction</th><th></th></tr>${rows.map(c=>`<tr><td>${esc(c.name)}</td><td>${esc(c.type)}</td><td>${esc(c.prompt)}<br><span class="muted">${esc(c.url||'')}</span></td><td>${postButton(`/checkpoints/${c.id}/resume`,'Resume')}</td></tr>`).join('')||'<tr><td colspan="4">No open checkpoints.</td></tr>'}</table></div>`));
});
app.get('/ledger',(req,res)=>{
  const rows=q.recentSubs.all();
  res.send(layout('Ledger',`<div class="panel"><h3>Deduplicated backlink and citation ledger</h3><table><tr><th>Site</th><th>Article</th><th>Status</th><th>Submitted</th><th>Live URL / evidence</th><th>Rel</th></tr>${rows.map(s=>`<tr><td>${esc(s.name)}<br><span class="muted">${esc(s.domain)}</span></td><td>${esc(s.title||'Listing profile')}</td><td><span class="badge ${statusClass(s.status)}">${esc(s.status)}</span>${s.error?`<br>${esc(s.error).slice(0,160)}`:''}</td><td>${fmt(s.submitted_at)}</td><td>${s.live_url?`<a href="${esc(s.live_url)}" target="_blank">${esc(s.live_url)}</a>`:esc(s.proof_url||'')}</td><td>${esc(s.link_rel||'')}</td></tr>`).join('')||'<tr><td colspan="6">No ledger entries yet.</td></tr>'}</table></div>`));
});

app.post('/run/full',(req,res)=>{const ok=runAsync(async()=>{await runDiscoveryAndQualification();await runSubmissionCycle();await recheckSubmissions();});res.redirect(`/?started=${ok}`);});
app.post('/run/discovery',(req,res)=>{runAsync(runDiscoveryAndQualification);res.redirect('/');});
app.post('/run/submissions',(req,res)=>{runAsync(runSubmissionCycle);res.redirect('/');});
app.post('/run/recheck',(req,res)=>{runAsync(recheckSubmissions);res.redirect('/');});
app.post('/checkpoints/:id/resume',(req,res)=>{
  const cp=db.prepare(`SELECT * FROM checkpoints WHERE id=?`).get(req.params.id);
  if(!cp)return res.redirect('/checkpoints');
  const opp=q.oppById.get(cp.opportunity_id);
  runAsync(async()=>{try{await processOpportunity(opp,true);}catch(e){setOpp(opp.id,{status:'error',last_error:String(e)});log('error','Resume failed',{id:opp.id,error:String(e)});}});
  res.redirect('/checkpoints');
});

cron.schedule(process.env.CRON_DISCOVERY||'0 9 * * *',()=>runAsync(runDiscoveryAndQualification),{timezone:process.env.TZ||'Asia/Kolkata'});
cron.schedule(process.env.CRON_SUBMIT||'0 12 * * *',()=>runAsync(runSubmissionCycle),{timezone:process.env.TZ||'Asia/Kolkata'});
cron.schedule(process.env.CRON_RECHECK||'0 18 * * *',()=>runAsync(recheckSubmissions),{timezone:process.env.TZ||'Asia/Kolkata'});

app.listen(8080,'0.0.0.0',()=>{log('info','NAMS v5 started',{domain:DOMAIN,model:MODEL});console.log('NAMS v5 ready on 8080');});
