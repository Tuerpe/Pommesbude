/* Stream-Relay-Website: Login/Registrierung, Raster aller laufenden Streams via WHEP, Audio-Fokus, Nutzerverwaltung. */
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const el = (tag, attrs = {}, ...children) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') n.className = v;
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    n.append(...children);
    return n;
  };
  const api = async (method, url, body) => {
    const r = await fetch(url, {
      method, headers: body ? { 'Content-Type': 'application/json' } : {}, body: body ? JSON.stringify(body) : undefined,
    });
    if (r.status === 204) return null;
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw Object.assign(new Error(j.error || `http_${r.status}`), { status: r.status, code: j.error });
    return j;
  };
  const ERR = {
    bad_name: 'Name: 2-20 Zeichen, nur a-z, 0-9, _ und -.', bad_password: 'Passwort mindestens 8 Zeichen.',
    name_taken: 'Name ist schon vergeben.', bad_credentials: 'Name oder Passwort falsch.',
    too_many_attempts: 'Zu viele Fehlversuche, 15 Minuten warten.',
  };

  // ---------------------------------------------------------------- Zustand
  let me = null;               // {name,status,streamKey,...}
  let viewerToken = null;
  let pollTimer = null;
  const players = new Map();   // key ('<name>' | '<name>-cam') -> Player
  let audioOn = null;          // key oder null
  let showOwn = false;         // eigene Streams/Kamera werden standardmaessig nicht geladen (Traffic, Spiegel-Effekt)
  const keyOf = (name, kind) => (kind === 'cam' ? `${name}-cam` : name);

  // Layout: mode standard|allBig|allSmall|custom, big = Keys im grossen Raster (nur custom), hideCams, focus = Key oder null
  const LS = 'pommesbude.layout';
  let L = { mode: 'standard', big: [], hideCams: false, focus: null, prevBig: null, stripH: 160 };
  try { Object.assign(L, JSON.parse(localStorage.getItem(LS) || '{}')); } catch {}
  const saveLayout = () => { try { localStorage.setItem(LS, JSON.stringify(L)); } catch {} };

  // ---------------------------------------------------------------- Ansichten
  function show(id) {
    for (const s of ['auth', 'pending', 'main']) $('#' + s).classList.toggle('hidden', s !== id);
  }

  async function boot() {
    try {
      me = await api('GET', '/api/me');
    } catch {
      me = null;
    }
    route();
  }
  function route() {
    stopPolling();
    if (!me) return show('auth');
    if (me.status !== 'approved') {
      $('#pending-name').textContent = me.name;
      show('pending');
      pollTimer = setInterval(async () => {
        try { me = await api('GET', '/api/me'); if (me.status === 'approved') route(); } catch { me = null; route(); }
      }, 10000);
      return;
    }
    $('#me-name').textContent = me.name;
    show('main');
    refreshStreams();
    pollTimer = setInterval(refreshStreams, 5000);
  }
  function stopPolling() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }

  // ---------------------------------------------------------------- Auth-Formulare
  for (const b of document.querySelectorAll('.tabs button')) {
    b.addEventListener('click', () => {
      document.querySelectorAll('.tabs button').forEach((x) => x.classList.toggle('active', x === b));
      $('#form-login').classList.toggle('hidden', b.dataset.tab !== 'login');
      $('#form-register').classList.toggle('hidden', b.dataset.tab !== 'register');
      $('#auth-error').textContent = '';
    });
  }
  async function submitAuth(e, url) {
    e.preventDefault();
    const f = new FormData(e.target);
    $('#auth-error').textContent = '';
    try {
      me = await api('POST', url, { name: f.get('name'), password: f.get('password') });
      me = await api('GET', '/api/me');
      route();
    } catch (err) {
      $('#auth-error').textContent = ERR[err.code] || `Fehler (${err.message})`;
    }
  }
  $('#form-login').addEventListener('submit', (e) => submitAuth(e, '/api/login'));
  $('#form-register').addEventListener('submit', (e) => submitAuth(e, '/api/register'));
  const logout = async () => { await api('POST', '/api/logout'); teardownAll(); me = null; route(); };
  $('#btn-logout').addEventListener('click', logout);
  $('#pending-logout').addEventListener('click', logout);

  // ---------------------------------------------------------------- Stream-Liste
  async function refreshStreams() {
    let data;
    try {
      data = await api('GET', '/api/streams');
    } catch (err) {
      if (err.status === 401 || err.status === 403) { me = null; teardownAll(); route(); }
      return;
    }
    viewerToken = data.viewerToken;

    // Alle Live-Elemente: Streams und Kameras
    const items = [];
    for (const s of data.streams) {
      if (s.live) items.push({ key: keyOf(s.name, 'stream'), name: s.name, kind: 'stream' });
      if (s.camLive) items.push({ key: keyOf(s.name, 'cam'), name: s.name, kind: 'cam' });
    }
    const own = items.filter((i) => i.name === data.me);
    const shown = items.filter((i) => (i.name !== data.me || showOwn) && !(L.hideCams && i.kind === 'cam'));

    for (const i of shown) if (!players.has(i.key)) players.set(i.key, new Player(i));
    for (const [key, p] of players) if (!shown.some((i) => i.key === key)) { p.destroy(); players.delete(key); }
    if (L.focus && !players.has(L.focus)) { L.focus = null; saveLayout(); }
    if (audioOn && !players.has(audioOn)) audioOn = null;

    const liveStreams = items.filter((i) => i.kind === 'stream').length;
    const liveCams = items.filter((i) => i.kind === 'cam').length;
    $('#live-count').textContent = items.length ? `${liveStreams} live${liveCams ? ` · ${liveCams} 🎥` : ''}` : '';
    $('#empty').classList.toggle('hidden', shown.length > 0);
    $('#empty').textContent = own.length ? 'Nur du streamst gerade. Deine eigenen Streams werden nicht geladen, um Traffic zu sparen.' : 'Gerade streamt niemand.';

    const offline = data.streams.filter((s) => !s.live && !s.camLive);
    const chips = offline.map((s) => el('span', { class: 'chip' }, s.name));
    if (own.length) {
      const what = own.map((i) => (i.kind === 'cam' ? 'Kamera' : 'Bildschirm')).join(' + ');
      chips.unshift(el('span', { class: 'chip own' }, `🔴 Du streamst gerade (${what}) `,
        el('button', { onclick: () => { showOwn = !showOwn; refreshStreams(); } }, showOwn ? 'Ausblenden' : 'Anzeigen')));
    }
    $('#offline').replaceChildren(...chips);
    layout();
    try { const m = await api('GET', '/api/me'); $('#pending-badge').textContent = m.pendingCount; $('#pending-badge').classList.toggle('hidden', !m.pendingCount); } catch {}
  }

  // ---------------------------------------------------------------- Layout
  // Entscheidet pro Element, ob es ins grosse Raster oder in die kleine Leiste kommt.
  function isBig(p) {
    if (L.focus) return p.key === L.focus;
    switch (L.mode) {
      case 'allBig': return true;
      case 'allSmall': return false;
      case 'custom': return L.big.includes(p.key);
      default: return p.kind === 'stream';   // standard: Streams gross, Kameras klein
    }
  }
  function layout() {
    const grid = $('#grid'), strip = $('#strip');
    const bigOnes = [], smallOnes = [];
    for (const p of players.values()) (isBig(p) ? bigOnes : smallOnes).push(p);
    // DOM-Knoten nur umhaengen (kein Reconnect), Reihenfolge stabil nach Key
    const byKey = (a, b) => a.key.localeCompare(b.key);
    for (const p of bigOnes.sort(byKey)) { p.tile.classList.remove('small'); if (p.tile.parentNode !== grid) grid.append(p.tile); else grid.append(p.tile); }
    for (const p of smallOnes.sort(byKey)) { p.tile.classList.add('small'); if (p.tile.parentNode !== strip) strip.append(p.tile); else strip.append(p.tile); }
    for (const p of players.values()) p.updateButtons();

    // Leiste + Trennbalken bleiben sichtbar, sobald es Kacheln gibt, damit man immer etwas hineinziehen kann
    $('main').style.setProperty('--strip-h', `${L.stripH}px`);
    $('#strip-wrap').classList.toggle('hidden', players.size === 0);
    $('#splitter').classList.toggle('hidden', players.size === 0);
    $('#strip-empty').classList.toggle('hidden', smallOnes.length > 0);
    $('#grid-empty').classList.toggle('hidden', !(bigOnes.length === 0 && smallOnes.length > 0));
    fitGrid(bigOnes.length);

    for (const b of document.querySelectorAll('[data-mode]')) b.classList.toggle('active', b.dataset.mode === L.mode && !L.focus);
    $('#btn-cams').classList.toggle('active', L.hideCams);
    $('#btn-cams').textContent = L.hideCams ? '🎥 Kameras aus' : '🎥 Kameras an';
  }
  // Groesste 16:9-Kachelgroesse, mit der n Kacheln in die Rasterflaeche passen
  function fitGrid(n) {
    const grid = $('#grid'), area = $('#grid-area');
    if (!n) return;
    const gap = 10, W = area.clientWidth, H = area.clientHeight;
    let best = { cols: 1, w: 0 };
    for (let cols = 1; cols <= n; cols++) {
      const rows = Math.ceil(n / cols);
      const w = Math.min((W - gap * (cols - 1)) / cols, ((H - gap * (rows - 1)) / rows) * 16 / 9);
      if (w > best.w) best = { cols, w };
    }
    const w = Math.max(120, Math.floor(best.w)), h = Math.floor(w * 9 / 16);
    grid.style.setProperty('--cols', best.cols);
    grid.style.setProperty('--tile-w', w + 'px');
    grid.style.setProperty('--tile-h', h + 'px');
  }
  window.addEventListener('resize', layout);
  new ResizeObserver(() => fitGrid([...players.values()].filter(isBig).length)).observe($('#grid-area'));

  // Trennbalken: Hoehe der Leiste per Ziehen (Maus und Touch), Doppelklick = Standard
  {
    const sp = $('#splitter');
    const clamp = (v) => Math.max(90, Math.min(Math.floor($('main').clientHeight * 0.6), v));
    let drag = null;   // {startY, startH}
    sp.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      drag = { startY: e.clientY, startH: L.stripH };
      sp.classList.add('active'); document.body.classList.add('resizing');
    });
    window.addEventListener('pointermove', (e) => {
      if (!drag) return;
      L.stripH = clamp(drag.startH - (e.clientY - drag.startY));
      $('main').style.setProperty('--strip-h', `${L.stripH}px`);
      fitGrid([...players.values()].filter(isBig).length);
    });
    const end = () => { if (!drag) return; drag = null; sp.classList.remove('active'); document.body.classList.remove('resizing'); saveLayout(); };
    window.addEventListener('pointerup', end); window.addEventListener('pointercancel', end);
    sp.addEventListener('dblclick', () => { L.stripH = 160; saveLayout(); layout(); });
  }
  function setMode(mode) {
    L.mode = mode; L.focus = null;
    if (mode === 'custom' && !L.big.length) L.big = [...players.values()].filter((p) => p.kind === 'stream').map((p) => p.key);
    saveLayout(); layout();
  }
  // Verschieben ins Raster / in die Leiste -> Modus custom
  function moveTo(key, big) {
    if (L.focus) { L.focus = null; }
    if (L.mode !== 'custom') { L.big = [...players.values()].filter(isBig).map((p) => p.key); L.mode = 'custom'; }
    L.big = L.big.filter((k) => k !== key);
    if (big) L.big.push(key);
    saveLayout(); layout();
  }
  function toggleFocus(key) {
    L.focus = L.focus === key ? null : key;
    saveLayout(); layout();
  }
  function setAudio(key) {
    audioOn = audioOn === key ? null : key;
    for (const [k, p] of players) p.setAudio(k === audioOn);
  }
  function teardownAll() {
    for (const p of players.values()) p.destroy();
    players.clear();
    audioOn = null;
    $('#grid').replaceChildren();
    $('#strip .tile')?.remove();
  }
  for (const b of document.querySelectorAll('[data-mode]')) b.addEventListener('click', () => setMode(b.dataset.mode));
  $('#btn-cams').addEventListener('click', () => { L.hideCams = !L.hideCams; saveLayout(); refreshStreams(); });

  // Drag & Drop: Kacheln zwischen Raster und Leiste
  let dragKey = null;
  for (const zoneId of ['grid-area', 'strip']) {
    const zone = $('#' + zoneId);
    zone.addEventListener('dragover', (e) => { if (dragKey) { e.preventDefault(); zone.classList.add('drop'); } });
    zone.addEventListener('dragleave', () => zone.classList.remove('drop'));
    zone.addEventListener('drop', (e) => { e.preventDefault(); zone.classList.remove('drop'); if (dragKey) moveTo(dragKey, zoneId === 'grid-area'); dragKey = null; });
  }

  // ---------------------------------------------------------------- WHEP-Player
  class Player {
    constructor(item) {
      this.key = item.key; this.name = item.name; this.kind = item.kind;
      this.pc = null;
      this.location = null;
      this.dead = false;
      this.retry = null;
      this.video = el('video', { autoplay: '', muted: '', playsinline: '' });
      this.video.muted = true;
      this.video.addEventListener('dblclick', () => this.toggleFullscreen());
      this.fsBtn = el('button', { title: 'Vollbild', onclick: (e) => { e.stopPropagation(); this.toggleFullscreen(); } }, '⛶');
      this.audioBtn = el('button', { title: 'Ton', onclick: (e) => { e.stopPropagation(); setAudio(this.key); } }, '🔇');
      this.moveBtn = el('button', { title: 'Verschieben', onclick: (e) => { e.stopPropagation(); moveTo(this.key, this.tile.classList.contains('small')); } }, '⬇');
      this.focusBtn = el('button', { title: 'Nur dieses gross', onclick: (e) => { e.stopPropagation(); toggleFocus(this.key); } }, '⤢');
      this.state = el('span', { class: 'state' }, 'verbinde…');
      const badge = item.kind === 'cam' ? el('span', { class: 'badge-cam' }, '🎥') : el('span', { class: 'live' }, 'LIVE');
      this.tile = el('div', { class: 'tile' + (item.kind === 'cam' ? ' cam' : ''), draggable: 'true' }, this.video,
        el('div', { class: 'bar' }, el('span', { class: 'name' }, item.name), badge, this.state, this.fsBtn, this.focusBtn, this.moveBtn, ...(item.kind === 'cam' ? [] : [this.audioBtn])));
      // Eigene Kamera wie ein Spiegel anzeigen (nur lokal; gesendet wird unverspiegelt)
      if (item.kind === 'cam' && me && item.name === me.name) this.tile.classList.add('mirror');
      this.tile.addEventListener('dragstart', (e) => { dragKey = this.key; e.dataTransfer.effectAllowed = 'move'; this.tile.classList.add('dragging'); });
      this.tile.addEventListener('dragend', () => { this.tile.classList.remove('dragging'); dragKey = null; });
      (isBig(this) ? $('#grid') : $('#strip')).append(this.tile);
      this.connect();
    }
    toggleFullscreen() {
      if (document.fullscreenElement === this.tile) document.exitFullscreen?.();
      else this.tile.requestFullscreen?.().catch(() => {});
    }
    updateButtons() {
      const small = this.tile.classList.contains('small');
      this.moveBtn.textContent = small ? '⬆' : '⬇';
      this.moveBtn.title = small ? 'Ins grosse Raster' : 'In die Leiste';
      this.focusBtn.classList.toggle('on', L.focus === this.key);
    }
    setAudio(on) {
      this.video.muted = !on;
      this.audioBtn.textContent = on ? '🔊' : '🔇';
      this.audioBtn.classList.toggle('on', on);
      this.tile.classList.toggle('audio-on', on);
      if (on) this.video.play().catch(() => {});
    }
    async connect() {
      if (this.dead) return;
      this.cleanupPc();
      const pc = (this.pc = new RTCPeerConnection());
      pc.addTransceiver('video', { direction: 'recvonly' });
      if (this.kind !== 'cam') pc.addTransceiver('audio', { direction: 'recvonly' });
      pc.ontrack = (ev) => { if (ev.streams[0] && this.video.srcObject !== ev.streams[0]) this.video.srcObject = ev.streams[0]; };
      pc.onconnectionstatechange = () => {
        const s = pc.connectionState;
        this.state.textContent = s === 'connected' ? '' : s;
        if (s === 'failed' || s === 'disconnected' || s === 'closed') this.scheduleRetry();
      };
      try {
        await pc.setLocalDescription(await pc.createOffer());
        await new Promise((res) => {
          if (pc.iceGatheringState === 'complete') return res();
          const t = setTimeout(res, 2000);
          pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') { clearTimeout(t); res(); } };
        });
        const r = await fetch(`/${encodeURIComponent(this.key)}/whep`, {
          method: 'POST', headers: { 'Content-Type': 'application/sdp', Authorization: `Bearer ${viewerToken}` }, body: pc.localDescription.sdp,
        });
        if (r.status !== 201) throw new Error(`whep ${r.status}`);
        this.location = r.headers.get('Location');
        await pc.setRemoteDescription({ type: 'answer', sdp: await r.text() });
        this.video.play().catch(() => {});
      } catch (err) {
        this.state.textContent = 'Fehler: ' + err.message;
        this.scheduleRetry();
      }
    }
    scheduleRetry() {
      if (this.dead || this.retry) return;
      this.retry = setTimeout(() => { this.retry = null; this.connect(); }, 3000);
    }
    cleanupPc() {
      if (this.location) { fetch(this.location, { method: 'DELETE' }).catch(() => {}); this.location = null; }
      if (this.pc) { this.pc.onconnectionstatechange = null; this.pc.close(); this.pc = null; }
    }
    destroy() {
      this.dead = true;
      if (this.retry) clearTimeout(this.retry);
      this.cleanupPc();
      this.video.srcObject = null;
      this.tile.remove();
    }
  }

  // ---------------------------------------------------------------- Dialoge
  const dlgKey = $('#dlg-key');
  const dlgUsers = $('#dlg-users');
  document.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => b.closest('dialog').close()));
  document.querySelectorAll('[data-copy]').forEach((b) => b.addEventListener('click', async () => {
    const inp = $('#' + b.dataset.copy);
    inp.select();
    try { await navigator.clipboard.writeText(inp.value); b.textContent = 'Kopiert ✓'; setTimeout(() => (b.textContent = 'Kopieren'), 1500); } catch {}
  }));

  async function openKey() {
    me = await api('GET', '/api/me');
    $('#key-url').value = me.whipUrl;
    $('#key-token').value = `${me.name}:${me.streamKey}`;
    dlgKey.showModal();
  }
  $('#btn-key').addEventListener('click', openKey);
  $('#key-rotate').addEventListener('click', async () => {
    if (!confirm('Neuen Stream-Key erzeugen? Der alte funktioniert dann nicht mehr, OBS muss neu eingerichtet werden.')) return;
    await api('POST', '/api/me/streamkey');
    await openKey();
  });

  async function openUsers() {
    const users = await api('GET', '/api/users');
    const tb = $('#users-table tbody');
    tb.replaceChildren(...users.map((u) => el('tr', {},
      el('td', {}, u.name, u.name === me.name ? ' (du)' : ''),
      el('td', { class: u.status === 'approved' ? 'st-approved' : 'st-pending' }, u.status === 'approved' ? 'freigegeben' : 'wartet'),
      el('td', {},
        ...(u.status === 'pending' ? [el('button', { onclick: async () => { await api('POST', `/api/users/${u.id}/approve`); openUsers(); } }, 'Freigeben')] : []),
        ...(u.name !== me.name ? [el('button', { class: 'secondary', onclick: async () => {
          if (!confirm(`Passwort von ${u.name} zuruecksetzen? Das alte gilt dann nicht mehr.`)) return;
          const r = await api('POST', `/api/users/${u.id}/resetpw`);
          prompt(`Neues Startpasswort fuer ${u.name} (per Discord weitergeben, danach unter "Passwort" aendern):`, r.tempPassword);
        } }, 'Passwort')] : []),
        ...(u.name !== me.name ? [el('button', { class: 'danger', onclick: async () => {
          if (confirm(`${u.name} wirklich löschen?`)) { await api('POST', `/api/users/${u.id}/delete`); openUsers(); }
        } }, 'Löschen')] : []),
      ),
    )));
    if (!dlgUsers.open) dlgUsers.showModal();
  }
  $('#btn-users').addEventListener('click', openUsers);

  const dlgPw = $('#dlg-pw');
  $('#btn-pw').addEventListener('click', () => { $('#form-pw').reset(); $('#pw-error').textContent = ''; dlgPw.showModal(); });
  $('#form-pw').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      await api('POST', '/api/me/password', { oldPassword: f.get('oldPassword'), newPassword: f.get('newPassword') });
      dlgPw.close();
      alert('Passwort geändert.');
    } catch (err) {
      $('#pw-error').textContent = err.code === 'bad_credentials' ? 'Aktuelles Passwort ist falsch.' : (ERR[err.code] || err.message);
    }
  });

  boot();
})();
