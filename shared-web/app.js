/* Ronic JustTerminal: shared UI (tabs, settings, shortcuts).
 *
  * This page knows NOTHING about PTYs or the operating system. It talks to the native app through
  * JSON messages (contract in docs/BRIDGE.md):
 *   macOS   → window.webkit.messageHandlers.jt.postMessage(json)   (Swift, WKWebView)
 *   Windows → window.chrome.webview.postMessage(json)               (C#, WebView2)
  *   browser (no native app) → demo mode with a local "echo", handy for working on the UI.
  * The native app answers by calling JT.recv(msg) / JT.data(id, base64).
 */
'use strict';

(() => {
  // ------------------------------------------------------------------ host
  const macHost = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.jt;
  const winHost = window.chrome && window.chrome.webview;

  const host = {
    post(msg) {
      const json = JSON.stringify(msg);
      if (macHost) macHost.postMessage(json);
      else if (winHost) winHost.postMessage(json);
      else Demo.handle(msg);
    },
  };

  // --------------------------------------------------------------- estado
  const DEFAULTS = {
    opacity: 1,            // 1 = fully dark (default); lower = more glass
    fontSize: 13,
    fontFamily: '',
    lineHeight: 1.2,
    cursorStyle: 'bar',
    cursorBlink: true,
    defaultProfile: '',
    copyOnSelect: false,
    optionAsMeta: false,
    scrollback: 10000,
    showSidebar: true,     // sidebar with folders and history
    sidebarWidth: 248,
    showHidden: false,
    showFiles: true,
    favorites: [],
    historyScope: 'tab',   // sidebar history: 'tab' (this tab) or 'all' (every tab)
    fullPathPrompt: true,  // macOS: the prompt shows the full path, like on Windows
  };

  const HISTORY_MAX = 300;

  const FONT_STACK = {
    mac: '"SF Mono", Menlo, Monaco, monospace',
    win: '"Cascadia Mono", "Cascadia Code", Consolas, "Courier New", monospace',
    browser: '"SF Mono", "Cascadia Mono", Menlo, Consolas, monospace',
  };

  const THEME = {
    background: '#00000000',
    foreground: '#e6edf3',
    cursor: '#3cf59a',
    cursorAccent: '#0b0d0e',
    selectionBackground: 'rgba(60, 245, 154, 0.28)',
    selectionInactiveBackground: 'rgba(230, 237, 243, 0.14)',
    scrollbarSliderBackground: 'rgba(255, 255, 255, 0.10)',
    scrollbarSliderHoverBackground: 'rgba(255, 255, 255, 0.18)',
    scrollbarSliderActiveBackground: 'rgba(60, 245, 154, 0.35)',
    black: '#1b1f23', red: '#ff6b6b', green: '#3cf59a', yellow: '#f7d774',
    blue: '#6cb6ff', magenta: '#d2a8ff', cyan: '#5ee7df', white: '#c9d1d9',
    brightBlack: '#6e7681', brightRed: '#ff8e8e', brightGreen: '#7cffbe', brightYellow: '#ffe89a',
    brightBlue: '#9ccbff', brightMagenta: '#e2c5ff', brightCyan: '#8bf3ec', brightWhite: '#ffffff',
  };

  const MAX_WEBGL = 6;          // contextos WebGL vivos (o navegador limita ~16)
  const ACK_CHUNK = 32 * 1024;  // flow control: acknowledges bytes already drawn

  const state = {
    platform: macHost ? 'mac' : winHost ? 'win' : 'browser',
    settings: { ...DEFAULTS },
    profiles: [],
    version: '',
    windowsBuild: 0,
    tabs: [],
    activeId: null,
    nextId: 1,
    webglLRU: [],
    webglBroken: false,
    home: '',
    places: [],
    history: [],          // [{ cmd, cwd, at, tab, run }], most recent first
    runId: Date.now().toString(36) + Math.random().toString(36).slice(2, 6), // tells tabs apart across app runs
  };

  const $ = (sel) => document.querySelector(sel);
  const tabsEl = $('#tabs');
  const panesEl = $('#panes');
  const settingsEl = $('#settings');
  const menuEl = $('#menu');

  document.documentElement.classList.add(state.platform);

  // ------------------------------------------------------------ utilidades
  function b64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function debounce(fn, ms) {
    let t = 0;
    return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
  }

  const tabById = (id) => state.tabs.find((t) => t.id === id);
  const activeTab = () => tabById(state.activeId);
  const profileName = (id) => (state.profiles.find((p) => p.id === id) || {}).name || 'shell';
  const profileOf = (tab) => state.profiles.find((p) => p.id === tab.profile) || { kind: 'posix' };

  function fontFamily() {
    const custom = (state.settings.fontFamily || '').trim();
    const stack = FONT_STACK[state.platform];
    return custom ? `${/[\s,"]/.test(custom) && !custom.includes('"') ? `"${custom}"` : custom}, ${stack}` : stack;
  }

  function termOptions() {
    const s = state.settings;
    const opts = {
      allowTransparency: true,
      allowProposedApi: true,
      fontFamily: fontFamily(),
      fontSize: s.fontSize,
      lineHeight: s.lineHeight,
      cursorStyle: s.cursorStyle,
      cursorBlink: s.cursorBlink,
      cursorInactiveStyle: 'outline',
      scrollback: s.scrollback,
      macOptionIsMeta: s.optionAsMeta,
      macOptionClickForcesSelection: true,
      rightClickSelectsWord: false,
      drawBoldTextInBrightColors: true,
      minimumContrastRatio: 1,
      smoothScrollDuration: 0,
      theme: THEME,
    };
    if (state.platform === 'win') opts.windowsPty = { backend: 'conpty', buildNumber: state.windowsBuild || 19045 };
    return opts;
  }

  // ------------------------------------------------------------------ tabs
  function newTab(profile, cwd) {
    const id = state.nextId++;
    profile = profile || state.settings.defaultProfile || (state.profiles[0] && state.profiles[0].id) || '';

    const el = document.createElement('div');
    el.className = 'pane';
    panesEl.appendChild(el);

    const term = new Terminal(termOptions());
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon.WebLinksAddon((ev, uri) => {
      if (ev.metaKey || ev.ctrlKey) host.post({ t: 'openUrl', url: uri });
    }));
    const unicode = new Unicode11Addon.Unicode11Addon();
    term.loadAddon(unicode);
    term.unicode.activeVersion = '11';
    term.open(el);

    const tab = {
      id, profile, el, term, fit,
      shellTitle: '',     // title set by the shell itself (OSC 0/2)
      customTitle: '',    // title given by the user (rename)
      cwd: '',            // current directory (native on macOS; OSC 7 / 9;9 on Windows)
      cwdHost: '',
      expanded: new Set(),
      promptMark: null,   // where the prompt ends: the typed command starts there
      typedSinceMark: false,
      markTimer: 0,
      integration: false, // the shell marks its prompt with OSC 133 (more accurate)
      webgl: null,
      activity: false,
      exited: false,
      startedAt: performance.now(),
      ackBytes: 0,
      ackTimer: 0,
    };

    term.onData((data) => { trackInput(tab, data); host.post({ t: 'input', id, data }); });
    term.onBinary((data) => host.post({ t: 'input', id, data, binary: true }));
    term.onResize(({ cols, rows }) => host.post({ t: 'resize', id, cols, rows }));
    term.onTitleChange((title) => { tab.shellTitle = title || ''; renderTabs(); });

    // Shell integration (OSC sequences the shell itself emits in its prompt):
    //   OSC 7    file://host/path     → current directory (configured zsh/bash/fish, WSL, Git Bash)
    //   OSC 9;9  "C:\path"            → current directory (PowerShell/cmd, the Windows Terminal convention)
    //   OSC 133  A/B                  → prompt start/end (exact capture of the typed command)
    term.parser.registerOscHandler(7, (data) => {
      const m = /^file:\/\/([^/]*)(\/.*)$/.exec(data);
      if (m) {
        let path = m[2];
        try { path = decodeURIComponent(path); } catch (_) { /* keep it as it came */ }
        if (/^\/[A-Za-z]:/.test(path)) path = path.slice(1).replace(/\//g, '\\');
        setCwd(tab, path, profileOf(tab).flavor === 'wsl' ? m[1] : '');
      }
      return true;
    });
    term.parser.registerOscHandler(9, (data) => {
      if (!data.startsWith('9;')) return false;
      setCwd(tab, data.slice(2).trim().replace(/^"(.*)"$/, '$1'), '');
      return true;
    });
    term.parser.registerOscHandler(133, (data) => {
      tab.integration = true;
      if (data[0] === 'B') markPrompt(tab);
      return true;
    });
    term.onSelectionChange(() => {
      if (state.settings.copyOnSelect && term.hasSelection()) host.post({ t: 'copy', text: term.getSelection() });
    });
    el.addEventListener('contextmenu', (ev) => { ev.preventDefault(); openContextMenu(ev.clientX, ev.clientY); });

    state.tabs.push(tab);
    activate(id);
    host.post({ t: 'spawn', id, profile, cwd: cwd || '', cols: term.cols, rows: term.rows });
    return tab;
  }

  function activate(id) {
    const tab = tabById(id);
    if (!tab) return;
    const prev = activeTab();
    if (prev && prev !== tab) prev.el.classList.remove('active');
    state.activeId = id;
    tab.activity = false;
    tab.el.classList.add('active');
    ensureWebgl(tab);
    fitTab(tab);
    tab.term.focus();
    renderTabs();
    sidebar.syncToTab(tab);
  }

  function closeTab(id) {
    const tab = tabById(id);
    if (!tab) return;
    if (!tab.exited) host.post({ t: 'kill', id });
    removeTab(tab);
  }

  function removeTab(tab) {
    const idx = state.tabs.indexOf(tab);
    if (idx < 0) return;
    state.tabs.splice(idx, 1);
    state.webglLRU = state.webglLRU.filter((t) => t !== tab);
    clearTimeout(tab.ackTimer);
    clearTimeout(tab.markTimer);
    sidebar.forgetTab(tab);
    tab.term.dispose();
    tab.el.remove();
    if (state.activeId === tab.id) {
      state.activeId = null;
      const next = state.tabs[idx] || state.tabs[idx - 1];
      if (next) activate(next.id);
    }
    renderTabs();
    if (state.tabs.length === 0) {
      closeSettings();
      if (state.platform === 'browser') newTab();
      else host.post({ t: 'lastTabClosed' });
    }
  }

  function cycleTab(delta) {
    if (state.tabs.length < 2) return;
    const idx = state.tabs.findIndex((t) => t.id === state.activeId);
    activate(state.tabs[(idx + delta + state.tabs.length) % state.tabs.length].id);
  }

  function selectTab(n) {
    // ⌘9 / Ctrl+Alt+9 = last tab, like in browsers
    const tab = n >= 9 ? state.tabs[state.tabs.length - 1] : state.tabs[n - 1];
    if (tab) activate(tab.id);
  }

  function fitTab(tab) {
    if (!tab || !tab.el.classList.contains('active')) return;
    try { tab.fit.fit(); } catch (_) { /* pane has no size yet */ }
  }

  // WebGL only on recently used tabs; the others fall back to the DOM renderer.
  function ensureWebgl(tab) {
    state.webglLRU = state.webglLRU.filter((t) => t !== tab);
    state.webglLRU.push(tab);
    if (!tab.webgl && !state.webglBroken && window.WebglAddon) {
      try {
        const addon = new WebglAddon.WebglAddon();
        addon.onContextLoss(() => { addon.dispose(); tab.webgl = null; });
        tab.term.loadAddon(addon);
        tab.webgl = addon;
      } catch (err) {
        state.webglBroken = true;
        console.warn('WebGL unavailable, using the DOM renderer', err);
      }
    }
    while (state.webglLRU.length > MAX_WEBGL) {
      const old = state.webglLRU.shift();
      if (old.webgl) { old.webgl.dispose(); old.webgl = null; }
    }
  }

  function tabTitle(tab) {
    return tab.customTitle || tab.shellTitle || folderName(tab.cwd) || profileName(tab.profile);
  }

  function folderName(path) {
    if (!path) return '';
    const parts = path.split(/[\\/]/).filter(Boolean);
    return parts.length ? parts[parts.length - 1] : path;
  }

  function renderTabs() {
    const frag = document.createDocumentFragment();
    for (const tab of state.tabs) {
      const el = document.createElement('div');
      el.className = 'tab';
      el.dataset.id = tab.id;
      el.setAttribute('role', 'tab');
      el.draggable = true;
      el.classList.toggle('active', tab.id === state.activeId);
      el.classList.toggle('activity', tab.activity);
      el.classList.toggle('exited', tab.exited);
      el.title = tabTitle(tab);

      const dot = document.createElement('span');
      dot.className = 'dot';
      const title = document.createElement('span');
      title.className = 'title';
      title.textContent = tabTitle(tab);
      const close = document.createElement('button');
      close.className = 'close';
      close.title = 'Fechar aba';
      close.innerHTML = '<svg viewBox="0 0 16 16"><path d="m4.5 4.5 7 7m0-7-7 7"/></svg>';
      el.append(dot, title, close);
      frag.appendChild(el);
    }
    tabsEl.replaceChildren(frag);
    const active = tabsEl.querySelector('.tab.active');
    if (active) active.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    publishTabs();
    scheduleDragRegions();
  }

  const publishTabs = debounce(() => {
    const tab = activeTab();
    host.post({ t: 'tabs', count: state.tabs.length, title: tab ? tabTitle(tab) : '' });
  }, 30);

  // Click, middle click, double click (rename) and drag to reorder.
  tabsEl.addEventListener('mousedown', (ev) => {
    const el = ev.target.closest('.tab');
    if (!el || ev.target.closest('.close') || ev.target.closest('input')) return;
    if (ev.button === 0) activate(Number(el.dataset.id));
  });
  tabsEl.addEventListener('auxclick', (ev) => {
    const el = ev.target.closest('.tab');
    if (el && ev.button === 1) closeTab(Number(el.dataset.id));
  });
  tabsEl.addEventListener('click', (ev) => {
    const close = ev.target.closest('.close');
    if (close) closeTab(Number(close.closest('.tab').dataset.id));
  });
  tabsEl.addEventListener('dblclick', (ev) => {
    const el = ev.target.closest('.tab');
    if (el && !ev.target.closest('.close')) renameTab(Number(el.dataset.id));
  });
  tabsEl.addEventListener('contextmenu', (ev) => {
    ev.preventDefault();
    const el = ev.target.closest('.tab');
    if (el) activate(Number(el.dataset.id));
    openContextMenu(ev.clientX, ev.clientY);
  });

  let dragId = null;
  tabsEl.addEventListener('dragstart', (ev) => {
    const el = ev.target.closest('.tab');
    if (!el) return;
    dragId = Number(el.dataset.id);
    el.classList.add('dragging');
    ev.dataTransfer.effectAllowed = 'move';
    ev.dataTransfer.setData('text/plain', String(dragId));
  });
  tabsEl.addEventListener('dragover', (ev) => {
    const el = ev.target.closest('.tab');
    if (dragId === null || !el) return;
    ev.preventDefault();
    const after = ev.clientX > el.getBoundingClientRect().left + el.offsetWidth / 2;
    tabsEl.querySelectorAll('.drop-before, .drop-after').forEach((n) => n.classList.remove('drop-before', 'drop-after'));
    el.classList.add(after ? 'drop-after' : 'drop-before');
  });
  tabsEl.addEventListener('drop', (ev) => {
    const el = ev.target.closest('.tab');
    if (dragId === null || !el) return;
    ev.preventDefault();
    const targetId = Number(el.dataset.id);
    const after = el.classList.contains('drop-after');
    const from = state.tabs.findIndex((t) => t.id === dragId);
    const [moved] = state.tabs.splice(from, 1);
    let to = state.tabs.findIndex((t) => t.id === targetId);
    if (after) to += 1;
    state.tabs.splice(to, 0, moved);
    renderTabs();
  });
  tabsEl.addEventListener('dragend', () => { dragId = null; renderTabs(); });

  function renameTab(id) {
    const tab = tabById(id || state.activeId);
    if (!tab) return;
    activate(tab.id);
    const el = tabsEl.querySelector(`.tab[data-id="${tab.id}"]`);
    const titleEl = el && el.querySelector('.title');
    if (!titleEl) return;
    const input = document.createElement('input');
    input.className = 'rename';
    input.value = tabTitle(tab);
    input.placeholder = tab.shellTitle || folderName(tab.cwd) || profileName(tab.profile);
    el.draggable = false;
    titleEl.replaceWith(input);
    input.focus();
    input.select();
    let done = false;
    const finish = (commit) => {
      if (done) return;
      done = true;
      if (commit) tab.customTitle = input.value.trim(); // empty = back to the automatic title
      renderTabs();
      tab.term.focus();
    };
    input.addEventListener('keydown', (ev) => {
      ev.stopPropagation();
      if (ev.key === 'Enter') finish(true);
      else if (ev.key === 'Escape') finish(false);
    });
    input.addEventListener('blur', () => finish(true));
  }

  // ------------------------------------------------- data coming from the PTY
  function onData(id, b64) {
    const bytes = b64ToBytes(b64);
    const tab = tabById(id);
    if (!tab) { host.post({ t: 'ack', id, bytes: bytes.length }); return; }
    tab.term.write(bytes, () => { ack(tab, bytes.length); scheduleMark(tab); });
    if (id !== state.activeId && !tab.activity) { tab.activity = true; renderTabs(); }
  }

  function ack(tab, n) {
    tab.ackBytes += n;
    if (tab.ackBytes >= ACK_CHUNK) return flushAck(tab);
    if (!tab.ackTimer) tab.ackTimer = setTimeout(() => flushAck(tab), 8);
  }

  function flushAck(tab) {
    clearTimeout(tab.ackTimer);
    tab.ackTimer = 0;
    if (tab.ackBytes > 0) host.post({ t: 'ack', id: tab.id, bytes: tab.ackBytes });
    tab.ackBytes = 0;
  }

  // ------------------------------------------ current directory and command history
  function setCwd(tab, path, hostName) {
    if (!tab || !path) return;
    if (path === tab.cwd && (hostName || '') === tab.cwdHost) return;
    tab.cwd = path;
    tab.cwdHost = hostName || '';
    renderTabs();
    if (tab.id === state.activeId) sidebar.syncToTab(tab);
  }

  // Without shell integration, the end of the prompt is inferred: after Enter (or ^C), the last
  // output before the terminal goes quiet is the new prompt. Typing (echo) doesn't move the mark.
  function trackInput(tab, data) {
    if (data === '\r') {
      captureCommand(tab);
      tab.typedSinceMark = false;
    } else if (data.length > 1 && data.includes('\r') && !data.startsWith('\x1b[200~')) {
      // Text + Enter in one chunk (pasted, typed by automation): the part before the first
      // Enter completes the current line; any following whole lines are commands too.
      const parts = data.split('\r');
      captureCommand(tab, parts[0]);
      parts.slice(1, -1).forEach((line) => addHistory(line.trim(), tab));
      tab.typedSinceMark = parts[parts.length - 1].length > 0;
    } else if (data === '\x03' || data === '\x04') {
      tab.typedSinceMark = false;
    } else {
      tab.typedSinceMark = true;
    }
  }

  function scheduleMark(tab) {
    if (tab.integration) return;
    clearTimeout(tab.markTimer);
    tab.markTimer = setTimeout(() => { if (!tab.typedSinceMark) markPrompt(tab); }, 70);
  }

  function markPrompt(tab) {
    const b = tab.term.buffer.active;
    if (b.type !== 'normal') return;
    tab.promptMark = { y: b.baseY + b.cursorY, x: b.cursorX };
    sidebar.onPrompt(tab);
  }

  function captureCommand(tab, pending = '') {
    const b = tab.term.buffer.active;
    if (b.type !== 'normal') return;              // vim, less, htop…: not a shell command
    const cy = b.baseY + b.cursorY;
    const m = tab.promptMark;
    let text = '';
    if (m && m.y <= cy && cy - m.y <= 6) {
      for (let y = m.y; y < b.length; y++) {
        const line = b.getLine(y);
        if (!line || (y > cy && !line.isWrapped)) break;
        if (y > m.y && !line.isWrapped) text += '\n';
        text += line.translateToString(true, y === m.y ? m.x : 0);
      }
    } else {
      // No reliable mark: strip the prompt using the most common shapes ("… $ ", "… % ", "❯ ").
      const line = b.getLine(cy);
      const raw = line ? line.translateToString(true) : '';
      const pm = /^.{0,100}?[$%#>❯»]\s(.*)$/.exec(raw);
      text = pm ? pm[1] : raw;
    }
    addHistory((text + pending).trim(), tab);
  }

  // Each command remembers the tab it was typed in: the sidebar shows the active tab's history
  // (or every tab's). Repeating a command in the same tab just moves it to the top.
  function addHistory(cmd, tab) {
    if (!cmd || cmd.length > 4000) return;
    state.history = state.history.filter((h) => !(h.cmd === cmd && h.tab === tab.id && h.run === state.runId));
    state.history.unshift({ cmd, cwd: tab.cwd || '', at: Date.now(), tab: tab.id, run: state.runId });
    if (state.history.length > HISTORY_MAX) state.history.length = HISTORY_MAX;
    sidebar.renderHistory();
    persistHistory();
  }

  const persistHistory = debounce(() => host.post({ t: 'saveHistory', items: state.history }), 800);

  function clearHistory() {
    state.history = [];
    sidebar.renderHistory();
    host.post({ t: 'saveHistory', items: [] });
  }

  function insertText(text) {
    const tab = activeTab();
    if (!tab || tab.exited) return;
    host.post({ t: 'input', id: tab.id, data: text });
    tab.term.focus();
  }

  let toastTimer = 0;
  function toast(text) {
    const el = $('#toast');
    el.textContent = text;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 1600);
  }

  function onExit(id, code) {
    const tab = tabById(id);
    if (!tab) return;
    tab.exited = true;
    // A shell that dies right after starting (invalid command, etc.): keep the tab to show why.
    if (code !== 0 && performance.now() - tab.startedAt < 1500) {
      tab.term.write(`\r\n\x1b[31m[processo encerrado com código ${code}]\x1b[0m\r\n`);
      renderTabs();
      return;
    }
    removeTab(tab);
  }

  function onSpawnError(id, message) {
    const tab = tabById(id);
    if (!tab) return;
    tab.exited = true;
    tab.term.write(`\x1b[31mNão foi possível iniciar o shell:\x1b[0m ${message}\r\n`);
    renderTabs();
  }

  // ---------------------------------------------------------------- settings
  const persistSettings = debounce(() => host.post({ t: 'saveSettings', settings: state.settings }), 250);

  function applySettings({ save = true } = {}) {
    const s = state.settings;
    document.documentElement.style.setProperty('--opacity', String(s.opacity));
    for (const tab of state.tabs) {
      const o = tab.term.options;
      o.fontFamily = fontFamily();
      o.fontSize = s.fontSize;
      o.lineHeight = s.lineHeight;
      o.cursorStyle = s.cursorStyle;
      o.cursorBlink = s.cursorBlink;
      o.macOptionIsMeta = s.optionAsMeta;
      o.scrollback = s.scrollback;
    }
    fitTab(activeTab());
    syncSettingsForm();
    sidebar.applySettings();
    if (save) persistSettings();
  }

  function setSetting(key, value) {
    state.settings[key] = value;
    if (key === 'opacity') host.post({ t: 'opacity', value });
    applySettings();
  }

  function zoom(delta) {
    const size = delta === 0 ? DEFAULTS.fontSize : Math.min(28, Math.max(9, state.settings.fontSize + delta));
    setSetting('fontSize', size);
  }

  function syncSettingsForm() {
    const s = state.settings;
    $('#opacity').value = Math.round(s.opacity * 100);
    $('#opacity-value').textContent = `${Math.round(s.opacity * 100)}%`;
    $('#font-size').value = s.fontSize;
    $('#font-size-value').textContent = s.fontSize;
    if (document.activeElement !== $('#font-family')) $('#font-family').value = s.fontFamily;
    $('#font-family').placeholder = FONT_STACK[state.platform].split(',')[0].replace(/"/g, '');
    $('#cursor-blink').checked = s.cursorBlink;
    $('#show-sidebar').checked = s.showSidebar;
    $('#full-path-prompt').checked = s.fullPathPrompt;
    $('#copy-on-select').checked = s.copyOnSelect;
    $('#option-as-meta').checked = s.optionAsMeta;
    document.querySelectorAll('#cursor-style button').forEach((b) => b.classList.toggle('on', b.dataset.value === s.cursorStyle));
    const sel = $('#default-profile');
    sel.replaceChildren(...state.profiles.map((p) => new Option(p.name, p.id, false, p.id === s.defaultProfile)));
    if (!s.defaultProfile && state.profiles[0]) sel.value = state.profiles[0].id;
  }

  $('#opacity').addEventListener('input', (e) => setSetting('opacity', Number(e.target.value) / 100));
  $('#font-size').addEventListener('input', (e) => setSetting('fontSize', Number(e.target.value)));
  $('#font-family').addEventListener('input', debounce((e) => setSetting('fontFamily', e.target.value), 400));
  $('#cursor-blink').addEventListener('change', (e) => setSetting('cursorBlink', e.target.checked));
  $('#show-sidebar').addEventListener('change', (e) => setSetting('showSidebar', e.target.checked));
  $('#full-path-prompt').addEventListener('change', (e) => setSetting('fullPathPrompt', e.target.checked));
  $('#sidebar-btn').addEventListener('click', () => command('toggleSidebar'));
  $('#copy-on-select').addEventListener('change', (e) => setSetting('copyOnSelect', e.target.checked));
  $('#option-as-meta').addEventListener('change', (e) => setSetting('optionAsMeta', e.target.checked));
  $('#default-profile').addEventListener('change', (e) => setSetting('defaultProfile', e.target.value));
  $('#cursor-style').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b) setSetting('cursorStyle', b.dataset.value);
  });

  function toggleSettings() { settingsEl.hidden ? openSettings() : closeSettings(); }
  function openSettings() {
    closeMenu();
    syncSettingsForm();
    settingsEl.hidden = false;
    $('#settings-btn').classList.add('on');
  }
  function closeSettings() {
    if (settingsEl.hidden) return;
    settingsEl.hidden = true;
    $('#settings-btn').classList.remove('on');
    const tab = activeTab();
    if (tab) tab.term.focus();
  }
  $('#settings-btn').addEventListener('click', toggleSettings);
  $('#settings-close').addEventListener('click', closeSettings);

  // ----------------------------------------------------------- menus flutuantes
  const MOD = () => (state.platform === 'mac' ? '⌘' : 'Ctrl+');
  const SHIFT_MOD = () => (state.platform === 'mac' ? '⇧⌘' : 'Ctrl+Shift+');

  function openMenu(x, y, items) {
    closeMenu();
    menuEl.replaceChildren(...items.map((it) => {
      if (it === '-') return document.createElement('hr');
      const b = document.createElement('button');
      b.innerHTML = `<span></span><kbd></kbd>`;
      b.firstChild.textContent = it.label;
      b.lastChild.textContent = it.key || '';
      b.addEventListener('click', () => { closeMenu(); it.run(); });
      return b;
    }));
    menuEl.hidden = false;
    const r = menuEl.getBoundingClientRect();
    menuEl.style.left = `${Math.min(x, innerWidth - r.width - 6)}px`;
    menuEl.style.top = `${Math.min(y, innerHeight - r.height - 6)}px`;
  }
  function closeMenu() { menuEl.hidden = true; }

  function openContextMenu(x, y) {
    const tab = activeTab();
    const win = state.platform === 'win';
    openMenu(x, y, [
      { label: 'Copiar', key: win ? 'Ctrl+Shift+C' : '⌘C', run: () => command('copy') },
      { label: 'Colar', key: win ? 'Ctrl+V' : '⌘V', run: () => command('paste') },
      { label: 'Selecionar tudo', key: win ? '' : '⌘A', run: () => command('selectAll') },
      { label: 'Limpar', key: win ? '' : '⌘K', run: () => command('clear') },
      '-',
      { label: 'Nova aba', key: win ? 'Ctrl+Shift+T' : '⌘T', run: () => command('newTab') },
      { label: 'Renomear aba', key: `${SHIFT_MOD()}R`, run: () => command('renameTab') },
      { label: 'Fechar aba', key: win ? 'Ctrl+Shift+W' : '⌘W', run: () => tab && closeTab(tab.id) },
    ]);
  }

  function openProfileMenu() {
    const r = $('#profile-btn').getBoundingClientRect();
    openMenu(r.left, r.bottom + 4, state.profiles.map((p) => ({ label: p.name, run: () => newTab(p.id) })));
  }

  $('#new-tab').addEventListener('click', () => newTab());
  $('#profile-btn').addEventListener('click', openProfileMenu);
  $('#new-tab').addEventListener('contextmenu', (ev) => { ev.preventDefault(); openProfileMenu(); });
  document.addEventListener('mousedown', (ev) => {
    if (!menuEl.hidden && !menuEl.contains(ev.target)) closeMenu();
    if (!settingsEl.hidden && !settingsEl.contains(ev.target) && !ev.target.closest('#settings-btn')) closeSettings();
    // Clicking the sidebar, the menus or the toolbar buttons must not steal the keyboard from
    // the terminal (otherwise Ctrl+C and every other key would go nowhere). Text fields keep
    // their normal focus behavior.
    if (ev.target.closest('#sidebar, #menu, .tab-actions, #sidebar-btn') && !isTextField(ev.target)) {
      ev.preventDefault();
    }
  });

  // When the window becomes active again, the keyboard goes back to the terminal.
  window.addEventListener('focus', () => {
    if (!isTextField(document.activeElement) && settingsEl.hidden) focusTerminal();
  });

  // A UI text field (rename tab, font) has focus: copy/paste go to it, not to the shell.
  function focusedField() {
    const el = document.activeElement;
    return el && el.matches && el.matches('input[type="text"], input[type="search"], input.rename') ? el : null;
  }

  function isTextField(el) {
    return !!(el && el.matches && el.matches('input, select, textarea:not(.xterm-helper-textarea), [contenteditable="true"]'));
  }

  function terminalHasFocus() {
    const el = document.activeElement;
    return !!(el && el.classList && el.classList.contains('xterm-helper-textarea'));
  }

  function focusTerminal() {
    const tab = activeTab();
    if (tab) tab.term.focus();
  }

  // A key pressed while the keyboard is not on the terminal (focus left on a button, the page
  // body…): bring the focus back and deliver the key as terminal input, so nothing is lost.
  function strayKeyToTerminal(ev) {
    const tab = activeTab();
    if (!tab || tab.exited) return false;
    const appCursor = tab.term.modes.applicationCursorKeysMode;
    const arrows = { ArrowUp: 'A', ArrowDown: 'B', ArrowRight: 'C', ArrowLeft: 'D' };
    let data = null;
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey && /^Key[A-Z]$/.test(ev.code)) {
      data = String.fromCharCode(ev.code.charCodeAt(3) - 64);          // Ctrl+C → \x03, Ctrl+D → \x04…
    } else if (ev.ctrlKey && ev.code === 'BracketLeft') {
      data = '\x1b';
    } else if (ev.metaKey || ev.ctrlKey) {
      return false;
    } else if (arrows[ev.key]) {
      data = (appCursor ? '\x1bO' : '\x1b[') + arrows[ev.key];
    } else {
      data = { Enter: '\r', Backspace: '\x7f', Tab: '\t', Escape: '\x1b', Delete: '\x1b[3~',
               Home: '\x1b[H', End: '\x1b[F', PageUp: '\x1b[5~', PageDown: '\x1b[6~' }[ev.key]
        || (ev.key.length === 1 ? (ev.altKey && state.settings.optionAsMeta ? `\x1b${ev.key}` : ev.key) : null);
    }
    tab.term.focus();
    if (data === null) return false;
    tab.term.input(data, true);
    return true;
  }

  // ----------------------------------------------------------------- commands
  // Called by the native menu (macOS), the tray (Windows) or the shortcuts below.
  function command(name, arg) {
    const tab = activeTab();
    switch (name) {
      case 'newTab': return newTab(arg);
      case 'toggleSidebar': return setSetting('showSidebar', !state.settings.showSidebar);
      case 'closeTab': return tab && closeTab(tab.id);
      case 'nextTab': return cycleTab(1);
      case 'prevTab': return cycleTab(-1);
      case 'selectTab': return selectTab(Number(arg));
      case 'renameTab': return renameTab();
      case 'settings': return toggleSettings();
      case 'copy': {
        const field = focusedField();
        if (field) {
          const text = field.value.slice(field.selectionStart, field.selectionEnd);
          if (text) host.post({ t: 'copy', text });
        } else if (tab && tab.term.hasSelection()) {
          host.post({ t: 'copy', text: tab.term.getSelection() });
        }
        return;
      }
      case 'paste': return host.post({ t: 'paste' });
      case 'selectAll': {
        const field = focusedField();
        return field ? field.select() : tab && tab.term.selectAll();
      }
      case 'clear': return tab && tab.term.clear();
      case 'zoomIn': return zoom(1);
      case 'zoomOut': return zoom(-1);
      case 'zoomReset': return zoom(0);
      case 'focus': return tab && tab.term.focus();
      default: console.warn('unknown command', name);
    }
  }

  // Shortcuts. On macOS, ⌘ shortcuts belong to the native menu (which intercepts them before the page);
  // here we only make sure no ⌘+key leaks into the shell. On Windows, everything is handled here.
  const WIN_KEYS = [
    [(e) => e.ctrlKey && e.shiftKey && e.code === 'KeyT', () => command('newTab')],
    [(e) => e.ctrlKey && e.shiftKey && e.code === 'KeyW', () => command('closeTab')],
    [(e) => e.ctrlKey && e.shiftKey && e.code === 'KeyR', () => command('renameTab')],
    [(e) => e.ctrlKey && e.shiftKey && e.code === 'KeyB', () => command('toggleSidebar')],
    [(e) => e.ctrlKey && !e.shiftKey && e.key === 'Tab', () => command('nextTab')],
    [(e) => e.ctrlKey && e.shiftKey && e.key === 'Tab', () => command('prevTab')],
    [(e) => e.ctrlKey && e.key === 'PageDown', () => command('nextTab')],
    [(e) => e.ctrlKey && e.key === 'PageUp', () => command('prevTab')],
    [(e) => e.ctrlKey && e.altKey && !e.getModifierState('AltGraph') && /^Digit[1-9]$/.test(e.code),
      (e) => command('selectTab', e.code.slice(5))],
    [(e) => e.ctrlKey && e.shiftKey && e.code === 'KeyC', () => command('copy')],
    [(e) => e.ctrlKey && e.code === 'Insert', () => command('copy')],
    [(e) => e.ctrlKey && !e.shiftKey && !e.altKey && e.code === 'KeyC' && activeTab() && activeTab().term.hasSelection(),
      () => { command('copy'); activeTab().term.clearSelection(); }],
    [(e) => e.ctrlKey && !e.altKey && e.code === 'KeyV', () => command('paste')],
    [(e) => e.shiftKey && e.code === 'Insert', () => command('paste')],
    [(e) => e.ctrlKey && e.code === 'Comma', () => command('settings')],
    [(e) => e.ctrlKey && (e.code === 'Equal' || e.code === 'NumpadAdd'), () => command('zoomIn')],
    [(e) => e.ctrlKey && (e.code === 'Minus' || e.code === 'NumpadSubtract'), () => command('zoomOut')],
    [(e) => e.ctrlKey && (e.code === 'Digit0' || e.code === 'Numpad0') && !e.altKey, () => command('zoomReset')],
  ];

  window.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape' && (!menuEl.hidden || !settingsEl.hidden)) {
      closeMenu(); closeSettings(); ev.preventDefault(); return;
    }
    if (isTextField(ev.target)) return;
    if (state.platform === 'mac') {
      if (ev.metaKey) { ev.preventDefault(); ev.stopPropagation(); return; }
    } else {
      for (const [match, run] of WIN_KEYS) {
        if (match(ev)) { ev.preventDefault(); ev.stopPropagation(); run(ev); return; }
      }
    }
    if (!terminalHasFocus() && menuEl.hidden && settingsEl.hidden && strayKeyToTerminal(ev)) {
      ev.preventDefault();
      ev.stopPropagation();
    }
  }, true);

  // --------------------------------------------- window dragging (macOS)
  // The page tells the native app where the "empty" part of the tab bar is; clicking there
  // drags the window (and double-clicking maximizes it), like a title bar.
  let lastRegions = '';
  const scheduleDragRegions = () => requestAnimationFrame(publishDragRegions);
  function publishDragRegions() {
    if (state.platform !== 'mac') return;
    const bar = $('#tabbar').getBoundingClientRect();
    const tabs = tabsEl.getBoundingClientRect();
    const spacer = $('#drag-spacer').getBoundingClientRect();
    const sbBtn = $('#sidebar-btn').getBoundingClientRect();
    const rects = [
      { x: 0, y: 0, w: Math.max(0, sbBtn.left), h: bar.height },
      { x: sbBtn.right, y: 0, w: Math.max(0, tabs.left - sbBtn.right), h: bar.height },
      { x: spacer.left, y: 0, w: spacer.width, h: bar.height },
      { x: tabs.left, y: 0, w: tabs.width, h: 2 },
    ].map((r) => ({ x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.w), h: Math.round(r.h) }));
    const json = JSON.stringify(rects);
    if (json !== lastRegions) { lastRegions = json; host.post({ t: 'dragRegions', rects }); }
  }

  // ------------------------------------------------------- redimensionamento
  let fitFrame = 0;
  new ResizeObserver(() => {
    cancelAnimationFrame(fitFrame);
    fitFrame = requestAnimationFrame(() => { fitTab(activeTab()); publishDragRegions(); });
  }).observe(panesEl);

  // --------------------------------------------------- messages from the native app
  function recv(msg) {
    switch (msg.t) {
      case 'init':
        state.platform = msg.platform || state.platform;
        state.version = msg.version || '';
        state.windowsBuild = msg.windowsBuild || 0;
        state.profiles = msg.profiles || [];
        state.settings = { ...DEFAULTS, ...(msg.settings || {}) };
        state.home = msg.home || '';
        state.places = msg.places || [];
        state.history = Array.isArray(msg.history) ? msg.history : [];
        if (msg.renderer === 'dom') state.webglBroken = true;   // screenshots (WKWebView snapshots don't include WebGL)
        sidebar.renderHistory();
        if (!state.profiles.some((p) => p.id === state.settings.defaultProfile)) state.settings.defaultProfile = '';
        $('#profile-btn').hidden = state.profiles.length < 2;
        $('#about').textContent = `Ronic JustTerminal ${state.version}`;
        applySettings({ save: false });
        if (state.tabs.length === 0) newTab();
        break;
      case 'data': onData(msg.id, msg.b64); break;
      case 'cwd': setCwd(tabById(msg.id), msg.path, msg.host || ''); break;
      case 'dirList': sidebar.onDirList(msg); break;
      case 'toast': toast(msg.text); break;
      case 'exit': onExit(msg.id, msg.code); break;
      case 'spawnError': onSpawnError(msg.id, msg.message); break;
      case 'cmd': command(msg.name, msg.arg); break;
      case 'pasteText': {
        if (!msg.text) break;
        const field = focusedField();
        if (field) {
          field.setRangeText(msg.text, field.selectionStart, field.selectionEnd, 'end');
          field.dispatchEvent(new Event('input', { bubbles: true }));
        } else {
          const tab = activeTab();
          if (tab) tab.term.paste(msg.text);
        }
        break;
      }
      case 'shown':
        if (state.tabs.length === 0) newTab();
        else { const tab = activeTab(); fitTab(tab); if (tab) tab.term.focus(); }
        break;
      case 'fullscreen':
        document.documentElement.classList.toggle('fullscreen', !!msg.on);
        scheduleDragRegions();
        break;
      default: console.warn('unknown message', msg);
    }
  }

  // Visible text of each tab (diagnostics and the native app's self-test).
  function dump() {
    return state.tabs.map((tab) => {
      const buf = tab.term.buffer.active;
      const lines = [];
      for (let i = 0; i < buf.length; i++) lines.push(buf.getLine(i).translateToString(true));
      return { id: tab.id, title: tabTitle(tab), active: tab.id === state.activeId, text: lines.join('\n').trimEnd() };
    });
  }

  // Types as if it were the user (native app self-test).
  function type(text) { const tab = activeTab(); if (tab) tab.term.input(text, true); }

  window.JT = { recv, data: onData, dump, type };

  // API for the sidebar (sidebar.js): it never talks to the native app directly.
  const sidebar = window.createSidebar({
    state, host, activeTab, profileOf, setSetting, openMenu, toast, clearHistory,
    newTab: (profile, cwd) => newTab(profile, cwd),
    insert: insertText,
    copy: (text) => host.post({ t: 'copy', text }),
    run: (tab, text) => {
      // A full-screen program (vim, less, htop…) is open: the "cd" would be typed into it.
      if (tab.term.buffer.active.type === 'alternate') {
        toast('Há um programa aberto nesta aba. Saia dele para navegar pelas pastas.');
        return;
      }
      host.post({ t: 'run', id: tab.id, text });
      tab.term.focus();
    },
    focusTerminal,
  });
  if (winHost) winHost.addEventListener('message', (e) => recv(typeof e.data === 'string' ? JSON.parse(e.data) : e.data));

  // ------------------------------------------------ demo mode (browser)
  const DEMO_FS = {
    '/': ['Applications', 'Users'],
    '/Applications': [],
    '/Users': ['demo'],
    '/Users/demo': ['.config', 'Desktop', 'Documents', 'Downloads', 'development', '.zshrc', 'notas.txt'],
    '/Users/demo/.config': [],
    '/Users/demo/Desktop': ['print.png'],
    '/Users/demo/Documents': ['contratos', 'planilha.xlsx'],
    '/Users/demo/Documents/contratos': [],
    '/Users/demo/Downloads': ['instalador.dmg'],
    '/Users/demo/development': ['Ronic-JustTerminal', 'Ronic-Mirror', 'rpg-manager'],
    '/Users/demo/development/Ronic-JustTerminal': ['macos', 'windows', 'shared-web', 'README.md', 'Makefile'],
    '/Users/demo/development/Ronic-JustTerminal/macos': [],
    '/Users/demo/development/Ronic-JustTerminal/windows': [],
    '/Users/demo/development/Ronic-JustTerminal/shared-web': ['app.js', 'sidebar.js', 'style.css'],
    '/Users/demo/development/Ronic-Mirror': [],
    '/Users/demo/development/rpg-manager': [],
  };

  const Demo = {
    lines: {},
    cwd: {},
    prompt(id) { return `\x1b[1;38;2;127;180;255m${this.cwd[id].replace('/Users/demo', '~')}\x1b[0m $ `; },
    cd(id, arg) {
      const target = !arg || arg === '~' ? '/Users/demo'
        : arg.startsWith('/') ? arg
        : arg === '..' ? this.cwd[id].replace(/\/[^/]+$/, '') || '/'
        : `${this.cwd[id] === '/' ? '' : this.cwd[id]}/${arg}`;
      if (!DEMO_FS[target]) return `cd: no such file or directory: ${arg}\r\n`;
      this.cwd[id] = target;
      setTimeout(() => recv({ t: 'cwd', id, path: target }), 0);
      return '';
    },
    handle(msg) {
      const send = (m) => setTimeout(() => recv(m), 0);
      const out = (id, text) => send({ t: 'data', id, b64: btoa(unescape(encodeURIComponent(text))) });
      switch (msg.t) {
        case 'ready': {
          let saved = {};
          try { saved = JSON.parse(localStorage.getItem('jt.settings') || '{}'); } catch (_) { /* no storage */ }
          send({ t: 'init', platform: 'browser', version: 'dev', settings: saved, home: '/Users/demo',
                 profiles: [{ id: 'demo', name: 'demo', kind: 'posix', home: '/Users/demo' },
                            { id: 'demo2', name: 'demo (2)', kind: 'posix', home: '/Users/demo' }],
                 places: [{ name: 'demo', path: '/Users/demo', icon: 'home' },
                          { name: 'Mesa', path: '/Users/demo/Desktop' },
                          { name: 'Documentos', path: '/Users/demo/Documents' },
                          { name: 'Downloads', path: '/Users/demo/Downloads' },
                          { name: 'Disco', path: '/', icon: 'disk' }],
                 history: [{ cmd: 'git status', cwd: '/Users/demo/development', at: Date.now() - 60000 },
                           { cmd: 'npm run build', cwd: '/Users/demo/development', at: Date.now() - 120000 }] });
          break;
        }
        case 'spawn':
          this.lines[msg.id] = '';
          this.cwd[msg.id] = DEMO_FS[msg.cwd] ? msg.cwd : '/Users/demo';
          send({ t: 'cwd', id: msg.id, path: this.cwd[msg.id] });
          out(msg.id, `\x1b[1;32mRonic JustTerminal\x1b[0m modo navegador (sem PTY: só "cd" e eco)\r\n` +
            `Rode o app nativo para ter um shell de verdade.\r\n\r\n${this.prompt(msg.id)}`);
          break;
        case 'run': {
          const m = /cd (?:-- |\/d )?['"]?(.*?)['"]?\r$/.exec(msg.text);
          if (m) out(msg.id, `cd ${m[1]}\r\n${this.cd(msg.id, m[1])}${this.prompt(msg.id)}`);
          break;
        }
        case 'listDir': {
          const names = DEMO_FS[msg.path];
          const entries = (names || []).map((n) => ({ n, d: !!DEMO_FS[`${msg.path === '/' ? '' : msg.path}/${n}`], h: n.startsWith('.') }))
            .sort((a, b) => (b.d - a.d) || a.n.localeCompare(b.n));
          send({ t: 'dirList', reqId: msg.reqId, path: msg.path, entries, error: names ? '' : 'pasta não encontrada' });
          break;
        }
        case 'input': {
          let echo = '';
          for (const ch of msg.data) {
            if (ch === '\r') {
              const line = this.lines[msg.id].trim();
              const cd = /^cd(?:\s+(.*))?$/.exec(line);
              const result = cd ? this.cd(msg.id, (cd[1] || '').trim())
                : line ? `demo: ${line}: comando simulado\r\n` : '';
              echo += `\r\n${result}${this.prompt(msg.id)}`;
              this.lines[msg.id] = '';
            } else if (ch === '\x7f') {
              if (this.lines[msg.id]) { this.lines[msg.id] = this.lines[msg.id].slice(0, -1); echo += '\b \b'; }
            } else if (ch >= ' ') { this.lines[msg.id] += ch; echo += ch; }
          }
          if (echo) out(msg.id, echo);
          break;
        }
        case 'saveSettings':
          try { localStorage.setItem('jt.settings', JSON.stringify(msg.settings)); } catch (_) { /* no storage */ }
          break;
        case 'copy':
          if (navigator.clipboard) navigator.clipboard.writeText(msg.text).catch(() => {});
          break;
        case 'paste':
          if (navigator.clipboard) navigator.clipboard.readText().then((text) => send({ t: 'pasteText', text })).catch(() => {});
          break;
        case 'openUrl': window.open(msg.url, '_blank', 'noopener'); break;
        default: break;
      }
    },
  };

  host.post({ t: 'ready' });
})();
