#!/usr/bin/env node
// Command evidence for the agent-coordinated PROJ gate; no second scheduler.
//   quality.mjs PROJ THEME [check|snapshot|run KIND|record-build LOG HEAD INPUTS|review REPORT|skip-sonar REASON|sonar-issues FILE]
//   quality.mjs seal PROJ THEME   refuse to seal P5 unless every record is current and progress.md shows its status block
// The record actions write 5_progress/quality-*.json and refresh the rendered "### Gate Status" block of the
// "## Quality Gate" section in progress.md; `seal` only reads (exit 0 sealable, 1 not, 64 usage).
// `run sonar` also appends to quality-sonar-rounds.json (scan history); `sonar-issues FILE` binds the saved output of
// `sonar list issues` to the current scan; `seal` then checks the carry-forward notes in progress.md against both.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync, spawnSync, spawn } from 'node:child_process';

const argv = process.argv.slice(2);
const [proj, theme, action = 'check', kind, ...args] = argv[0] === 'seal' ? [argv[1], argv[2], 'seal'] : argv;
// Leading whitespace belongs to filenames in NUL-delimited output.
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).replace(/\n$/, '');
const hash = value => createHash('sha256').update(value).digest('hex');
const base = `specs/PROJ-${proj}-${theme}`;
const progress = `${base}/5_progress`;
const configPath = `${base}/3-4_plan/wave-gate-config.json`;
const progressFile = `${progress}/PROJ-${proj}-progress.md`;
const evidencePath = key => `${progress}/quality-${encodeURIComponent(key)}.json`;
const operational = name => name.startsWith(`${progress}/`) || [`${base}/state.json`, `${base}/findings.json`, `${base}/.findings.lock`].includes(name);
function snapshotFile(name) {
  const stat = fs.lstatSync(name);
  if (stat.isSymbolicLink()) throw new Error(`artifact/input symlink unsupported: ${name}`);
  if (stat.isDirectory()) return fs.readdirSync(name).sort().map(child => [child, snapshotFile(path.join(name, child))]);
  return hash(fs.readFileSync(name));
}
function inputs() {
  const changed = [...git('diff', '--name-only', 'HEAD', '-z').split('\0'), ...git('ls-files', '--others', '--exclude-standard', '-z').split('\0')].filter(Boolean);
  if (changed.some(name => !operational(name))) throw new Error('commit non-evidence changes before verification');
  // Evidence-only commits do not invalidate the code/configuration being verified.
  const tree = git('ls-tree', '-rz', 'HEAD').split('\0').filter(line => line && !operational(line.split('\t')[1]));
  const local = fs.readdirSync('.').filter(name => name === '.env' || name.startsWith('.env.'));
  for (const name of ['node_modules/.package-lock.json', 'node_modules/.modules.yaml']) if (fs.existsSync(name)) local.push(name);
  const installEpoch = fs.existsSync('node_modules') ? fs.statSync('node_modules').mtimeMs : null;
  return hash(JSON.stringify([tree, local.sort().map(name => [name, hash(fs.readFileSync(name))]), installEpoch, Object.entries(process.env).filter(([name]) => !['_', 'SHLVL', 'PWD', 'OLDPWD'].includes(name)).sort(), process.version, process.platform, process.arch]));
}
function artifacts(names) {
  if (!Array.isArray(names) || names.some(name => typeof name !== 'string' || !name.trim())) throw new Error('artifact paths must be non-empty strings');
  return names.map(name => [name, snapshotFile(name)]);
}
function selected(log) {
  // Same common runner summaries accepted by the wave gate: Vitest, TAP, pytest/Playwright.
  log = log.replace(/\x1b\[[0-9;]*m/g, '');
  const counts = [...log.matchAll(/(?:Tests\s+[^\n]*?([0-9]+)\s+passed|# tests\s+([0-9]+)|Running\s+([0-9]+)\s+tests?|(?:^|\n)\s*([0-9]+)\s+passed)/g)].map(m => Number(m.slice(1).find(v => v !== undefined)));
  return Math.max(0, ...counts);
}
function mutants(log) {
  // Positive control for mutation runs: the wrapper must print how many mutants it tested ("42 mutants", "Mutants: 42").
  log = log.replace(/\x1b\[[0-9;]*m/g, '');
  return Math.max(0, ...[...log.matchAll(/([0-9]+)\s+(?:mutants?|mutations?)\b|\b(?:mutants?|mutations?)\s*[:=]\s*([0-9]+)/gi)].map(m => Number(m[1] ?? m[2])));
}
function survivors(log) {
  // Mutation wrappers print "Survivors: N" next to "Mutants: N"; exit 1 without it is not survivor evidence.
  log = log.replace(/\x1b\[[0-9;]*m/g, '');
  return Math.max(0, ...[...log.matchAll(/\bsurvivors?\s*[:=]\s*([0-9]+)/gi)].map(m => Number(m[1])));
}
function mutationBase() { return git('rev-parse', '--verify', `proj-PROJ-${proj}-base^{commit}`); }
const roundsPath = `${progress}/quality-sonar-rounds.json`;
const rounds = () => fs.existsSync(roundsPath) ? JSON.parse(fs.readFileSync(roundsPath, 'utf8')) : [];
const SONAR_OPEN = ['OPEN', 'CONFIRMED', 'REOPENED'], SONAR_BLOCKING = ['BLOCKER', 'CRITICAL', 'MAJOR'];
// "### Carried Forward (<kind>…" up to the next heading, or null.
function carriedForward(text, kind) {
  const heading = new RegExp(`^### Carried Forward \\(${kind}[^\\n]*$`, 'm').exec(text);
  if (!heading) return null;
  const rest = text.slice(heading.index + heading[0].length), next = /^#{1,3} /m.exec(rest);
  return next ? rest.slice(0, next.index) : rest;
}
function write(key, record) {
  const target = evidencePath(key), temp = `${target}.${randomUUID()}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(record, null, 2) + '\n'); fs.renameSync(temp, target);
}
function commandFor(key, config) {
  if (key.startsWith('test:')) return (config.phase_commands ?? []).find(entry => entry.phase === 'quality' && entry.label === key.slice(5))?.command;
  return key === 'lint' ? config.lint_cmd ?? 'npm run lint' : config[`${key}_cmd`];
}
function valid(key, config, fingerprint) {
  const record = JSON.parse(fs.readFileSync(evidencePath(key), 'utf8'));
  // Mutation contract: exit 0 = the tool's own threshold is met, exit 1 with mutants analysed = survivors (the progress status decides
  // whether they block); any other non-zero exit (timeout 124/137, crash) is a failed run, never survivor evidence.
  if (record.inputs !== fingerprint || !record.head || (record.rc !== 0 && !(key === 'mutation' && record.rc === 1 && record.mutants > 0 && record.survivors > 0))) throw new Error(`${key}: stale or failed evidence`);
  if (!['review', 'sonar-skip', 'sonar-issues'].includes(key) && record.command !== commandFor(key, config)) throw new Error(`${key}: command changed`);
  if (!record.log || snapshotFile(record.log) !== record.log_hash) throw new Error(`${key}: log missing or changed`);
  if (JSON.stringify(artifacts(record.artifacts.map(([name]) => name))) !== JSON.stringify(record.artifacts)) throw new Error(`${key}: artifacts missing or changed`);
  if ((key === 'coverage' || key.startsWith('test:')) && !(record.selected > 0)) throw new Error(`${key}: no tests selected`);
  if (key === 'mutation' && !(record.mutants > 0)) throw new Error('mutation: no mutants analysed');
  if ((key === 'mutation' || key === 'sonar-issues') && record.base_sha !== mutationBase()) throw new Error(`${key}: base tag moved since the run`);
  if (key === 'sonar-issues' && record.ce_task !== valid('sonar', config, fingerprint).ce_task) throw new Error('sonar-issues: recorded for a different scan');
  return record;
}
function canSkip(reason) {
  const available = name => spawnSync('bash', ['-c', 'command -v "$1" >/dev/null', '_', name]).status === 0;
  if (reason === 'sonar CLI unavailable') return !available('sonar') || !available('sonar-scanner');
  return reason === 'project not configured' && !fs.existsSync('sonar-project.properties');
}
const STATUS_BEGIN = '<!-- quality-status: rendered by chain quality from 5_progress/quality-*.json, never edit -->', STATUS_END = '<!-- /quality-status -->';
// The status block is derived from the records alone; a record that is missing, stale or failed reads "pending".
function statusBlock(config, fingerprint) {
  const current = key => { try { return valid(key, config, fingerprint); } catch { return null; } };
  const passed = keys => keys.every(key => current(key)) ? 'passed' : 'pending';
  const tests = [...(config.coverage_cmd ? ['coverage'] : []), ...(config.phase_commands ?? []).filter(e => e.phase === 'quality').map(e => `test:${e.label}`)];
  const mutation = !config.mutation_cmd ? 'skipped (not configured)' : current('mutation') ? (current('mutation').rc === 0 ? 'ran' : `ran (${current('mutation').survivors} survivors carried forward)`) : 'pending';
  const skip = fs.existsSync(evidencePath('sonar-skip')) ? current('sonar-skip') : null;
  const issues = current('sonar-issues');
  const sonar = skip ? (canSkip(skip.reason) ? `skipped (${skip.reason})` : 'pending') : current('sonar') && issues ? (issues.open.length ? `ran (${issues.open.length} carried forward)` : 'ran') : 'pending';
  const rows = [['Code Review', passed(['review'])], ['Mutation', mutation], ['Build', passed(['build'])], ['Tests', tests.length ? passed(tests) : 'skipped (none declared)'], ['Lint', passed(['lint'])], ['SonarCloud', sonar]];
  return [STATUS_BEGIN, '### Gate Status', '', '| Check | Status |', '|---|---|', ...rows.map(([name, status]) => `| ${name} | ${status} |`), STATUS_END].join('\n');
}
// The "## Quality Gate —" section: from its heading to the next "## " heading. The status block counts only inside it.
function qualitySection(text) {
  const heading = /^## Quality Gate —.*$/m.exec(text);
  if (!heading) return null;
  const next = /^## /m.exec(text.slice(heading.index + heading[0].length));
  return { start: heading.index, end: next ? heading.index + heading[0].length + next.index : text.length, headingEnd: heading.index + heading[0].length };
}
const STATUS_BLOCK = /<!-- quality-status:[^\n]*-->[\s\S]*?<!-- \/quality-status -->/g;
function refreshProgress(config, fingerprint) {
  if (!fs.existsSync(progressFile)) return;
  const block = statusBlock(config, fingerprint);
  let text = fs.readFileSync(progressFile, 'utf8');
  const section = qualitySection(text);
  if (!section) text = `${text.replace(STATUS_BLOCK, '').replace(/\n*$/, '\n')}\n## Quality Gate — PROJ-${proj}\n\n${block}\n`;
  else {
    let inner = text.slice(section.start, section.end), seen = false;
    inner = inner.replace(STATUS_BLOCK, () => seen++ ? '' : block); // first block updated, duplicates dropped
    if (!seen) inner = inner.replace(/^(## Quality Gate —.*)$/m, (line) => `${line}\n\n${block}`);
    text = text.slice(0, section.start).replace(STATUS_BLOCK, '') + inner + text.slice(section.end).replace(STATUS_BLOCK, '');
  }
  fs.writeFileSync(progressFile, text);
}
// Same rules as env-local.sh (sourced by every other gate): .env.local fills only unset variables, quotes stripped once per side.
function loadEnvLocal() {
  if (!fs.existsSync('.env.local')) return;
  for (const line of fs.readFileSync('.env.local', 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('='), key = eq < 0 ? line : line.slice(0, eq);
    const value = (eq < 0 ? line : line.slice(eq + 1)).replace(/"$/, '').replace(/^"/, '').replace(/'$/, '').replace(/^'/, '');
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && !process.env[key]) process.env[key] = value;
  }
}
function verifyAll(config, fingerprint) {
  for (const key of ['build', 'lint', 'review', ...(config.mutation_cmd ? ['mutation'] : []), ...(config.coverage_cmd ? ['coverage'] : []), ...(config.phase_commands ?? []).filter(e => e.phase === 'quality').map(e => `test:${e.label}`)]) valid(key, config, fingerprint);
  if (fs.existsSync(evidencePath('sonar-skip'))) {
    const skip = valid('sonar-skip', config, fingerprint);
    if (!canSkip(skip.reason)) throw new Error('Sonar skip no longer valid');
  } else { valid('sonar', config, fingerprint); valid('sonar-issues', config, fingerprint); }
}
async function main() {
  if (action === 'seal' && (!proj || !theme)) { console.error('Usage: quality.mjs seal PROJ THEME'); process.exit(64); }
  if (!proj || !theme || !/^[\w-]+$/.test(proj) || !/^[\w-]+$/.test(theme)) throw new Error('Usage: quality.mjs PROJ THEME [check|snapshot|run KIND|record-build LOG HEAD INPUTS|review REPORT|skip-sonar REASON|sonar-issues FILE] | seal PROJ THEME');
  if (fs.realpathSync('.') !== fs.realpathSync(git('rev-parse', '--show-toplevel'))) throw new Error('run from the worktree root');
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  if (action === 'seal') loadEnvLocal(); // the fingerprint hashes the environment the commands ran in
  const fingerprint = inputs();
  if (!['snapshot', 'record-build', 'seal'].includes(action)) {
    await act(config, fingerprint); // a failed action leaves the block alone, so a wrong environment cannot overwrite a green report
    refreshProgress(config, fingerprint);
  } else await act(config, fingerprint);
}
async function act(config, fingerprint) {
  if (action === 'snapshot') { console.log(fingerprint); return; }
  if (action === 'check') {
    verifyAll(config, fingerprint);
    console.log('✓ PROJ command evidence matches current inputs, commands, logs and artifacts'); return;
  }
  if (action === 'seal') {
    verifyAll(config, fingerprint);
    if (!fs.existsSync(progressFile)) throw new Error(`progress file missing: ${progressFile}`);
    const text = fs.readFileSync(progressFile, 'utf8'), section = qualitySection(text);
    if (!section) throw new Error('Quality Gate section missing in the progress file');
    // exactly one block in the whole file, inside the section, identical to the one derived from the records
    const blocks = text.match(STATUS_BLOCK) ?? [];
    if (blocks.length !== 1 || !text.slice(section.start, section.end).includes(blocks[0]) || blocks[0] !== statusBlock(config, fingerprint)) throw new Error('Quality Gate status block missing, duplicated, outside the section or edited — run `chain quality <X> <theme> check` to render it');
    // Carry-forward claims: the notes in progress.md must match the records.
    if (!fs.existsSync(evidencePath('sonar-skip'))) {
      const open = valid('sonar-issues', config, fingerprint).open;
      if (open.length && rounds().length < 4) throw new Error(`Sonar: ${open.length} issue(s) open but ${rounds().length} scan(s) recorded; carrying forward needs the initial scan plus three fix rounds`);
      const notes = carriedForward(text, 'Sonar') ?? '';
      const missing = open.filter(issue => !new RegExp(`(?<![\\w-])${issue.key.replace(/[^\w-]/g, '\\$&')}(?![\\w-])`).test(notes)); // whole key, not a prefix of a longer one
      if (missing.length) throw new Error(`Sonar issues missing from "### Carried Forward (Sonar": ${missing.map(issue => issue.key).join(', ')}`);
    }
    if (config.mutation_cmd && valid('mutation', config, fingerprint).rc === 1 && !/^\s*[-*] /m.test(carriedForward(text, 'Mutation') ?? '')) throw new Error('Mutation survivors need a bullet under "### Carried Forward (Mutation"');
    console.log('✓ Quality Gate proof present (code review, build, Sonar disposition)'); return;
  }
  if (action === 'sonar-issues') {
    const sonar = valid('sonar', config, fingerprint);
    if (!kind || !path.posix.normalize(kind).startsWith(`${progress}/`)) throw new Error(`usage: sonar-issues ${progress}/<file> (the saved output of: sonar list issues … --page-size 500)`);
    if (!fs.realpathSync(kind).startsWith(fs.realpathSync(progress) + path.sep)) throw new Error(`usage: sonar-issues ${progress}/<file> (a symlink out of ${progress}/ is not accepted)`);
    // The list must be fetched after this scan finished: an older saved file is not evidence for it.
    if (fs.statSync(kind).mtimeMs < fs.statSync(evidencePath('sonar')).mtimeMs) throw new Error('sonar issues file is older than the current scan; fetch the list again');
    const data = JSON.parse(fs.readFileSync(kind, 'utf8'));
    if (!Array.isArray(data.issues) || !Number.isInteger(data.paging?.total)) throw new Error('not the output of sonar list issues');
    if (data.issues.length !== data.paging.total) throw new Error(`sonar issues incomplete (${data.issues.length} of ${data.paging.total}); fetch every page`);
    if (new Set(data.issues.map(issue => issue.key)).size !== data.issues.length) throw new Error('sonar issues contain duplicates (a page pasted twice?); fetch every page once');
    const baseSha = mutationBase(), changed = new Set(git('diff', '-z', '--name-only', `${baseSha}..HEAD`).split('\0').filter(Boolean));
    const open = data.issues.filter(issue => SONAR_OPEN.includes(issue.status) && SONAR_BLOCKING.includes(issue.severity))
      .map(issue => ({ key: issue.key, severity: issue.severity, file: String(issue.component).replace(/^[^:]*:/, ''), line: issue.line ?? null, rule: issue.rule }))
      .filter(issue => changed.has(issue.file));
    write('sonar-issues', { head: git('rev-parse', 'HEAD'), inputs: fingerprint, rc: 0, log: kind, log_hash: snapshotFile(kind), artifacts: [], ce_task: sonar.ce_task, base_sha: baseSha, open, source: 'file' });
    console.log(`✓ sonar issues: ${open.length} open BLOCKER/CRITICAL/MAJOR in changed files`); return;
  }
  if (action === 'review' || action === 'skip-sonar') {
    const key = action === 'review' ? 'review' : 'sonar-skip';
    if (action === 'skip-sonar' && !canSkip(kind)) throw new Error('invalid Sonar skip');
    const log = action === 'review' ? kind : `${progress}/quality-sonar-skip.log`;
    if (action === 'skip-sonar') fs.writeFileSync(log, kind + '\n');
    if (!fs.readFileSync(log, 'utf8').trim()) throw new Error('review report is empty');
    write(key, { head: git('rev-parse', 'HEAD'), inputs: fingerprint, rc: 0, log, log_hash: snapshotFile(log), artifacts: [], reason: action === 'skip-sonar' ? kind : undefined }); return;
  }
  if (action !== 'run' && action !== 'record-build') throw new Error('unknown action');
  const key = action === 'record-build' ? 'build' : kind;
  const isMut = key === 'mutation', baseSha = isMut ? mutationBase() : undefined;
  const command = commandFor(key, config);
  if (!command?.trim()) throw new Error(`missing command for ${key}`);
  const artifactNames = config[`${key}_artifacts`] ?? [];
  if (key === 'coverage' && !artifactNames.length) throw new Error('coverage requires declared artifacts');
  if (action === 'run' && ['build', 'coverage'].includes(key) && artifactNames.length) {
    try {
      const previous = valid(key, config, fingerprint);
      if (JSON.stringify(previous.artifacts.map(([name]) => name)) !== JSON.stringify(artifactNames)) throw new Error('artifact configuration changed');
      console.log(`✓ reused ${key}: ${previous.log}`); return;
    } catch { /* Missing/stale evidence requires an actual command. */ }
  }
  if (key === 'sonar' && config.coverage_cmd) valid('coverage', config, fingerprint);
  fs.rmSync(evidencePath(key), { force: true });
  if (key === 'sonar') fs.rmSync(evidencePath('sonar-skip'), { force: true });
  const started = Date.now(), head = git('rev-parse', 'HEAD');
  let log, rc;
  if (action === 'record-build') {
    // Called only by wave-gate after its build process exits 0 and HEAD/clean checks pass.
    log = kind;
    if (args[0] !== head || args[1] !== fingerprint) throw new Error('wave build inputs changed');
    rc = 0;
  } else {
    log = `${progress}/quality-${encodeURIComponent(key)}-${randomUUID()}.log`;
    const fd = fs.openSync(log, 'w');
    const seconds = Number(config.timeouts?.[`${key}_seconds`] ?? config.timeouts?.ac_seconds ?? 600);
    if (!Number.isFinite(seconds) || seconds <= 0) throw new Error('invalid command timeout');
    let invocation = ['bash', '-c', command];
    const phase = (config.phase_commands ?? []).find(e => `test:${e.label}` === key);
    if (phase?.auth_consuming) {
      if (!config.auth_budget?.preflight_cmd || !fs.existsSync('scripts/worktree.sh')) throw new Error('auth quality command requires preflight and shared lock helper');
      invocation = ['bash', 'scripts/worktree.sh', 'with-shared-lock', '--', 'bash', '-c', 'bash -c "$1" && bash -c "$2"', '_', config.auth_budget.preflight_cmd, command];
    }
    let changedDir, mutationChild, interrupted = 0;
    const handlers = isMut ? ['SIGHUP', 'SIGINT', 'SIGQUIT', 'SIGTERM'].map(signal => [signal, () => {
      interrupted = 128 + os.constants.signals[signal];
      mutationChild?.kill('SIGTERM');
    }]) : [];
    for (const [signal, handler] of handlers) process.on(signal, handler);
    try {
      let env = process.env;
      if (isMut) {
        changedDir = fs.mkdtempSync(path.join(path.resolve(os.tmpdir()), 'skillchain-mutation-'));
        const changedFile = path.join(changedDir, 'changed-files');
        // shortcut: Git path output uses Node's 1 MiB buffer; stream it if a project exceeds that size.
        fs.writeFileSync(changedFile, execFileSync('git', ['diff', '-z', '--name-only', '--diff-filter=d', `${baseSha}..HEAD`]));
        // Child-only handoff preserves the input fingerprint; never inherit a legacy scope.
        env = { ...process.env, BASE_SHA: baseSha, CHANGED_FILES_FILE: changedFile };
        delete env.CHANGED_FILES;
      }
      const timeoutArgs = ['--kill-after=5s', String(seconds), ...invocation];
      if (isMut) {
        // Await the child so cancellation reaches timeout and still runs our cleanup.
        rc = await new Promise((resolve, reject) => {
          mutationChild = spawn('timeout', timeoutArgs, { stdio: ['ignore', fd, fd], env });
          mutationChild.once('error', reject);
          mutationChild.once('close', (status, signal) => {
            resolve(interrupted || (status ?? (signal ? 128 + os.constants.signals[signal] : 2)));
          });
        });
      } else {
        rc = spawnSync('timeout', timeoutArgs, { stdio: ['ignore', fd, fd], env }).status ?? 1;
      }
    } finally {
      fs.closeSync(fd);
      if (changedDir) fs.rmSync(changedDir, { recursive: true, force: true });
      for (const [signal, handler] of handlers) process.removeListener(signal, handler);
    }
  }
  const output = fs.readFileSync(log, 'utf8');
  const count = isMut ? mutants(output) : selected(output);
  if ((key === 'coverage' || key.startsWith('test:') || isMut) && !count) rc ||= 1;
  if (inputs() !== fingerprint || git('rev-parse', 'HEAD') !== head) rc ||= 1;
  let files = [], ceTask;
  if (rc === 0) {
    if (key === 'sonar') {
      const task = '.scannerwork/report-task.txt';
      if (!fs.existsSync(task) || fs.statSync(task).mtimeMs < started || !/^ceTaskId=.+/m.test(fs.readFileSync(task, 'utf8'))) throw new Error('Sonar produced no fresh task receipt');
      files = artifacts([task]); ceTask = /^ceTaskId=(.+)$/m.exec(fs.readFileSync(task, 'utf8'))[1];
    } else files = artifacts(artifactNames);
  }
  const survived = isMut ? survivors(output) : 0;
  write(key, { head, inputs: fingerprint, command, rc, ...(isMut ? { mutants: count, survivors: survived, base_sha: baseSha } : { selected: count }), ...(ceTask ? { ce_task: ceTask } : {}), log, log_hash: snapshotFile(log), artifacts: files });
  if (key === 'sonar' && rc === 0) fs.writeFileSync(roundsPath, JSON.stringify([...rounds(), { n: rounds().length + 1, head, ce_task: ceTask, at: new Date().toISOString() }], null, 2) + '\n');
  if (rc) throw new Error(`${key} failed (${rc})${isMut && count && rc === 1 ? (survived ? ' — surviving mutants, see log' : ' — exit 1 without a "Survivors: N" line, see log') : ''}; log: ${log}`);
  if (key === 'sonar') fs.rmSync(evidencePath('sonar-skip'), { force: true });
  console.log(`✓ ${key}: ${log}`);
}
try { await main(); } catch (error) { console.error(`quality: ${error.message}`); process.exitCode = 1; }
