/* Ronic JustTerminal: right sidebar (Git).
 *
 * Follows the active tab: when its shell is inside a Git repository, shows the current branch,
 * ahead/behind the upstream, an operation in progress (merge, rebase, cherry-pick, revert),
 * the changed files and the branches.
 *
 * Reads (status, branches) run in the background through the native app ({t: 'git'}).
 * Actions that change the repository in a way the user should see (commit, push, pull, switch,
 * merge, rebase…) are typed into the terminal, like the sidebar's "cd": you see the exact
 * command and its output, and Git can ask for credentials, open the editor or run hooks there.
 * Staging, unstaging and discarding a file run in the background (one click = one file).
 *
 * This file never talks to the system directly: everything goes through the `api` from app.js.
 */
'use strict';

window.createGitPanel = function createGitPanel(api) {
  const $ = (sel) => document.querySelector(sel);
  const bar = $('#gitbar');
  const headEl = $('#git-head');
  const bannerEl = $('#git-banner');
  const emptyEl = $('#git-empty');
  const listEl = $('#git-changes .git-list');
  const changesCountEl = $('#git-changes-count');
  const branchesCountEl = $('#git-branches-count');
  const branchListEl = $('#git-branches .git-branch-list');
  const branchFilterEl = $('#git-branch-filter');
  const messageEl = $('#git-message');
  const hintEl = $('#git-commit-hint');
  const diffEl = $('#diff-view');
  const diffTitleEl = diffEl.querySelector('.diff-title');
  const diffBodyEl = diffEl.querySelector('.diff-body');

  const AUTO_FETCH_MS = 5 * 60 * 1000;
  const POLL_MS = 4000;
  const MAX_FILES = 400;

  let repo = null;          // last snapshot (see refresh)
  let refreshing = false;
  let refreshAgain = false;
  let pollTimer = 0;
  let lastFetchAt = 0;         // last attempt (throttle)
  let lastFetchRoot = '';
  let lastFetchOkAt = 0;       // last successful background fetch (shown in the header)
  let showRemotes = false;
  let creatingBranch = false;
  let armedDiscard = '';

  const ICON = {
    repo: '<svg viewBox="0 0 16 16"><path d="M3.5 2.25h8.25v11.5H3.5a1 1 0 0 1-1-1v-9.5a1 1 0 0 1 1-1Z"/><path d="M2.5 11.25a1 1 0 0 1 1-1h8.25"/></svg>',
    branch: '<svg viewBox="0 0 16 16"><circle cx="4.5" cy="3.75" r="1.5"/><circle cx="4.5" cy="12.25" r="1.5"/><circle cx="11.5" cy="5.75" r="1.5"/><path d="M4.5 5.25v5.5M11.5 7.25c0 2.5-3 2.5-5.6 4"/></svg>',
    fetch: '<svg viewBox="0 0 16 16"><path d="M13 8a5 5 0 1 1-1.46-3.54M13 2.75v2.5h-2.5"/></svg>',
    pull: '<svg viewBox="0 0 16 16"><path d="M8 2.75v9.5M4.5 8.75 8 12.25l3.5-3.5"/></svg>',
    push: '<svg viewBox="0 0 16 16"><path d="M8 13.25v-9.5M4.5 7.25 8 3.75l3.5 3.5"/></svg>',
    plus: '<svg viewBox="0 0 16 16"><path d="M8 3.5v9M3.5 8h9"/></svg>',
    minus: '<svg viewBox="0 0 16 16"><path d="M3.5 8h9"/></svg>',
    discard: '<svg viewBox="0 0 16 16"><path d="M5.5 4.25 3 6.75l2.5 2.5"/><path d="M3.25 6.75h6.5a3.25 3.25 0 0 1 0 6.5H7"/></svg>',
    check: '<svg viewBox="0 0 16 16"><path d="m3.5 8.5 3 3 6-7"/></svg>',
    diff: '<svg viewBox="0 0 16 16"><path d="M4 1.75h5l3 3v9.5H4z"/><path d="M6.25 8h3.5M8 6.25v3.5M6.25 11.5h3.5"/></svg>',
  };

  // ------------------------------------------------------------------ helpers

  const visible = () => api.state.settings.showGit;
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const baseName = (p) => p.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || p;

  function ago(unixSeconds) {
    if (!unixSeconds) return '';
    const s = Math.max(0, Date.now() / 1000 - unixSeconds);
    if (s < 60) return 'agora';
    if (s < 3600) return `há ${Math.floor(s / 60)} min`;
    if (s < 86400) return `há ${Math.floor(s / 3600)} h`;
    if (s < 172800) return 'ontem';
    if (s < 30 * 86400) return `há ${Math.floor(s / 86400)} dias`;
    return new Date(unixSeconds * 1000).toLocaleDateString();
  }

  /** Quotes an argument for the active tab's shell. */
  function q(arg) {
    const kind = repo ? repo.kind : 'posix';
    if (/^[\w@%+=:,./-]+$/.test(arg)) return arg;
    if (kind === 'powershell') return `'${arg.replace(/'/g, "''")}'`;
    if (kind === 'cmd') return `"${arg.replace(/"/g, '""')}"`;
    return `'${arg.replace(/'/g, "'\\''")}'`;
  }

  /** Runs commands one after the other, stopping at the first failure, in the shell's dialect. */
  function chain(cmds) {
    if (cmds.length === 1) return cmds[0];
    if (repo && repo.kind === 'powershell') {
      // Windows PowerShell 5.1 has no "&&": a; if ($?) { b; if ($?) { c } }
      return cmds.reduceRight((rest, cmd) => (rest ? `${cmd}; if ($?) { ${rest} }` : cmd), '');
    }
    return cmds.join(' && ');
  }

  /** Types a Git command into the terminal (a new tab if the active one is busy). */
  function type(cmds) {
    if (!repo) return;
    api.runInTerminal(chain([].concat(cmds)), repo.root);
  }

  function git(args, opts = {}) {
    const tab = api.activeTab();
    if (!tab) return Promise.resolve({ code: -1, out: '', err: 'sem aba' });
    return api.git(tab, args, { cwd: opts.cwd || (repo && repo.root) || tab.cwd, write: !!opts.write });
  }

  // ------------------------------------------------------------------ parsing

  function parseStatus(out) {
    const st = { branch: '', oid: '', upstream: '', ahead: 0, behind: 0, staged: [], unstaged: [], conflicts: [] };
    const parts = out.split('\0');
    for (let i = 0; i < parts.length; i++) {
      const line = parts[i];
      if (!line) continue;
      if (line.startsWith('# branch.oid ')) st.oid = line.slice(13);
      else if (line.startsWith('# branch.head ')) st.branch = line.slice(14);
      else if (line.startsWith('# branch.upstream ')) st.upstream = line.slice(18);
      else if (line.startsWith('# branch.ab ')) {
        const m = /\+(\d+) -(\d+)/.exec(line);
        if (m) { st.ahead = Number(m[1]); st.behind = Number(m[2]); }
      } else if (line[0] === '1' || line[0] === '2') {
        const f = line.split(' ');
        const xy = f[1];
        const path = f.slice(line[0] === '1' ? 8 : 9).join(' ');
        const orig = line[0] === '2' ? parts[++i] : '';
        if (xy[0] !== '.') st.staged.push({ path, code: xy[0], orig });
        if (xy[1] !== '.') st.unstaged.push({ path, code: xy[1], orig });
      } else if (line[0] === 'u') {
        st.conflicts.push({ path: line.split(' ').slice(10).join(' '), code: 'U' });
      } else if (line[0] === '?') {
        st.unstaged.push({ path: line.slice(2), code: '?', untracked: true });
      }
    }
    return st;
  }

  function parseRefs(out) {
    const local = [];
    const remote = [];
    for (const line of out.split('\n')) {
      if (!line) continue;
      const [ref, short, upstream, track, date, head, subject] = line.split('\0');
      const ab = { ahead: 0, behind: 0, gone: track === 'gone' };
      const a = /ahead (\d+)/.exec(track || '');
      const b = /behind (\d+)/.exec(track || '');
      if (a) ab.ahead = Number(a[1]);
      if (b) ab.behind = Number(b[1]);
      const item = { ref, name: short, upstream, ...ab, date: Number(date) || 0, current: head === '*', subject: subject || '' };
      if (ref.startsWith('refs/heads/')) local.push(item);
      else if (ref.startsWith('refs/remotes/') && !ref.endsWith('/HEAD')) remote.push(item);
    }
    local.sort((x, y) => (y.current - x.current) || (y.date - x.date));
    remote.sort((x, y) => y.date - x.date);
    return { local, remote };
  }

  // ------------------------------------------------------------------ refresh

  async function refresh() {
    if (!visible()) return;
    if (refreshing) { refreshAgain = true; return; }
    const tab = api.activeTab();
    if (!tab || !tab.cwd) { repo = { state: 'noCwd' }; render(); return; }
    refreshing = true;
    try {
      const top = await api.git(tab, ['rev-parse', '--show-toplevel', '--absolute-git-dir'], { cwd: tab.cwd });
      if (tab !== api.activeTab()) return;
      if (top.code !== 0) {
        repo = { state: top.code === 127 ? 'noGit' : 'notRepo', cwd: tab.cwd, kind: api.profileOf(tab).kind, tabId: tab.id };
        render();
        return;
      }
      const [root, gitDir] = top.out.trim().split('\n');
      const opts = { cwd: root };
      const [status, refs, dir, stash, remotes] = await Promise.all([
        api.git(tab, ['status', '--porcelain=v2', '--branch', '-z', '--untracked-files=normal'], opts),
        api.git(tab, ['for-each-ref', '--format=%(refname)%00%(refname:short)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(HEAD)%00%(contents:subject)', 'refs/heads', 'refs/remotes'], opts),
        api.listDir(tab, gitDir),
        api.git(tab, ['rev-list', '--walk-reflogs', '--count', 'refs/stash'], opts),
        api.git(tab, ['remote'], opts),
      ]);
      if (tab !== api.activeTab()) return;
      const names = new Set((dir.entries || []).map((e) => e.n));
      const op = names.has('rebase-merge') || names.has('rebase-apply') ? 'rebase'
        : names.has('MERGE_HEAD') ? 'merge'
        : names.has('CHERRY_PICK_HEAD') ? 'cherry-pick'
        : names.has('REVERT_HEAD') ? 'revert' : '';
      const remoteNames = remotes.out.split('\n').map((s) => s.trim()).filter(Boolean);
      repo = {
        state: 'repo',
        tabId: tab.id,
        kind: api.profileOf(tab).kind,
        root,
        gitDir,
        name: baseName(root),
        op,
        stash: stash.code === 0 ? Number(stash.out.trim()) || 0 : 0,
        remote: remoteNames.includes('origin') ? 'origin' : remoteNames[0] || '',
        ...parseStatus(status.out),
        ...parseRefs(refs.out),
      };
      render();
      maybeAutoFetch(tab);
    } finally {
      refreshing = false;
      if (refreshAgain) { refreshAgain = false; setTimeout(refresh, 50); }
    }
  }

  const scheduleRefresh = (() => {
    let t = 0;
    return (ms = 120) => { clearTimeout(t); t = setTimeout(refresh, ms); };
  })();

  function maybeAutoFetch(tab) {
    if (!api.state.settings.gitAutoFetch || !repo || !repo.remote) return;
    if (repo.root === lastFetchRoot && Date.now() - lastFetchAt < AUTO_FETCH_MS) return;
    lastFetchRoot = repo.root;
    lastFetchAt = Date.now();
    // Background fetch: never prompts (no terminal); failures (auth, offline) are silent.
    api.git(tab, ['fetch', '--quiet', '--prune', '--no-recurse-submodules'], { cwd: repo.root, write: true, background: true })
      .then((r) => { if (r.code === 0) { lastFetchOkAt = Date.now(); scheduleRefresh(); } });
  }

  // ------------------------------------------------------------------ render

  function render() {
    const r = repo;
    bar.classList.toggle('empty', !r || r.state !== 'repo');
    if (!r || r.state !== 'repo') {
      headEl.replaceChildren();
      bannerEl.hidden = true;
      emptyEl.hidden = false;
      if (!r || r.state === 'noCwd') {
        emptyEl.innerHTML = 'Abra uma pasta no terminal para ver o Git dela.';
      } else if (r.state === 'noGit') {
        emptyEl.innerHTML = '<b>Git não encontrado.</b><br>No macOS: <code>xcode-select --install</code> ou <code>brew install git</code>.<br>No Windows: instale o Git for Windows.';
      } else {
        emptyEl.innerHTML = `<b>${esc(baseName(r.cwd))}</b> não é um repositório Git.<button id="git-init">Inicializar repositório aqui</button>`;
        emptyEl.querySelector('#git-init').addEventListener('click', () => api.runInTerminal('git init', r.cwd));
      }
      return;
    }
    emptyEl.hidden = true;
    renderHead(r);
    renderBanner(r);
    renderChanges(r);
    renderBranches(r);
  }

  function abHtml(ahead, behind) {
    if (!ahead && !behind) return '';
    return `<span class="ab">${ahead ? `<span class="up" title="${ahead} commit(s) para enviar">↑${ahead}</span>` : ''}${behind ? `<span class="down" title="${behind} commit(s) para receber">↓${behind}</span>` : ''}</span>`;
  }

  function renderHead(r) {
    const detached = r.branch === '(detached)';
    const branchName = detached ? `${r.oid.slice(0, 8)} (detached)` : r.branch;
    const upstream = r.upstream
      ? `${esc(r.upstream)}${lastFetchRoot === r.root && lastFetchOkAt ? ` · buscado ${ago(lastFetchOkAt / 1000)}` : ''}`
      : r.remote ? 'sem branch remota: use Publicar' : 'sem remoto configurado';
    const pushLabel = r.upstream ? `Push${r.ahead ? ` <span class="badge">${r.ahead}</span>` : ''}` : 'Publicar';
    headEl.innerHTML = `
      <div class="git-repo">${ICON.repo}<b title="${esc(r.root)}">${esc(r.name)}</b>${r.stash ? `<span class="stash" title="Alterações guardadas (git stash)">stash ${r.stash}</span>` : ''}</div>
      <div class="git-branch-line">${ICON.branch}<span class="name" title="${esc(branchName)}">${esc(branchName)}</span>${abHtml(r.ahead, r.behind)}</div>
      <div class="git-upstream" title="${esc(r.upstream || '')}">${upstream}</div>
      <div class="git-actions">
        <button data-act="fetch" title="git fetch --prune">${ICON.fetch}Buscar</button>
        <button data-act="pull" title="git pull" ${r.upstream ? '' : 'disabled'}>${ICON.pull}Pull${r.behind ? ` <span class="badge">${r.behind}</span>` : ''}</button>
        <button data-act="push" title="${r.upstream ? 'git push' : `git push -u ${esc(r.remote || 'origin')} HEAD`}" ${r.remote && !detached ? '' : 'disabled'}>${ICON.push}${pushLabel}</button>
      </div>`;
  }

  function renderBanner(r) {
    if (!r.op) { bannerEl.hidden = true; return; }
    const label = { merge: 'Merge', rebase: 'Rebase', 'cherry-pick': 'Cherry-pick', revert: 'Revert' }[r.op];
    const conflicts = r.conflicts.length;
    bannerEl.hidden = false;
    bannerEl.innerHTML = `⚠ <b>${label} em andamento</b>${conflicts ? ` · ${conflicts} conflito${conflicts > 1 ? 's' : ''} para resolver` : ' · sem conflitos pendentes'}
      <div class="row-actions">
        <button data-op="continue" ${conflicts ? 'disabled title="Resolva os conflitos primeiro"' : ''}>Continuar</button>
        <button data-op="abort" class="abort">Abortar</button>
      </div>`;
  }

  function fileRow(file, group) {
    const isDir = /[\\/]$/.test(file.path);
    const clean = file.path.replace(/[\\/]$/, '');
    const slash = Math.max(clean.lastIndexOf('/'), clean.lastIndexOf('\\'));
    const dir = slash > 0 ? clean.slice(0, slash) : '';
    const name = (slash > 0 ? clean.slice(slash + 1) : clean) + (isDir ? '/' : '');
    const key = `${group}:${file.path}`;
    const acts = group === 'conflicts'
      ? `<button class="icon-btn tiny" data-act="resolve" title="Marcar como resolvido (git add)">${ICON.check}</button>`
      : group === 'staged'
        ? `<button class="icon-btn tiny" data-act="unstage" title="Tirar do stage">${ICON.minus}</button>`
        : `<button class="icon-btn tiny ${armedDiscard === key ? 'armed' : ''}" data-act="discard" title="${armedDiscard === key ? 'Clique de novo para descartar' : 'Descartar alterações'}">${ICON.discard}</button>
           <button class="icon-btn tiny" data-act="stage" title="Colocar no stage">${ICON.plus}</button>`;
    const code = file.code === '?' ? 'N' : file.code;
    const title = { M: 'modificado', A: 'adicionado', D: 'apagado', R: 'renomeado', C: 'copiado', U: 'em conflito', T: 'tipo alterado', N: 'novo (não rastreado)' }[code] || '';
    return `<div class="file-row ${code === 'D' ? 'deleted' : ''}" data-group="${group}" data-path="${esc(file.path)}" title="${esc(file.path)}${file.orig ? ` ← ${esc(file.orig)}` : ''}\nClique para ver as diferenças">
      <span class="st ${code}" title="${title}">${code}</span>
      <span class="fname">${esc(name)}</span><span class="fdir">${esc(dir)}</span>
      <span class="acts">${acts}</span></div>`;
  }

  function renderChanges(r) {
    const total = r.staged.length + r.unstaged.length + r.conflicts.length;
    changesCountEl.textContent = total ? `(${total})` : '';
    let html = '';
    const group = (id, label, files, action) => {
      if (!files.length) return;
      html += `<div class="git-group"><span>${label} (${files.length})</span>${action || ''}</div>`;
      html += files.slice(0, MAX_FILES).map((f) => fileRow(f, id)).join('');
      if (files.length > MAX_FILES) html += `<div class="note">… e mais ${files.length - MAX_FILES}</div>`;
    };
    group('conflicts', 'Conflitos', r.conflicts);
    group('staged', 'No stage', r.staged, '<button data-act="unstage-all" title="Tirar tudo do stage">− tudo</button>');
    group('unstaged', 'Fora do stage', r.unstaged, '<button data-act="stage-all" title="Colocar tudo no stage (git add -A)">+ tudo</button>');
    if (!total) html = '<div class="note">Nada para commitar: a árvore de trabalho está limpa.</div>';
    listEl.innerHTML = html;

    const nothingStaged = !r.staged.length;
    hintEl.textContent = total && nothingStaged ? 'Nada no stage: o commit vai incluir todas as alterações (git add -A).' : '';
    $('#git-commit').disabled = !total && !r.op;
    $('#git-commit-push').disabled = (!total && !r.op) || !r.remote || r.branch === '(detached)';
  }

  function renderBranches(r) {
    const filter = branchFilterEl.value.trim().toLowerCase();
    const match = (b) => !filter || b.name.toLowerCase().includes(filter);
    const local = r.local.filter(match);
    const remote = r.remote.filter(match);
    branchesCountEl.textContent = r.local.length ? `(${r.local.length})` : '';
    const row = (b, isRemote) => `
      <div class="branch-row ${b.current ? 'current' : ''} ${b.gone ? 'gone' : ''}" data-branch="${esc(b.name)}" data-remote="${isRemote ? 1 : 0}"
           title="${esc(b.name)}${b.upstream ? ` → ${esc(b.upstream)}` : ''}${b.gone ? ' (remota apagada)' : ''}\n${esc(b.subject)}">
        ${ICON.branch}<span class="bname">${esc(b.name)}</span>${abHtml(b.ahead, b.behind)}<span class="when">${ago(b.date)}</span>
      </div>`;
    let html = '';
    if (creatingBranch) {
      html += '<div class="git-new-branch"><input id="git-new-branch-name" type="text" placeholder="nome-da-branch (Enter cria, Esc cancela)" spellcheck="false" autocomplete="off"></div>';
    }
    html += local.map((b) => row(b, false)).join('') || (filter ? '<div class="note">Nenhuma branch local com esse nome</div>' : '');
    if (r.remote.length) {
      html += `<button class="git-remote-toggle" data-act="toggle-remotes">${showRemotes || filter ? '▾' : '▸'} Remotas (${r.remote.length})</button>`;
      if (showRemotes || filter) html += remote.map((b) => row(b, true)).join('');
    }
    branchListEl.innerHTML = html;
    if (creatingBranch) {
      const input = $('#git-new-branch-name');
      input.focus();
      input.addEventListener('keydown', (ev) => {
        ev.stopPropagation();
        if (ev.key === 'Enter') createBranch(input.value.trim());
        else if (ev.key === 'Escape') { creatingBranch = false; render(); api.focusTerminal(); }
      });
    }
  }

  // ------------------------------------------------------------------ actions

  function dirty() {
    return repo && (repo.staged.length + repo.unstaged.filter((f) => !f.untracked).length + repo.conflicts.length) > 0;
  }

  async function background(args, okMessage) {
    const res = await git(args, { write: true });
    if (res.code !== 0) api.toast((res.err || res.out || 'O git falhou').trim().split('\n').slice(-1)[0]);
    else if (okMessage) api.toast(okMessage);
    scheduleRefresh(0);
    return res;
  }

  function headAction(act) {
    if (!repo) return;
    if (act === 'fetch') type('git fetch --prune');
    else if (act === 'pull') type('git pull');
    else if (act === 'push') type(repo.upstream ? 'git push' : `git push -u ${q(repo.remote || 'origin')} HEAD`);
  }

  function opAction(which) {
    const op = repo && repo.op;
    if (!op) return;
    if (which === 'abort') return type(`git ${op} --abort`);
    // A merge is concluded by a commit; the others have --continue.
    type(op === 'merge' ? 'git commit --no-edit' : `git ${op} --continue`);
  }

  function commitCommands(push) {
    const message = messageEl.value.trim();
    if (!message) {
      api.toast('Escreva a mensagem do commit');
      messageEl.focus();
      return null;
    }
    // First paragraph = subject; the rest becomes the body (each paragraph its own -m).
    const paragraphs = message.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
    const commit = `git commit ${paragraphs.map((p) => `-m ${q(p)}`).join(' ')}`;
    const cmds = [];
    if (!repo.staged.length && !repo.op) cmds.push('git add -A');
    cmds.push(commit);
    if (push) cmds.push(repo.upstream ? 'git push' : `git push -u ${q(repo.remote || 'origin')} HEAD`);
    return cmds;
  }

  function commit(push) {
    if (!repo) return;
    const cmds = commitCommands(push);
    if (!cmds) return;
    type(cmds);
    messageEl.value = '';
  }

  function switchTo(name, isRemote, anchor) {
    if (!repo) return;
    let cmd;
    if (isRemote) {
      const localName = name.slice(name.indexOf('/') + 1);
      const existing = repo.local.find((b) => b.name === localName);
      cmd = existing ? `git switch ${q(localName)}` : `git switch --track ${q(name)}`;
    } else {
      if (repo.local.find((b) => b.name === name && b.current)) return;
      cmd = `git switch ${q(name)}`;
    }
    if (!dirty()) return type(cmd);
    const r = anchor.getBoundingClientRect();
    api.openMenu(r.left, r.bottom, [
      { label: 'Guardar alterações (stash) e trocar', run: () => type([`git stash push -u -m ${q(`ronic: antes de trocar para ${name}`)}`, cmd]) },
      { label: 'Trocar levando as alterações', run: () => type(cmd) },
      '-',
      { label: 'Cancelar', run: () => {} },
    ]);
  }

  async function createBranch(name) {
    if (!name) return;
    const check = await git(['check-ref-format', '--branch', name]);
    if (check.code !== 0) { api.toast(`Nome de branch inválido: ${name}`); return; }
    creatingBranch = false;
    type(`git switch -c ${q(name)}`);
    render();
  }

  async function cleanupMerged() {
    if (!repo) return;
    const base = repo.upstream ? repo.upstream : repo.branch;
    const res = await git(['branch', '--merged', base, '--format=%(refname:short)']);
    const keep = new Set([repo.branch, 'main', 'master', 'develop', 'dev', 'trunk']);
    const merged = res.out.split('\n').map((s) => s.trim()).filter((b) => b && !keep.has(b));
    if (!merged.length) { api.toast('Nenhuma branch mergeada para limpar'); return; }
    const r = $('#git-cleanup').getBoundingClientRect();
    api.openMenu(r.left - 160, r.bottom + 4, [
      { label: `Excluir ${merged.length} branch${merged.length > 1 ? 'es' : ''} já mergeada${merged.length > 1 ? 's' : ''} em ${base}`, run: () => type(`git branch -d ${merged.map(q).join(' ')}`) },
      ...merged.slice(0, 8).map((b) => ({ label: `   ${b}`, run: () => type(`git branch -d ${q(b)}`) })),
      '-',
      { label: 'Cancelar', run: () => {} },
    ]);
  }

  function branchMenu(ev, name, isRemote) {
    ev.preventDefault();
    const current = !isRemote && repo.local.find((b) => b.name === name && b.current);
    const items = [];
    if (!current) items.push({ label: 'Trocar para esta branch', run: () => switchTo(name, isRemote, ev.target) });
    if (!current) items.push({ label: `Mesclar em ${repo.branch} (git merge)`, run: () => type(`git merge ${q(name)}`) });
    if (!current) items.push({ label: `Rebase de ${repo.branch} sobre esta`, run: () => type(`git rebase ${q(name)}`) });
    items.push({ label: 'Copiar nome', run: () => { api.copy(name); api.toast('Nome da branch copiado'); } });
    if (!isRemote && !current) {
      items.push('-');
      items.push({ label: 'Excluir branch (git branch -d)', run: () => type(`git branch -d ${q(name)}`) });
    }
    api.openMenu(ev.clientX, ev.clientY, items);
  }

  // ---------------------------------------------------------------- diff viewer

  async function showDiff(path, group) {
    const file = (repo[group] || []).find((f) => f.path === path) || {};
    const args = group === 'staged' ? ['diff', '--cached', '--no-color', '--no-ext-diff', '--', path]
      : file.untracked ? ['diff', '--no-color', '--no-ext-diff', '--no-index', '--', '/dev/null', path]
      : ['diff', '--no-color', '--no-ext-diff', '--', path];
    diffTitleEl.innerHTML = `${esc(path)}<small>${group === 'staged' ? 'no stage' : group === 'conflicts' ? 'em conflito' : file.untracked ? 'arquivo novo' : 'alterações'}</small>`;
    diffBodyEl.textContent = 'carregando…';
    diffEl.hidden = false;
    const res = await git(args);
    const text = res.out || res.err || '';
    if (!text.trim()) { diffBodyEl.textContent = 'Sem diferenças de texto (arquivo binário ou só permissões).'; return; }
    const frag = document.createDocumentFragment();
    for (const line of text.split('\n').slice(0, 5000)) {
      const div = document.createElement('div');
      div.textContent = line || ' ';
      if (/^(diff |index |--- |\+\+\+ |new file|deleted file|similarity|rename |old mode|new mode)/.test(line)) div.className = 'meta';
      else if (line.startsWith('@@')) div.className = 'hunk';
      else if (line.startsWith('+')) div.className = 'add';
      else if (line.startsWith('-')) div.className = 'del';
      frag.appendChild(div);
    }
    diffBodyEl.replaceChildren(frag);
    diffBodyEl.scrollTop = 0;
  }

  function closeDiff() {
    if (diffEl.hidden) return false;
    diffEl.hidden = true;
    api.focusTerminal();
    return true;
  }

  // ------------------------------------------------------------------ events

  headEl.addEventListener('click', (ev) => {
    const b = ev.target.closest('button[data-act]');
    if (b && !b.disabled) headAction(b.dataset.act);
  });
  bannerEl.addEventListener('click', (ev) => {
    const b = ev.target.closest('button[data-op]');
    if (b && !b.disabled) opAction(b.dataset.op);
  });

  listEl.addEventListener('click', (ev) => {
    if (!repo || repo.state !== 'repo') return;
    const groupAction = ev.target.closest('.git-group button[data-act]');
    if (groupAction) {
      if (groupAction.dataset.act === 'stage-all') background(['add', '-A']);
      else background(repo.oid === '(initial)' ? ['rm', '-r', '--cached', '-q', '--', '.'] : ['reset', '-q']);
      return;
    }
    const row = ev.target.closest('.file-row');
    if (!row) return;
    const { path, group } = row.dataset;
    const act = ev.target.closest('button[data-act]');
    if (!act) return showDiff(path, group);
    const key = `${group}:${path}`;
    switch (act.dataset.act) {
      case 'stage': background(['add', '--', path]); break;
      case 'resolve': background(['add', '--', path], 'Marcado como resolvido'); break;
      case 'unstage':
        background(repo.oid === '(initial)' ? ['rm', '--cached', '-q', '--', path] : ['restore', '--staged', '--', path]);
        break;
      case 'discard': {
        if (armedDiscard !== key) {
          armedDiscard = key;
          renderChanges(repo);
          setTimeout(() => { if (armedDiscard === key) { armedDiscard = ''; renderChanges(repo); } }, 3000);
          return;
        }
        armedDiscard = '';
        const file = repo.unstaged.find((f) => f.path === path) || {};
        background(file.untracked ? ['clean', '-f', '-d', '-q', '--', path] : ['restore', '--worktree', '--', path], 'Alterações descartadas');
        break;
      }
      default: break;
    }
  });

  branchListEl.addEventListener('click', (ev) => {
    if (ev.target.closest('[data-act="toggle-remotes"]')) { showRemotes = !showRemotes; renderBranches(repo); return; }
    const row = ev.target.closest('.branch-row');
    if (row) switchTo(row.dataset.branch, row.dataset.remote === '1', row);
  });
  branchListEl.addEventListener('contextmenu', (ev) => {
    const row = ev.target.closest('.branch-row');
    if (row) branchMenu(ev, row.dataset.branch, row.dataset.remote === '1');
  });
  branchFilterEl.addEventListener('input', () => repo && repo.state === 'repo' && renderBranches(repo));
  branchFilterEl.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') { branchFilterEl.value = ''; renderBranches(repo); api.focusTerminal(); } });

  $('#git-new-branch').addEventListener('click', () => { if (repo && repo.state === 'repo') { creatingBranch = true; renderBranches(repo); } });
  $('#git-cleanup').addEventListener('click', cleanupMerged);
  $('#git-refresh').addEventListener('click', () => scheduleRefresh(0));
  $('#git-commit').addEventListener('click', () => commit(false));
  $('#git-commit-push').addEventListener('click', () => commit(true));
  messageEl.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) { ev.preventDefault(); commit(ev.shiftKey); }
    else if (ev.key === 'Escape') api.focusTerminal();
  });
  $('#diff-close').addEventListener('click', closeDiff);

  // Width (drag the left edge).
  const resizer = $('#git-resizer');
  resizer.addEventListener('pointerdown', (ev) => {
    ev.preventDefault();
    resizer.setPointerCapture(ev.pointerId);
    resizer.classList.add('dragging');
    const startX = ev.clientX;
    const startW = api.state.settings.gitWidth;
    const move = (e) => {
      const w = Math.round(Math.min(560, Math.max(220, startW - (e.clientX - startX))));
      document.documentElement.style.setProperty('--git-w', `${w}px`);
      api.state.settings.gitWidth = w;
    };
    const up = () => {
      resizer.classList.remove('dragging');
      resizer.removeEventListener('pointermove', move);
      resizer.removeEventListener('pointerup', up);
      api.setSetting('gitWidth', api.state.settings.gitWidth);
    };
    resizer.addEventListener('pointermove', move);
    resizer.addEventListener('pointerup', up);
  });

  // Light polling while visible: catches files changed by an editor, not only by the shell.
  function startPolling() {
    clearInterval(pollTimer);
    pollTimer = setInterval(() => {
      if (visible() && document.visibilityState === 'visible' && !refreshing) refresh();
    }, POLL_MS);
  }

  // ------------------------------------------------------------------ app.js hooks

  function applySettings() {
    const s = api.state.settings;
    document.documentElement.classList.toggle('no-git', !s.showGit);
    document.documentElement.style.setProperty('--git-w', `${s.gitWidth}px`);
    $('#git-btn').classList.toggle('on', s.showGit);
    if (s.showGit) { startPolling(); scheduleRefresh(0); } else clearInterval(pollTimer);
  }

  return {
    applySettings,
    /** Active tab changed, or its directory did. */
    sync: () => scheduleRefresh(60),
    /** A command finished (prompt is back). */
    onPrompt: (tab) => { if (tab === api.activeTab()) scheduleRefresh(80); },
    onFocus: () => scheduleRefresh(0),
    closeDiff,
    /** Diagnostics / self-test. */
    snapshot: () => repo && { state: repo.state, branch: repo.branch, ahead: repo.ahead, behind: repo.behind, op: repo.op,
      staged: (repo.staged || []).length, unstaged: (repo.unstaged || []).length, local: (repo.local || []).length },
  };
};
