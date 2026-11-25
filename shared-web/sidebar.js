/* Ronic JustTerminal: sidebar (folders + history).
 *
  * Folders: mirrors the current directory of the active tab's shell (cd → the tree follows) and lets
  * you navigate by clicking (a click on a folder types the "cd" into the terminal). The current
  * directory comes from the native app ("cwd", macOS) or from the shell itself via OSC 7 / OSC 9;9.
 *
  * History: the typed commands (captured in app.js), with Copy and Insert buttons.
 *
  * This file never talks to the system: everything goes through the `api` provided by app.js.
 */
'use strict';

window.createSidebar = function createSidebar(api) {
  const $ = (sel) => document.querySelector(sel);
  const treeEl = $('#sb-folders .tree');
  const crumbsEl = $('#sb-folders .crumbs');
  const placesEl = $('#sb-places .places');
  const historyEl = $('#sb-history .history');
  const filterEl = $('#history-filter');

  const cache = new Map();     // "host|caminho" → { entries, error, stale }
  const pending = new Map();   // reqId → cache key
  let nextReq = 1;
  let selectedPath = null;
  let lastCwdKey = '';

  const ICON_DIR = '<svg viewBox="0 0 16 16"><path d="M1.75 4.25c0-.55.45-1 1-1h3.4l1.5 1.5h5.6c.55 0 1 .45 1 1v6.5c0 .55-.45 1-1 1H2.75c-.55 0-1-.45-1-1z"/></svg>';
  const ICON_FILE = '<svg viewBox="0 0 16 16"><path d="M4 1.75h5l3 3v9.5H4z"/><path d="M9 1.75v3h3"/></svg>';
  const ICON_HOME = '<svg viewBox="0 0 16 16"><path d="M2.5 7.25 8 2.75l5.5 4.5M4 6.25v7h8v-7"/></svg>';
  const ICON_DISK = '<svg viewBox="0 0 16 16"><rect x="2" y="4" width="12" height="8" rx="1.5"/><path d="M4.5 9.5h.01"/></svg>';
  const ICON_STAR = '<svg viewBox="0 0 16 16"><path d="m8 2 1.8 3.8 4.2.5-3.1 2.9.8 4.1L8 11.3l-3.7 2 .8-4.1L2 6.3l4.2-.5z"/></svg>';
  const ICON_COPY = '<svg viewBox="0 0 16 16"><rect x="5.25" y="5.25" width="8" height="8" rx="1.5"/><path d="M10.75 5.25v-1.5c0-.55-.45-1-1-1h-6c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h1.5"/></svg>';
  const ICON_INSERT = '<svg viewBox="0 0 16 16"><path d="M2.5 8h8.5M8 4.75 11.25 8 8 11.25M13.5 3v10"/></svg>';

  // ------------------------------------------------------------ caminhos

  /** Path context of a tab: style (posix or win), tree root, home, current directory. */
  function context(tab) {
    const profile = api.profileOf(tab);
    const style = profile.kind === 'powershell' || profile.kind === 'cmd' ? 'win' : 'posix';
    const home = profile.home || (style === 'posix' && api.state.platform !== 'win' ? api.state.home : '') || '';
    const cwd = tab.cwd || '';
    const ref = cwd || home;
    let root = rootOf(ref || (style === 'win' ? 'C:\\' : '/'), style);
    if (home && (!cwd || isUnder(cwd, home, style))) root = home;
    return { tab, profile, style, home, cwd, root, host: tab.cwdHost || '' };
  }

  function sep(style) { return style === 'win' ? '\\' : '/'; }

  function normalize(path, style) {
    if (style === 'win') {
      let p = path.replace(/\//g, '\\');
      if (/^[A-Za-z]:$/.test(p)) p += '\\';
      if (p.length > 3 && p.endsWith('\\')) p = p.slice(0, -1);
      return p;
    }
    return path.length > 1 && path.endsWith('/') ? path.slice(0, -1) : path;
  }

  function rootOf(path, style) {
    if (style === 'win') {
      const m = /^([A-Za-z]:)/.exec(path);
      if (m) return `${m[1].toUpperCase()}\\`;
      const unc = /^(\\\\[^\\]+\\[^\\]+)/.exec(path);
      return unc ? unc[1] : 'C:\\';
    }
    return '/';
  }

  function isUnder(path, base, style) {
    const a = style === 'win' ? path.toLowerCase() : path;
    const b = style === 'win' ? base.toLowerCase() : base;
    if (a === b) return true;
    const s = sep(style);
    return a.startsWith(b.endsWith(s) ? b : b + s);
  }

  function join(parent, name, style) {
    const s = sep(style);
    return parent.endsWith(s) ? parent + name : parent + s + name;
  }

  function baseName(path, style) {
    const s = sep(style);
    const p = path.endsWith(s) && path.length > 1 ? path.slice(0, -1) : path;
    const i = p.lastIndexOf(s);
    return i >= 0 ? p.slice(i + 1) || p : p;
  }

  /** Folders between `root` and `path` (inclusive), to expand the tree down to the current directory. */
  function chain(root, path, style) {
    if (!isUnder(path, root, style)) return [root];
    const s = sep(style);
    const rest = path.slice(root.length).split(s).filter(Boolean);
    const out = [root];
    let cur = root;
    for (const part of rest) { cur = join(cur, part, style); out.push(cur); }
    return out;
  }

  /** Converts a Windows path (C:\x) into the format of the tab's posix shell (WSL / Git Bash). */
  function toShellPath(path, ctx) {
    if (ctx.style === 'win' || !/^[A-Za-z]:\\/.test(path)) return path;
    const drive = path[0].toLowerCase();
    const rest = path.slice(3).replace(/\\/g, '/');
    if (ctx.profile.flavor === 'wsl') return `/mnt/${drive}/${rest}`.replace(/\/$/, '');
    return `/${drive}/${rest}`.replace(/\/$/, '');
  }

  /** "cd" command in the shell's dialect. The prefix clears whatever is typed on the line. */
  function cdCommand(path, ctx) {
    switch (ctx.profile.kind) {
      case 'powershell': return `\x1bSet-Location -LiteralPath '${path.replace(/'/g, "''")}'\r`;
      case 'cmd': return `\x1bcd /d "${path}"\r`;
      default: return `\x05\x15cd -- '${path.replace(/'/g, "'\\''")}'\r`;
    }
  }

  /** Path ready to paste into a command (quoted when needed). */
  function quoted(path, ctx) {
    if (/^[\w@%+=:,./\\~-]+$/.test(path)) return path;
    if (ctx.profile.kind === 'powershell') return `'${path.replace(/'/g, "''")}'`;
    if (ctx.profile.kind === 'cmd') return `"${path}"`;
    return `'${path.replace(/'/g, "'\\''")}'`;
  }

  // ---------------------------------------------------------- listagens

  const cacheKey = (ctx, path) => `${ctx.tab.id}|${ctx.host}|${path}`;

  function request(ctx, path, force = false) {
    const key = cacheKey(ctx, path);
    const entry = cache.get(key);
    if (entry && !entry.stale && !force) return;
    if ([...pending.values()].includes(key)) return;
    const reqId = nextReq++;
    pending.set(reqId, key);
    api.host.post({ t: 'listDir', reqId, id: ctx.tab.id, path, host: ctx.host });
  }

  function onDirList(msg) {
    const key = pending.get(msg.reqId);
    if (!key) return;
    pending.delete(msg.reqId);
    cache.set(key, { entries: msg.entries || [], error: msg.error || '', stale: false });
    renderTree();
  }

  function invalidate(ctx, path) {
    const entry = cache.get(cacheKey(ctx, path));
    if (entry) entry.stale = true;
    request(ctx, path, true);
  }

  // --------------------------------------------------------------- tree

  function renderTree() {
    const tab = api.activeTab();
    if (!tab) { treeEl.replaceChildren(); crumbsEl.replaceChildren(); return; }
    const ctx = context(tab);
    const frag = document.createDocumentFragment();
    const rootLabel = ctx.home && ctx.root === ctx.home ? baseName(ctx.home, ctx.style) || '~' : ctx.root;
    renderNode(frag, ctx, ctx.root, rootLabel, 0, ICON_HOME);
    treeEl.replaceChildren(frag);
    renderCrumbs(ctx);
  }

  function renderNode(frag, ctx, path, label, depth, icon, hidden = false) {
    const s = api.state.settings;
    const open = ctx.tab.expanded.has(path);
    const row = document.createElement('div');
    row.className = 'node dir';
    row.classList.toggle('hidden-entry', hidden);
    row.classList.toggle('open', open);
    row.classList.toggle('current', path === ctx.cwd);
    row.classList.toggle('selected', path === selectedPath && path !== ctx.cwd);
    row.dataset.path = path;
    row.dataset.kind = 'dir';
    row.style.paddingLeft = `${4 + depth * 13}px`;
    row.title = path;
    row.innerHTML = `<span class="chev"></span>${icon || ICON_DIR}<span class="name"></span>`;
    row.lastChild.textContent = label;
    row.setAttribute('role', 'treeitem');
    row.setAttribute('aria-expanded', String(open));
    frag.appendChild(row);
    if (!open) return;

    const entry = cache.get(cacheKey(ctx, path));
    if (!entry) {
      request(ctx, path);
      frag.appendChild(note('carregando…', depth + 1));
      return;
    }
    if (entry.stale) request(ctx, path);
    if (entry.error) { frag.appendChild(note(entry.error, depth + 1)); return; }

    let shown = 0;
    for (const e of entry.entries) {
      const childPath = join(path, e.n, ctx.style);
      // Hidden entries only show up with the "eye" on, except on the path to the current directory.
      if (e.h && !s.showHidden && !(e.d && ctx.cwd && isUnder(ctx.cwd, childPath, ctx.style))) continue;
      if (e.d) {
        renderNode(frag, ctx, childPath, e.n, depth + 1, null, !!e.h);
      } else if (s.showFiles) {
        const f = document.createElement('div');
        f.className = 'node file';
        f.classList.toggle('hidden-entry', !!e.h);
        const fp = childPath;
        f.classList.toggle('selected', fp === selectedPath);
        f.dataset.path = fp;
        f.dataset.kind = 'file';
        f.style.paddingLeft = `${4 + (depth + 1) * 13}px`;
        f.title = `${fp}\nDuplo clique: inserir no terminal`;
        f.innerHTML = `<span class="chev"></span>${ICON_FILE}<span class="name"></span>`;
        f.lastChild.textContent = e.n;
        frag.appendChild(f);
      } else {
        continue;
      }
      shown++;
    }
    if (!shown) frag.appendChild(note(entry.entries.length ? 'só itens ocultos' : 'pasta vazia', depth + 1));
  }

  function note(text, depth) {
    const n = document.createElement('div');
    n.className = 'node note';
    n.style.paddingLeft = `${4 + depth * 13 + 19}px`;
    n.textContent = text;
    return n;
  }

  function renderCrumbs(ctx) {
    const target = ctx.cwd || ctx.root;
    const parts = [];
    let start = rootOf(target, ctx.style);
    let label = ctx.style === 'win' ? start.replace(/\\$/, '') : '/';
    if (ctx.home && isUnder(target, ctx.home, ctx.style)) { start = ctx.home; label = '~'; }
    for (const p of chain(start, target, ctx.style)) {
      parts.push({ path: p, label: p === start ? label : baseName(p, ctx.style) });
    }
    const frag = document.createDocumentFragment();
    parts.forEach((part, i) => {
      if (i > 0) {
        const s = document.createElement('span');
        s.className = 'sep';
        s.textContent = '›';
        frag.appendChild(s);
      }
      const b = document.createElement('button');
      b.textContent = part.label;
      b.title = part.path;
      b.addEventListener('click', () => navigate(part.path));
      frag.appendChild(b);
    });
    crumbsEl.replaceChildren(frag);
    crumbsEl.scrollLeft = crumbsEl.scrollWidth;
  }

  function scrollToCurrent() {
    requestAnimationFrame(() => {
      const cur = treeEl.querySelector('.node.current');
      if (cur) cur.scrollIntoView({ block: 'nearest' });
    });
  }

  // ------------------------------------------------------------- actions

  function navigate(path) {
    const tab = api.activeTab();
    if (!tab || tab.exited) return;
    const ctx = context(tab);
    selectedPath = path;
    tab.expanded.add(path);
    api.run(tab, cdCommand(toShellPath(path, ctx), ctx));
    renderTree();
  }

  function insertPath(path) {
    const tab = api.activeTab();
    if (!tab) return;
    api.insert(`${quoted(toShellPath(path, context(tab)), context(tab))} `);
  }

  function toggle(path) {
    const tab = api.activeTab();
    if (!tab) return;
    if (tab.expanded.has(path)) tab.expanded.delete(path);
    else tab.expanded.add(path);
    renderTree();
  }

  function rowMenu(ev, path, kind) {
    const tab = api.activeTab();
    if (!tab) return;
    const ctx = context(tab);
    const favs = api.state.settings.favorites || [];
    const isFav = favs.includes(path);
    const reveal = api.state.platform === 'mac' ? 'Mostrar no Finder' : 'Mostrar no Explorador';
    const items = [];
    if (kind === 'dir') {
      items.push({ label: 'Abrir no terminal (cd)', run: () => navigate(path) });
      items.push({ label: 'Nova aba aqui', run: () => api.newTab(tab.profile, toShellPath(path, ctx)) });
      items.push('-');
    }
    items.push({ label: 'Inserir caminho no terminal', run: () => insertPath(path) });
    items.push({ label: 'Copiar caminho', run: () => { api.copy(path); api.toast('Caminho copiado'); } });
    items.push({ label: reveal, run: () => api.host.post({ t: 'reveal', id: tab.id, path, host: ctx.host }) });
    if (kind === 'dir') {
      items.push('-');
      items.push(isFav
        ? { label: 'Remover dos locais', run: () => api.setSetting('favorites', favs.filter((f) => f !== path)) }
        : { label: 'Adicionar aos locais', run: () => api.setSetting('favorites', [...favs, path]) });
    }
    api.openMenu(ev.clientX, ev.clientY, items);
  }

  treeEl.addEventListener('click', (ev) => {
    const row = ev.target.closest('.node[data-path]');
    if (!row) return;
    const path = row.dataset.path;
    if (row.dataset.kind === 'dir' && ev.target.closest('.chev')) return toggle(path);
    if (row.dataset.kind === 'dir') return navigate(path);
    selectedPath = path;
    renderTree();
  });
  treeEl.addEventListener('dblclick', (ev) => {
    const row = ev.target.closest('.node.file[data-path]');
    if (row) insertPath(row.dataset.path);
  });
  treeEl.addEventListener('contextmenu', (ev) => {
    ev.preventDefault();
    const row = ev.target.closest('.node[data-path]');
    if (row) rowMenu(ev, row.dataset.path, row.dataset.kind);
  });

  // ------------------------------------------------------------- locais

  function renderPlaces() {
    const tab = api.activeTab();
    const ctx = tab ? context(tab) : null;
    const frag = document.createDocumentFragment();
    const favs = (api.state.settings.favorites || []).map((p) => ({ name: null, path: p, icon: 'star' }));
    for (const place of [...(api.state.places || []), ...favs]) {
      const row = document.createElement('div');
      row.className = 'node dir';
      const path = ctx ? toShellPath(place.path, ctx) : place.path;
      row.dataset.path = path;
      row.dataset.kind = 'dir';
      row.title = place.path;
      row.classList.toggle('current', !!ctx && path === ctx.cwd);
      const icon = place.icon === 'home' ? ICON_HOME : place.icon === 'disk' ? ICON_DISK : place.icon === 'star' ? ICON_STAR : ICON_DIR;
      row.innerHTML = `${icon}<span class="name"></span>`;
      row.lastChild.textContent = place.name || baseName(place.path, /^[A-Za-z]:/.test(place.path) ? 'win' : 'posix');
      frag.appendChild(row);
    }
    placesEl.replaceChildren(frag);
  }

  placesEl.addEventListener('click', (ev) => {
    const row = ev.target.closest('.node[data-path]');
    if (row) navigate(row.dataset.path);
  });
  placesEl.addEventListener('contextmenu', (ev) => {
    ev.preventDefault();
    const row = ev.target.closest('.node[data-path]');
    if (row) rowMenu(ev, row.dataset.path, 'dir');
  });

  // ----------------------------------------------------------- history

  /** Visible history: the active tab's (default) or every tab's, without duplicates. */
  function visibleHistory() {
    const tab = api.activeTab();
    if (api.state.settings.historyScope !== 'all') {
      return tab ? api.state.history.filter((h) => h.tab === tab.id && h.run === api.state.runId) : [];
    }
    const seen = new Set();
    return api.state.history.filter((h) => !seen.has(h.cmd) && seen.add(h.cmd));
  }

  function renderHistory() {
    const q = filterEl.value.trim().toLowerCase();
    const scope = api.state.settings.historyScope === 'all' ? 'all' : 'tab';
    document.querySelectorAll('#history-scope button').forEach((b) => b.classList.toggle('on', b.dataset.value === scope));
    const items = visibleHistory().filter((h) => !q || h.cmd.toLowerCase().includes(q));
    const frag = document.createDocumentFragment();
    for (const h of items.slice(0, 300)) {
      const li = document.createElement('li');
      const when = new Date(h.at);
      li.title = `${h.cmd}\n${h.cwd ? `em ${h.cwd}\n` : ''}${when.toLocaleString()}\nDuplo clique: inserir no terminal`;
      li.innerHTML = `<code></code><span class="actions">
        <button class="icon-btn tiny copy" title="Copiar" aria-label="Copiar">${ICON_COPY}</button>
        <button class="icon-btn tiny insert" title="Inserir no terminal" aria-label="Inserir no terminal">${ICON_INSERT}</button>
      </span>`;
      li.firstChild.textContent = h.cmd;
      li.dataset.cmd = h.cmd;
      frag.appendChild(li);
    }
    if (!items.length) {
      const li = document.createElement('li');
      li.className = 'empty';
      li.textContent = q ? 'Nada encontrado'
        : scope === 'tab' ? 'Os comandos digitados nesta aba aparecem aqui' : 'Os comandos que você digitar aparecem aqui';
      frag.appendChild(li);
    }
    historyEl.replaceChildren(frag);
  }

  historyEl.addEventListener('click', (ev) => {
    const li = ev.target.closest('li[data-cmd]');
    if (!li) return;
    if (ev.target.closest('.copy')) { api.copy(li.dataset.cmd); api.toast('Comando copiado'); }
    else if (ev.target.closest('.insert')) api.insert(li.dataset.cmd);
  });
  historyEl.addEventListener('dblclick', (ev) => {
    const li = ev.target.closest('li[data-cmd]');
    if (li && !ev.target.closest('.actions')) api.insert(li.dataset.cmd);
  });
  filterEl.addEventListener('input', renderHistory);
  $('#history-scope').addEventListener('click', (ev) => {
    const b = ev.target.closest('button');
    if (b) api.setSetting('historyScope', b.dataset.value);
  });
  filterEl.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') {
      const first = historyEl.querySelector('li[data-cmd]');
      if (first) api.insert(first.dataset.cmd);
    } else if (ev.key === 'Escape') {
      filterEl.value = '';
      renderHistory();
      api.focusTerminal();
    }
  });

  let clearArmed = 0;
  $('#clear-history').addEventListener('click', (ev) => {
    const btn = ev.currentTarget;
    if (!clearArmed) {
      btn.classList.add('armed');
      btn.title = 'Clique de novo para limpar';
      clearArmed = setTimeout(() => { clearArmed = 0; btn.classList.remove('armed'); btn.title = 'Limpar histórico'; }, 2500);
      return;
    }
    clearTimeout(clearArmed);
    clearArmed = 0;
    btn.classList.remove('armed');
    api.clearHistory();
    api.toast('Histórico limpo');
  });

  // ------------------------------------------------ sections, buttons, width

  for (const section of document.querySelectorAll('.sb-section')) {
    section.querySelector('.sb-toggle').addEventListener('click', () => {
      const key = `collapsed_${section.id}`;
      api.setSetting(key, !api.state.settings[key]);
    });
  }
  $('#toggle-hidden').addEventListener('click', () => api.setSetting('showHidden', !api.state.settings.showHidden));
  $('#toggle-files').addEventListener('click', () => api.setSetting('showFiles', !api.state.settings.showFiles));
  $('#refresh-tree').addEventListener('click', () => {
    cache.clear();
    renderTree();
  });

  const resizer = $('#sb-resizer');
  resizer.addEventListener('pointerdown', (ev) => {
    ev.preventDefault();
    resizer.setPointerCapture(ev.pointerId);
    resizer.classList.add('dragging');
    const startX = ev.clientX;
    const startW = api.state.settings.sidebarWidth;
    const move = (e) => {
      const w = Math.round(Math.min(520, Math.max(170, startW + e.clientX - startX)));
      document.documentElement.style.setProperty('--sidebar-w', `${w}px`);
      api.state.settings.sidebarWidth = w;
    };
    const up = () => {
      resizer.classList.remove('dragging');
      resizer.removeEventListener('pointermove', move);
      resizer.removeEventListener('pointerup', up);
      api.setSetting('sidebarWidth', api.state.settings.sidebarWidth);
    };
    resizer.addEventListener('pointermove', move);
    resizer.addEventListener('pointerup', up);
  });

  function applySettings() {
    const s = api.state.settings;
    document.documentElement.classList.toggle('no-sidebar', !s.showSidebar);
    document.documentElement.style.setProperty('--sidebar-w', `${s.sidebarWidth}px`);
    $('#sidebar-btn').classList.toggle('on', s.showSidebar);
    $('#toggle-hidden').classList.toggle('on', s.showHidden);
    $('#toggle-files').classList.toggle('on', s.showFiles);
    for (const section of document.querySelectorAll('.sb-section')) {
      section.classList.toggle('collapsed', !!s[`collapsed_${section.id}`]);
    }
    renderPlaces();
    renderTree();
    renderHistory();
  }

  // ------------------------------------------------ events coming from app.js

  /** The active tab changed or its current directory changed: expand down to it and scroll to it. */
  function syncToTab(tab) {
    if (!tab || tab.id !== (api.activeTab() || {}).id) return;
    const ctx = context(tab);
    if (ctx.cwd) {
      for (const p of chain(ctx.root, ctx.cwd, ctx.style)) tab.expanded.add(p);
    } else {
      tab.expanded.add(ctx.root);
    }
    const key = `${tab.id}|${ctx.cwd}`;
    const moved = key !== lastCwdKey;
    lastCwdKey = key;
    if (moved && ctx.cwd) invalidate(ctx, ctx.cwd);
    renderPlaces();
    renderTree();
    renderHistory();
    if (moved) scrollToCurrent();
  }

  /** A command finished (prompt is back): the current directory may have new files. */
  function onPrompt(tab) {
    if (!tab || tab.id !== (api.activeTab() || {}).id || !tab.cwd) return;
    invalidate(context(tab), tab.cwd);
  }

  function forgetTab(tab) {
    for (const key of [...cache.keys()]) if (key.startsWith(`${tab.id}|`)) cache.delete(key);
  }

  return { applySettings, syncToTab, onPrompt, onDirList, renderHistory, renderPlaces, forgetTab };
};
