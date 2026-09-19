// SQLite-Zugriff ueber das eingebaute node:sqlite (Node >= 24, keine externe Abhaengigkeit).
import { DatabaseSync } from 'node:sqlite';
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const DB_PATH = process.env.DB_PATH || '/data/app.db';
mkdirSync(dirname(DB_PATH), { recursive: true });

export const db = new DatabaseSync(DB_PATH);
db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA foreign_keys = ON;
  CREATE TABLE IF NOT EXISTS users (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    pass_hash   TEXT NOT NULL,
    stream_key  TEXT,
    status      TEXT NOT NULL DEFAULT 'pending',   -- pending | approved
    created_at  INTEGER NOT NULL,
    approved_by INTEGER
  );
  CREATE TABLE IF NOT EXISTS sessions (
    id         TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS viewer_tokens (
    token      TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text       TEXT NOT NULL,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
  CREATE INDEX IF NOT EXISTS idx_vtokens_user ON viewer_tokens(user_id);
`);

const now = () => Date.now();
export const SESSION_TTL = 30 * 24 * 3600 * 1000;   // 30 Tage
export const VIEWER_TTL = 12 * 3600 * 1000;         // 12 Stunden

// --- Passwoerter -------------------------------------------------------------
export function hashPassword(pw) {
  const salt = randomBytes(16);
  const hash = scryptSync(pw, salt, 64);
  return `scrypt:${salt.toString('hex')}:${hash.toString('hex')}`;
}
export function verifyPassword(pw, stored) {
  const [, saltHex, hashHex] = stored.split(':');
  const hash = scryptSync(pw, Buffer.from(saltHex, 'hex'), 64);
  const expected = Buffer.from(hashHex, 'hex');
  return hash.length === expected.length && timingSafeEqual(hash, expected);
}
export const newStreamKey = () => randomBytes(24).toString('hex');

// --- Users ------------------------------------------------------------------
const stmts = {
  userByName: db.prepare('SELECT * FROM users WHERE name = ?'),
  userById: db.prepare('SELECT * FROM users WHERE id = ?'),
  userCount: db.prepare('SELECT COUNT(*) AS n FROM users'),
  insertUser: db.prepare('INSERT INTO users (name, pass_hash, stream_key, status, created_at) VALUES (?, ?, ?, ?, ?)'),
  listUsers: db.prepare('SELECT id, name, status, created_at, approved_by FROM users ORDER BY status DESC, name'),
  approveUser: db.prepare("UPDATE users SET status = 'approved', stream_key = ?, approved_by = ? WHERE id = ? AND status = 'pending'"),
  deleteUser: db.prepare('DELETE FROM users WHERE id = ?'),
  setStreamKey: db.prepare('UPDATE users SET stream_key = ? WHERE id = ?'),
  approvedNames: db.prepare("SELECT name FROM users WHERE status = 'approved' ORDER BY name"),

  insertSession: db.prepare('INSERT INTO sessions (id, user_id, expires_at) VALUES (?, ?, ?)'),
  sessionUser: db.prepare('SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.id = ? AND s.expires_at > ?'),
  deleteSession: db.prepare('DELETE FROM sessions WHERE id = ?'),

  insertViewerToken: db.prepare('INSERT INTO viewer_tokens (token, user_id, expires_at) VALUES (?, ?, ?)'),
  validViewerToken: db.prepare('SELECT token FROM viewer_tokens WHERE user_id = ? AND expires_at > ? ORDER BY expires_at DESC LIMIT 1'),
  viewerTokenUser: db.prepare("SELECT u.* FROM viewer_tokens t JOIN users u ON u.id = t.user_id WHERE t.token = ? AND t.expires_at > ? AND u.status = 'approved'"),

  cleanup: db.prepare('DELETE FROM sessions WHERE expires_at < ?'),
  cleanupTokens: db.prepare('DELETE FROM viewer_tokens WHERE expires_at < ?'),
};

export function createUser(name, password) {
  const first = stmts.userCount.get().n === 0;           // erster Nutzer darf sofort alles
  const status = first ? 'approved' : 'pending';
  const key = first ? newStreamKey() : null;
  const r = stmts.insertUser.run(name, hashPassword(password), key, status, now());
  return stmts.userById.get(r.lastInsertRowid);
}
export const getUserByName = (name) => stmts.userByName.get(name);
export const getUserById = (id) => stmts.userById.get(id);
export const listUsers = () => stmts.listUsers.all();
export const approvedNames = () => stmts.approvedNames.all().map((r) => r.name);
export const approveUser = (id, byId) => stmts.approveUser.run(newStreamKey(), byId, id).changes > 0;
export const deleteUser = (id) => stmts.deleteUser.run(id).changes > 0;
export function rotateStreamKey(id) {
  const key = newStreamKey();
  stmts.setStreamKey.run(key, id);
  return key;
}
export const setPassword = (id, pw) => db.prepare('UPDATE users SET pass_hash = ? WHERE id = ?').run(hashPassword(pw), id);

// --- Sessions ---------------------------------------------------------------
export function createSession(userId) {
  const id = randomBytes(32).toString('base64url');
  stmts.insertSession.run(id, userId, now() + SESSION_TTL);
  return id;
}
export const userForSession = (sid) => (sid ? stmts.sessionUser.get(sid, now()) : undefined);
export const destroySession = (sid) => stmts.deleteSession.run(sid);

// --- Viewer-Tokens (Player -> WHEP -> MediaMTX -> Auth-Hook) ----------------
export function viewerTokenFor(userId) {
  // Token wird erst erneuert, wenn weniger als 1h Restlaufzeit, sonst wiederverwendet.
  const row = db.prepare('SELECT token FROM viewer_tokens WHERE user_id = ? AND expires_at > ? ORDER BY expires_at DESC LIMIT 1')
    .get(userId, now() + 3600 * 1000);
  if (row) return row.token;
  const token = randomBytes(24).toString('hex');
  stmts.insertViewerToken.run(token, userId, now() + VIEWER_TTL);
  return token;
}
export const userForViewerToken = (token) => (token ? stmts.viewerTokenUser.get(token, now()) : undefined);

// --- Gruppen-Chat --------------------------------------------------------------
// Verlauf wird auf die letzten CHAT_KEEP Nachrichten begrenzt (einfacher Gruppen-Chat, kein Archiv).
const CHAT_KEEP = 2000;
const chat = {
  insert: db.prepare('INSERT INTO messages (user_id, text, created_at) VALUES (?, ?, ?)'),
  byId: db.prepare('SELECT m.id, m.text, m.created_at AS at, u.name FROM messages m JOIN users u ON u.id = m.user_id WHERE m.id = ?'),
  last: db.prepare('SELECT * FROM (SELECT m.id, m.text, m.created_at AS at, u.name FROM messages m JOIN users u ON u.id = m.user_id ORDER BY m.id DESC LIMIT ?) ORDER BY id'),
  after: db.prepare('SELECT m.id, m.text, m.created_at AS at, u.name FROM messages m JOIN users u ON u.id = m.user_id WHERE m.id > ? ORDER BY m.id LIMIT ?'),
  trim: db.prepare('DELETE FROM messages WHERE id <= (SELECT id FROM messages ORDER BY id DESC LIMIT 1 OFFSET ?)'),
};
export function addMessage(userId, text) {
  const r = chat.insert.run(userId, text, now());
  if (Number(r.lastInsertRowid) % 100 === 0) chat.trim.run(CHAT_KEEP);
  return chat.byId.get(r.lastInsertRowid);
}
export const messagesAfter = (afterId, limit = 200) => (afterId > 0 ? chat.after.all(afterId, limit) : chat.last.all(limit));

// Aufraeumen alle 6h
setInterval(() => {
  stmts.cleanup.run(now());
  stmts.cleanupTokens.run(now());
}, 6 * 3600 * 1000).unref();
