'use strict';

// Worktree manager for abema-androidtv.
// Zero dependencies: Node built-in modules only. Run with `node server.js`.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

// --- Config -----------------------------------------------------------------
const PORT = 4180;
const MAIN_REPO = '/Users/s24270/Documents/Github/abema-androidtv';
const WORKTREE_DIR = '/Users/s24270/Documents/Github/worktrees';
const BRANCH_PREFIX = 'suraj/';
// The create logic lives in a standalone shell script so it can also be invoked
// from a Claude skill or any shell. The server just shells out to it.
const CREATE_SCRIPT = path.join(__dirname, 'create-worktree.sh');
const ADD_EXISTING_SCRIPT = path.join(__dirname, 'add-existing-worktree.sh');
const INDEX_HTML = path.join(__dirname, 'index.html');
const FAVICON = path.join(__dirname, 'favicon.svg');

// --- Small helpers ----------------------------------------------------------

// Run a command without a shell (arg array => no injection). Never rejects;
// resolves { code, stdout, stderr } so callers can inspect git's own errors.
function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { ...opts });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', (err) => resolve({ code: -1, stdout, stderr: String(err.message || err) }));
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

const git = (args, cwd = MAIN_REPO) => run('git', args, { cwd });

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      if (raw.length > 1e6) reject(new Error('body too large'));
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error('invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

// --- Git operations ---------------------------------------------------------

// List worktrees under WORKTREE_DIR with per-row status.
async function listWorktrees() {
  const { stdout } = await git(['worktree', 'list', '--porcelain']);
  const entries = [];
  let cur = null;
  for (const line of stdout.split('\n')) {
    if (line.startsWith('worktree ')) {
      cur = { path: line.slice('worktree '.length) };
    } else if (line.startsWith('branch ') && cur) {
      cur.branch = line.slice('branch '.length).replace('refs/heads/', '');
    } else if (line.startsWith('HEAD ') && cur) {
      cur.head = line.slice('HEAD '.length);
    } else if (line === '' && cur) {
      entries.push(cur);
      cur = null;
    }
  }
  if (cur) entries.push(cur);

  const prefix = WORKTREE_DIR + path.sep;
  const managed = entries.filter((e) => e.path && e.path.startsWith(prefix));

  return Promise.all(
    managed.map(async (e) => {
      const [dirtyRes, baseRef, unpushedRes] = await Promise.all([
        git(['status', '--porcelain'], e.path),
        determineBaseRef(e.branch, e.path),
        git(['rev-list', '--count', 'HEAD', '--not', '--remotes'], e.path),
      ]);
      const aheadBehindRes = await git(['rev-list', '--left-right', '--count', `${baseRef}...HEAD`], e.path);
      const statusLines = dirtyRes.stdout.split('\n').filter(Boolean);
      const dirty = statusLines.length > 0;
      // Unmerged status codes (both-modified etc.) mean a merge conflict is unresolved.
      const conflicts = statusLines.some((l) => /^(DD|AU|UD|UA|DU|AA|UU) /.test(l));
      let behind = 0;
      let ahead = 0;
      const m = aheadBehindRes.stdout.trim().split(/\s+/);
      if (aheadBehindRes.code === 0 && m.length === 2) {
        behind = parseInt(m[0], 10) || 0;
        ahead = parseInt(m[1], 10) || 0;
      }
      const unpushed = unpushedRes.code === 0 ? parseInt(unpushedRes.stdout.trim(), 10) || 0 : 0;
      return {
        branch: e.branch || '(detached)',
        name: e.branch ? e.branch.replace(BRANCH_PREFIX, '') : e.branch,
        path: e.path,
        folder: path.basename(e.path),
        dirty,
        conflicts,
        ahead,
        behind,
        unpushed,
      };
    })
  );
}

// Determine the base ref for ahead/behind comparison. If origin/<branch> exists,
// use that; otherwise fall back to origin/main.
async function determineBaseRef(branch, wtPath) {
  if (!branch) return 'origin/main';
  const checkRef = await git(['rev-parse', '-q', '--verify', `origin/${branch}@{upstream}`], wtPath);
  if (checkRef.code === 0) return `origin/${branch}`;
  const checkRemote = await git(['rev-parse', '-q', '--verify', `origin/${branch}`], wtPath);
  if (checkRemote.code === 0) return `origin/${branch}`;
  return 'origin/main';
}

// Delegates to create-worktree.sh (the single source of truth for create).
async function createWorktree(name, base) {
  const args = [CREATE_SCRIPT, name];
  if (base) args.push(base);
  const res = await run('bash', args);
  const output = [res.stdout, res.stderr].filter(Boolean).join('').trim();
  if (res.code !== 0) {
    return { ok: false, error: output.replace(/^error:\s*/, '') || 'create failed' };
  }
  return { ok: true, output };
}

// Delegates to add-existing-worktree.sh (checks out a branch that already exists).
async function addExistingWorktree(branch) {
  const res = await run('bash', [ADD_EXISTING_SCRIPT, branch]);
  const output = [res.stdout, res.stderr].filter(Boolean).join('').trim();
  if (res.code !== 0) {
    return { ok: false, error: output.replace(/^error:\s*/, '') || 'add failed' };
  }
  return { ok: true, output };
}

async function deleteWorktree(wtPath, branch) {
  if (!wtPath || !wtPath.startsWith(WORKTREE_DIR + path.sep)) {
    return { ok: false, error: 'refusing to delete: path is not a managed worktree' };
  }
  const rm = await git(['worktree', 'remove', '--force', wtPath]);
  if (rm.code !== 0) {
    return { ok: false, error: (rm.stderr || rm.stdout || 'git worktree remove failed').trim() };
  }
  if (branch && branch !== '(detached)') {
    const del = await git(['branch', '-D', branch]);
    if (del.code !== 0) {
      return {
        ok: true,
        warning: `worktree removed, but deleting branch failed:\n${(del.stderr || del.stdout).trim()}`,
      };
    }
  }
  return { ok: true };
}

// Fetch the latest origin/main and merge it into the worktree's branch.
// On conflict the merge is left in progress (resolve in Android Studio / abort
// with `git merge --abort`) and we report it so the UI can warn.
async function pullLatest(wtPath) {
  if (!wtPath || !wtPath.startsWith(WORKTREE_DIR + path.sep)) {
    return { ok: false, error: 'refusing to pull: path is not a managed worktree' };
  }
  if (!fs.existsSync(wtPath)) return { ok: false, error: 'worktree folder no longer exists' };

  const merging = await git(['rev-parse', '-q', '--verify', 'MERGE_HEAD'], wtPath);
  if (merging.code === 0) {
    return { ok: false, error: 'a merge is already in progress — resolve or abort it first' };
  }

  const fetch = await git(['fetch', 'origin', 'main'], wtPath);
  if (fetch.code !== 0) {
    return { ok: false, error: (fetch.stderr || 'git fetch failed').trim() };
  }

  const merge = await git(['merge', '--no-edit', 'origin/main'], wtPath);
  if (merge.code === 0) {
    const msg = merge.stdout.trim();
    return { ok: true, output: /Already up to date/i.test(msg) ? 'Already up to date.' : 'Merged latest origin/main.' };
  }

  const unmerged = await git(['diff', '--name-only', '--diff-filter=U'], wtPath);
  if (unmerged.code === 0 && unmerged.stdout.trim()) {
    const files = unmerged.stdout.trim().split('\n');
    return {
      ok: false,
      conflict: true,
      error:
        'Merge conflict in ' + files.length + ' file' + (files.length === 1 ? '' : 's') +
        ' — resolve in Android Studio (or run `git merge --abort`):\n' + files.join('\n'),
    };
  }
  return { ok: false, error: (merge.stderr || merge.stdout || 'git merge failed').trim() };
}

async function openInStudio(wtPath) {
  if (!wtPath || !wtPath.startsWith(WORKTREE_DIR + path.sep)) {
    return { ok: false, error: 'refusing to open: path is not a managed worktree' };
  }
  if (!fs.existsSync(wtPath)) return { ok: false, error: 'worktree folder no longer exists' };
  const res = await run('open', ['-a', 'Android Studio', wtPath]);
  if (res.code !== 0) return { ok: false, error: (res.stderr || 'failed to open Android Studio').trim() };
  return { ok: true };
}

// --- HTTP server ------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const { pathname } = url;

    if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
      const html = fs.readFileSync(INDEX_HTML);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(html);
    }

    if (req.method === 'GET' && pathname === '/favicon.svg') {
      res.writeHead(200, { 'Content-Type': 'image/svg+xml; charset=utf-8', 'Cache-Control': 'no-cache' });
      return res.end(fs.readFileSync(FAVICON));
    }

    if (req.method === 'GET' && pathname === '/api/worktrees') {
      return sendJson(res, 200, { worktrees: await listWorktrees() });
    }

    if (req.method === 'POST' && pathname === '/api/worktrees') {
      const body = await readBody(req);
      const result = await createWorktree(
        typeof body.name === 'string' ? body.name : '',
        typeof body.base === 'string' && body.base ? body.base : undefined
      );
      return sendJson(res, result.ok ? 200 : 400, result);
    }

    if (req.method === 'POST' && pathname === '/api/worktrees/existing') {
      const body = await readBody(req);
      const result = await addExistingWorktree(typeof body.branch === 'string' ? body.branch : '');
      return sendJson(res, result.ok ? 200 : 400, result);
    }

    if (req.method === 'POST' && pathname === '/api/delete') {
      const body = await readBody(req);
      const result = await deleteWorktree(body.path, body.branch);
      return sendJson(res, result.ok ? 200 : 400, result);
    }

    if (req.method === 'POST' && pathname === '/api/pull') {
      const body = await readBody(req);
      const result = await pullLatest(body.path);
      return sendJson(res, result.ok ? 200 : result.conflict ? 409 : 400, result);
    }

    if (req.method === 'POST' && pathname === '/api/open') {
      const body = await readBody(req);
      const result = await openInStudio(body.path);
      return sendJson(res, result.ok ? 200 : 400, result);
    }

    sendJson(res, 404, { error: 'not found' });
  } catch (e) {
    sendJson(res, 500, { error: String(e.message || e) });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Worktree manager running → http://localhost:${PORT}`);
  console.log(`Main repo: ${MAIN_REPO}`);
  console.log('Press Ctrl+C to stop.');
});
