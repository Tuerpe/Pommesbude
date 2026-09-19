// Stream-Relay Website: Login/Registrierung/Freigabe, Auth-Hook fuer MediaMTX, Live-Liste, Voice-Praesenz (Mumble),
// Gruppen-Chat (SSE), statische Raster-Seite.
import express from 'express';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import {
  createUser, getUserByName, getUserById, listUsers, approvedNames, approveUser, deleteUser, rotateStreamKey, setPassword,
  verifyPassword, createSession, userForSession, destroySession, viewerTokenFor, userForViewerToken, SESSION_TTL,
  addMessage, messagesAfter,
} from './db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 3000);
const MEDIAMTX_API = process.env.MEDIAMTX_API || 'http://mediamtx:9997';
const PUBLIC_DOMAIN = process.env.DOMAIN || 'localhost';
const HOOK_SUBNET = process.env.HOOK_SUBNET || '172.30.0.0/24';
const SITE_NAME = process.env.SITE_NAME || 'Stream Relay';
// Voice (Mumble): Host/Passwort kommen aus .env (MUMBLE_HOST = DOMAIN, MUMBLE_PASSWORD), Praesenz vom Sidecar mumble-ice.
const MUMBLE_HOST = process.env.MUMBLE_HOST || '';
const MUMBLE_PASSWORD = process.env.MUMBLE_PASSWORD || '';
const MUMBLE_PORT = Number(process.env.MUMBLE_PORT || 64738);
const MUMBLE_ICE_URL = process.env.MUMBLE_ICE_URL || 'http://mumble:6503';
const VOICE_ENABLED = !!(MUMBLE_HOST && MUMBLE_PASSWORD);
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
  res.json({ siteName: SITE_NAME, clientVersion: CLIENT_VERSION, minClientVersion: MIN_CLIENT_VERSION, clientUrl: hasZip ? CLIENT_ZIP : null, voice: VOICE_ENABLED });
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

// mumble://name:passwort@host:port/?title=... verbindet den Mumble-Client direkt (laeuft er schon, uebernimmt die laufende Instanz).
const voiceUrlFor = (name) =>
  `mumble://${encodeURIComponent(name)}:${encodeURIComponent(MUMBLE_PASSWORD)}@${MUMBLE_HOST}:${MUMBLE_PORT}/?title=${encodeURIComponent(SITE_NAME)}`;

app.get('/api/me', requireLogin, (req, res) => {
  const u = req.user;
  const approved = u.status === 'approved';
  res.json({
    ...publicUser(u),
    streamKey: approved ? u.stream_key : null,
    whipUrl: `https://${PUBLIC_DOMAIN}/${u.name}/whip`,
    pendingCount: approved ? listUsers().filter((x) => x.status === 'pending').length : 0,
    voice: VOICE_ENABLED,
    voiceUrl: approved && VOICE_ENABLED ? voiceUrlFor(u.name) : null,
    voiceHost: approved && VOICE_ENABLED ? MUMBLE_HOST : null,
    voicePort: approved && VOICE_ENABLED ? MUMBLE_PORT : null,
    voicePassword: approved && VOICE_ENABLED ? MUMBLE_PASSWORD : null,
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
// Passwort eines anderen Nutzers zuruecksetzen: liefert ein einmaliges Startpasswort, das der Nutzer dann aendert.
app.post('/api/users/:id/resetpw', requireLogin, requireApproved, (req, res) => {
  const id = Number(req.params.id);
  if (id === req.user.id) return res.status(400).json({ error: 'not_self' });
  const target = getUserById(id);
  if (!target) return res.status(404).json({ error: 'not_found' });
  const temp = randomBytes(9).toString('base64url');
  setPassword(id, temp);
  console.log(`[users] ${req.user.name} reset password of ${target.name}`);
  res.json({ tempPassword: temp });
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

// --- Voice-Praesenz (wer ist im Mumble) ueber den Sidecar mumble-ice ------------------------------
let voiceCache = { at: 0, users: [], ok: false };
async function voiceUsers() {
  if (!VOICE_ENABLED) return voiceCache;
  if (Date.now() - voiceCache.at < 3000) return voiceCache;
  try {
    const r = await fetch(`${MUMBLE_ICE_URL}/users`, { signal: AbortSignal.timeout(2500) });
    const users = r.ok ? await r.json() : [];
    voiceCache = { at: Date.now(), users: Array.isArray(users) ? users : [], ok: r.ok };
  } catch (e) {
    voiceCache = { at: Date.now(), users: [], ok: false };
  }
  return voiceCache;
}
app.get('/api/voice', requireLogin, requireApproved, async (_req, res) => {
  const v = await voiceUsers();
  res.json({ enabled: VOICE_ENABLED, ok: v.ok, users: v.users });
});

// --- Gruppen-Chat: Verlauf, Senden, Live-Updates per Server-Sent Events ---------------------------------
const sseClients = new Set();
function sseBroadcast(event, data) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const c of sseClients) { try { c.write(payload); } catch { sseClients.delete(c); } }
}
app.get('/api/chat', requireLogin, requireApproved, (req, res) => {
  const after = Number(req.query.after || 0);
  res.json({ messages: messagesAfter(after > 0 ? after : 0, 200) });
});
const chatRate = new Map();   // userId -> Zeitstempel der letzten Nachrichten (max 5 in 5 s)
app.post('/api/chat', requireLogin, requireApproved, (req, res) => {
  const text = String(req.body?.text || '').replace(/\r\n?/g, '\n').trim();
  if (!text || text.length > 2000) return res.status(400).json({ error: 'bad_text' });
  const t = Date.now();
  const recent = (chatRate.get(req.user.id) || []).filter((x) => t - x < 5000);
  if (recent.length >= 5) return res.status(429).json({ error: 'too_fast' });
  recent.push(t); chatRate.set(req.user.id, recent);
  const m = addMessage(req.user.id, text);
  sseBroadcast('message', m);
  res.status(201).json(m);
});
app.get('/api/chat/stream', requireLogin, requireApproved, (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no',
  });
  res.write('retry: 3000\n\n');
  sseClients.add(res);
  const hb = setInterval(() => { try { res.write(': hb\n\n'); } catch {} }, 25000);
  req.on('close', () => { clearInterval(hb); sseClients.delete(res); });
});
// Praesenz-Aenderungen an alle SSE-Clients, solange jemand verbunden ist (alle 3 s beim Sidecar nachsehen).
let lastVoiceSig = '';
setInterval(async () => {
  if (!VOICE_ENABLED || sseClients.size === 0) return;
  const v = await voiceUsers();
  const sig = JSON.stringify(v.users);
  if (sig !== lastVoiceSig) { lastVoiceSig = sig; sseBroadcast('voice', { ok: v.ok, users: v.users }); }
}, 3000).unref();

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
  const v = await voiceUsers();
  res.json({ streams, viewerToken: viewerTokenFor(req.user.id), me: req.user.name, voice: { enabled: VOICE_ENABLED, ok: v.ok, users: v.users } });
});

// --- Statische Seite ------------------------------------------------------------------
// maxAge 0 + ETag: Browser fragt bei jedem Laden nach (304 wenn unveraendert), Updates kommen sofort an.
// index.html wird einmal gelesen und der Platzhalter {{SITE_NAME}} ersetzt (Branding aus .env).
const esc = (t) => t.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const indexHtml = readFileSync(join(__dirname, 'public', 'index.html'), 'utf8').split('{{SITE_NAME}}').join(esc(SITE_NAME));
app.get(['/', '/index.html'], (_req, res) => { res.setHeader('Cache-Control', 'no-cache'); res.type('html').send(indexHtml); });
app.use(express.static(join(__dirname, 'public'), { index: false, maxAge: 0, etag: true }));
app.use((_req, res) => res.status(404).json({ error: 'not_found' }));

app.listen(PORT, () => console.log(`[web] listening on :${PORT}, domain ${PUBLIC_DOMAIN}, site "${SITE_NAME}", client ${CLIENT_VERSION} (min ${MIN_CLIENT_VERSION}), hook subnet ${HOOK_SUBNET}, voice ${VOICE_ENABLED ? MUMBLE_HOST + ':' + MUMBLE_PORT : 'off'}`));
