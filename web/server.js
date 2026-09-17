// Stream-Relay Website: Login/Registrierung/Freigabe, Auth-Hook fuer MediaMTX, Live-Liste, statische Raster-Seite.
import express from 'express';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import {
  createUser, getUserByName, getUserById, listUsers, approvedNames, approveUser, deleteUser, rotateStreamKey, setPassword,
  verifyPassword, createSession, userForSession, destroySession, viewerTokenFor, userForViewerToken, SESSION_TTL,
} from './db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 3000);
const MEDIAMTX_API = process.env.MEDIAMTX_API || 'http://mediamtx:9997';
const PUBLIC_DOMAIN = process.env.DOMAIN || 'localhost';
const HOOK_SUBNET = process.env.HOOK_SUBNET || '172.30.0.0/24';
const SITE_NAME = process.env.SITE_NAME || 'Stream Relay';
// Client-Version = Inhalt der Datei VERSION (beim Docker-Build kopiert). MIN_CLIENT_VERSION anheben, wenn aeltere Launcher
// nicht mehr mit Server/Hook/Szenen zusammenarbeiten -> Launcher erzwingt dann das Update.
const CLIENT_VERSION = (() => { try { return readFileSync(join(__dirname, 'VERSION'), 'utf8').trim(); } catch { return '0.0.0'; } })();
const MIN_CLIENT_VERSION = '1.0.0';
const CLIENT_ZIP = '/client/pommesbude-client.zip';
const SECURE_COOKIES = process.env.INSECURE_COOKIES !== '1';
const NAME_RE = /^[a-z0-9_-]{2,20}$/;

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 1);
app.use(express.json({ limit: '16kb' }));

// --- Hilfsfunktionen -----------------------------------------------------------
function parseCookies(req) {
  const out = {};
  for (const part of (req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}
function setSessionCookie(res, sid) {
  res.setHeader('Set-Cookie',
    `sid=${sid}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${Math.floor(SESSION_TTL / 1000)}${SECURE_COOKIES ? '; Secure' : ''}`);
}
function clearSessionCookie(res) {
  res.setHeader('Set-Cookie', `sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${SECURE_COOKIES ? '; Secure' : ''}`);
}
function ipInCidr(ip, cidr) {
  const [net, bitsStr] = cidr.split('/');
  const bits = Number(bitsStr ?? 32);
  const toInt = (s) => s.split('.').reduce((a, o) => (a << 8) + Number(o), 0) >>> 0;
  ip = ip.replace(/^::ffff:/, '');
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) return false;
  const mask = bits === 0 ? 0 : (~0 << (32 - bits)) >>> 0;
  return (toInt(ip) & mask) === (toInt(net) & mask);
}
const publicUser = (u) => ({ id: u.id, name: u.name, status: u.status });

// Brute-Force-Bremse fuer Login: 10 Fehlversuche pro IP in 15 Minuten.
const loginFails = new Map();
function loginBlocked(ip) {
  const e = loginFails.get(ip);
  return e && e.count >= 10 && Date.now() - e.first < 15 * 60 * 1000;
}
function noteLoginFail(ip) {
  const e = loginFails.get(ip);
  if (!e || Date.now() - e.first > 15 * 60 * 1000) loginFails.set(ip, { count: 1, first: Date.now() });
  else e.count++;
}

// --- Oeffentliche Konfiguration (Branding, Versionen, Client-Download) -------------------------
app.get('/api/config', (_req, res) => {
  const hasZip = existsSync(join(__dirname, 'public', 'client', 'pommesbude-client.zip'));
  res.json({ siteName: SITE_NAME, clientVersion: CLIENT_VERSION, minClientVersion: MIN_CLIENT_VERSION, clientUrl: hasZip ? CLIENT_ZIP : null });
});

// --- Auth-Middleware ---------------------------------------------------------------
function attachUser(req, _res, next) {
  req.sid = parseCookies(req).sid;
  req.user = userForSession(req.sid);
  next();
}
const requireLogin = (req, res, next) => (req.user ? next() : res.status(401).json({ error: 'not_logged_in' }));
const requireApproved = (req, res, next) =>
  (req.user?.status === 'approved' ? next() : res.status(403).json({ error: 'not_approved' }));

// --- MediaMTX Auth-Hook -------------------------------------------------------------
// MediaMTX POSTet {user,password,token,ip,action,path,protocol,...}. 2xx = erlaubt.
app.post('/api/mediamtx/auth', (req, res) => {
  const src = req.socket.remoteAddress || '';
  if (!ipInCidr(src, HOOK_SUBNET)) return res.status(403).end();
  const { user, password, token, action, path } = req.body || {};
  if (action === 'publish') {
    const u = user ? getUserByName(user) : undefined;
    // Erlaubt: eigener Pfad <name> (Bildschirm/Spiel) und <name>-cam (Kamera), beide mit dem eigenen Stream-Key.
    if (u && u.status === 'approved' && u.stream_key && password === u.stream_key && (path === u.name || path === `${u.name}-cam`)) return res.status(200).end();
    console.log(`[hook] publish DENIED user=${user} path=${path} ip=${req.body?.ip}`);
    return res.status(401).end();
  }
  if (action === 'read') {
    // Player schickt Bearer <viewerToken>; MediaMTX liefert ihn als "token".
    const viewer = userForViewerToken(token);
    if (viewer) return res.status(200).end();
    console.log(`[hook] read DENIED path=${path} ip=${req.body?.ip}`);
    return res.status(401).end();
  }
  return res.status(401).end();
});

app.use(attachUser);

// --- Registrierung / Login -----------------------------------------------------------
app.post('/api/register', (req, res) => {
  const name = String(req.body?.name || '').trim().toLowerCase();
  const password = String(req.body?.password || '');
  if (!NAME_RE.test(name) || name.endsWith('-cam')) return res.status(400).json({ error: 'bad_name' });
  if (password.length < 8 || password.length > 128) return res.status(400).json({ error: 'bad_password' });
  if (getUserByName(name)) return res.status(409).json({ error: 'name_taken' });
  const u = createUser(name, password);
  const sid = createSession(u.id);
  setSessionCookie(res, sid);
  console.log(`[users] registered ${u.name} (${u.status})`);
  res.status(201).json(publicUser(u));
});

app.post('/api/login', (req, res) => {
  const ip = req.ip;
  if (loginBlocked(ip)) return res.status(429).json({ error: 'too_many_attempts' });
  const name = String(req.body?.name || '').trim().toLowerCase();
  const password = String(req.body?.password || '');
  const u = getUserByName(name);
  if (!u || !verifyPassword(password, u.pass_hash)) {
    noteLoginFail(ip);
    return res.status(401).json({ error: 'bad_credentials' });
  }
  const sid = createSession(u.id);
  setSessionCookie(res, sid);
  res.json(publicUser(u));
});

app.post('/api/logout', (req, res) => {
  if (req.sid) destroySession(req.sid);
  clearSessionCookie(res);
  res.status(204).end();
});

app.get('/api/me', requireLogin, (req, res) => {
  const u = req.user;
  res.json({
    ...publicUser(u),
    streamKey: u.status === 'approved' ? u.stream_key : null,
    whipUrl: `https://${PUBLIC_DOMAIN}/${u.name}/whip`,
    pendingCount: u.status === 'approved' ? listUsers().filter((x) => x.status === 'pending').length : 0,
  });
});

app.post('/api/me/streamkey', requireLogin, requireApproved, (req, res) => {
  res.json({ streamKey: rotateStreamKey(req.user.id) });
});

app.post('/api/me/password', requireLogin, (req, res) => {
  const oldPw = String(req.body?.oldPassword || '');
  const newPw = String(req.body?.newPassword || '');
  if (!verifyPassword(oldPw, req.user.pass_hash)) return res.status(401).json({ error: 'bad_credentials' });
  if (newPw.length < 8 || newPw.length > 128) return res.status(400).json({ error: 'bad_password' });
  setPassword(req.user.id, newPw);
  res.status(204).end();
});

// --- Nutzerverwaltung (jeder freigegebene Nutzer darf freigeben/loeschen) ---------------------
app.get('/api/users', requireLogin, requireApproved, (_req, res) => {
  res.json(listUsers().map((u) => ({ id: u.id, name: u.name, status: u.status, createdAt: u.created_at })));
});
app.post('/api/users/:id/approve', requireLogin, requireApproved, (req, res) => {
  const id = Number(req.params.id);
  if (!approveUser(id, req.user.id)) return res.status(404).json({ error: 'not_pending' });
  console.log(`[users] ${req.user.name} approved #${id}`);
  res.status(204).end();
});
app.post('/api/users/:id/delete', requireLogin, requireApproved, (req, res) => {
  const id = Number(req.params.id);
  if (id === req.user.id) return res.status(400).json({ error: 'not_self' });
  const target = getUserById(id);
  if (!target || !deleteUser(id)) return res.status(404).json({ error: 'not_found' });
  console.log(`[users] ${req.user.name} deleted ${target.name}`);
  res.status(204).end();
});

// --- Live-Liste aus der MediaMTX Control-API ---------------------------------------------
let pathsCache = { at: 0, items: [] };
async function livePaths() {
  if (Date.now() - pathsCache.at < 2000) return pathsCache.items;
  const items = [];
  try {
    const r = await fetch(`${MEDIAMTX_API}/v3/paths/list?itemsPerPage=500`, { signal: AbortSignal.timeout(3000) });
    if (r.ok) {
      const j = await r.json();
      for (const p of j.items || []) items.push({ name: p.name, ready: !!p.ready, readyTime: p.readyTime, readers: (p.readers || []).length });
    }
  } catch (e) {
    console.warn('[mediamtx] paths/list failed:', e.message);
  }
  pathsCache = { at: Date.now(), items };
  return items;
}

app.get('/api/streams', requireLogin, requireApproved, async (req, res) => {
  const live = new Map((await livePaths()).map((p) => [p.name, p]));
  const streams = approvedNames().map((name) => {
    const p = live.get(name);
    const c = live.get(`${name}-cam`);
    return {
      name, live: !!p?.ready, since: p?.ready ? p.readyTime : null, readers: p?.readers ?? 0,
      camLive: !!c?.ready, camSince: c?.ready ? c.readyTime : null, camReaders: c?.readers ?? 0,
    };
  });
  res.json({ streams, viewerToken: viewerTokenFor(req.user.id), me: req.user.name });
});

// --- Statische Seite ------------------------------------------------------------------
// maxAge 0 + ETag: Browser fragt bei jedem Laden nach (304 wenn unveraendert), Updates kommen sofort an.
// index.html wird einmal gelesen und der Platzhalter {{SITE_NAME}} ersetzt (Branding aus .env).
const esc = (t) => t.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const indexHtml = readFileSync(join(__dirname, 'public', 'index.html'), 'utf8').split('{{SITE_NAME}}').join(esc(SITE_NAME));
app.get(['/', '/index.html'], (_req, res) => { res.setHeader('Cache-Control', 'no-cache'); res.type('html').send(indexHtml); });
app.use(express.static(join(__dirname, 'public'), { index: false, maxAge: 0, etag: true }));
app.use((_req, res) => res.status(404).json({ error: 'not_found' }));

app.listen(PORT, () => console.log(`[web] listening on :${PORT}, domain ${PUBLIC_DOMAIN}, site "${SITE_NAME}", client ${CLIENT_VERSION} (min ${MIN_CLIENT_VERSION}), hook subnet ${HOOK_SUBNET}`));
