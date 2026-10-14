#!/usr/bin/env node
// Command evidence for the agent-coordinated PROJ gate; no second scheduler.
//   quality.mjs PROJ THEME [check|snapshot|run KIND|record-build LOG HEAD INPUTS|review REPORT|skip-sonar REASON]
//   quality.mjs seal PROJ THEME   refuse to seal P5 unless every record is current and progress.md shows its status block
// The record actions write 5_progress/quality-*.json and refresh the rendered "### Gate Status" block of the
// "## Quality Gate" section in progress.md; `seal` only reads (exit 0 sealable, 1 not, 64 usage).
import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';

const argv = process.argv.slice(2);
const [proj, theme, action = 'check', kind, ...args] = argv[0] === 'seal' ? [argv[1], argv[2], 'seal'] : argv;
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
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
function mutationBase() { return git('rev-parse', '--verify', `proj-PROJ-${proj}-base^{commit}`); }
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
  if (record.inputs !== fingerprint || !record.head || (record.rc !== 0 && !(key === 'mutation' && record.rc === 1 && record.mutants > 0))) throw new Error(`${key}: stale or failed evidence`);
  if (key !== 'review' && key !== 'sonar-skip' && record.command !== commandFor(key, config)) throw new Error(`${key}: command changed`);
  if (!record.log || snapshotFile(record.log) !== record.log_hash) throw new Error(`${key}: log missing or changed`);
  if (JSON.stringify(artifacts(record.artifacts.map(([name]) => name))) !== JSON.stringify(record.artifacts)) throw new Error(`${key}: artifacts missing or changed`);
  if ((key === 'coverage' || key.startsWith('test:')) && !(record.selected > 0)) throw new Error(`${key}: no tests selected`);
  if (key === 'mutation' && !(record.mutants > 0)) throw new Error('mutation: no mutants analysed');
  if (key === 'mutation' && record.base_sha !== mutationBase()) throw new Error('mutation: base tag moved since the run');
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
  const mutation = !config.mutation_cmd ? 'skipped (not configured)' : current('mutation') ? (current('mutation').rc === 0 ? 'ran' : 'ran (survivors carried forward)') : 'pending';
  const skip = fs.existsSync(evidencePath('sonar-skip')) ? current('sonar-skip') : null;
  const sonar = skip ? (canSkip(skip.reason) ? `skipped (${skip.reason})` : 'pending') : current('sonar') ? 'ran' : 'pending';
  const rows = [['Code Review', passed(['review'])], ['Mutation', mutation], ['Build', passed(['build'])], ['Tests', tests.length ? passed(tests) : 'skipped (none declared)'], ['Lint', passed(['lint'])], ['SonarCloud', sonar]];
  return [STATUS_BEGIN, '### Gate Status', '', '| Check | Status |', '|---|---|', ...rows.map(([name, status]) => `| ${name} | ${status} |`), STATUS_END].join('\n');
}
function refreshProgress(config, fingerprint) {
  if (!fs.existsSync(progressFile)) return;
  const block = statusBlock(config, fingerprint), text = fs.readFileSync(progressFile, 'utf8');
  const marked = /<!-- quality-status:[^\n]*-->[\s\S]*?<!-- \/quality-status -->/, heading = /^## Quality Gate —.*$/m;
  fs.writeFileSync(progressFile, marked.test(text) ? text.replace(marked, () => block) : heading.test(text) ? text.replace(heading, line => `${line}\n\n${block}`) : `${text.replace(/\n*$/, '\n')}\n## Quality Gate — PROJ-${proj}\n\n${block}\n`);
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
  } else valid('sonar', config, fingerprint);
}
function main() {
  if (action === 'seal' && (!proj || !theme)) { console.error('Usage: quality.mjs seal PROJ THEME'); process.exit(64); }
  if (!proj || !theme || !/^[\w-]+$/.test(proj) || !/^[\w-]+$/.test(theme)) throw new Error('Usage: quality.mjs PROJ THEME [check|snapshot|run KIND|record-build LOG HEAD INPUTS|review REPORT|skip-sonar REASON] | seal PROJ THEME');
  if (fs.realpathSync('.') !== fs.realpathSync(git('rev-parse', '--show-toplevel'))) throw new Error('run from the worktree root');
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  if (action === 'seal') loadEnvLocal(); // the fingerprint hashes the environment the commands ran in
  const fingerprint = inputs();
  if (!['snapshot', 'record-build', 'seal'].includes(action)) {
    act(config, fingerprint); // a failed action leaves the block alone, so a wrong environment cannot overwrite a green report
    refreshProgress(config, fingerprint);
  } else act(config, fingerprint);
}
function act(config, fingerprint) {
  if (action === 'snapshot') { console.log(fingerprint); return; }
  if (action === 'check') {
    verifyAll(config, fingerprint);
    console.log('✓ PROJ command evidence matches current inputs, commands, logs and artifacts'); return;
  }
  if (action === 'seal') {
    verifyAll(config, fingerprint);
    if (!fs.existsSync(progressFile)) throw new Error(`progress file missing: ${progressFile}`);
    if (!fs.readFileSync(progressFile, 'utf8').includes(statusBlock(config, fingerprint))) throw new Error('Quality Gate status block missing or edited — run `chain quality <X> <theme> check` to render it');
    console.log('✓ Quality Gate proof present (code review, build, Sonar disposition)'); return;
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
    // Mutation gets the changed files as env: BASE_SHA (the P0 base tag) and CHANGED_FILES (newline-separated, deleted files excluded).
    // Passed to the child only, so the input fingerprint (which hashes process.env) is unaffected.
    const env = isMut ? { ...process.env, BASE_SHA: baseSha, CHANGED_FILES: git('diff', '--name-only', '--diff-filter=d', `${baseSha}..HEAD`) } : process.env;
    const result = spawnSync('timeout', ['--kill-after=5s', String(seconds), ...invocation], { stdio: ['ignore', fd, fd], env });
    fs.closeSync(fd); rc = result.status ?? 1;
  }
  const output = fs.readFileSync(log, 'utf8');
  const count = isMut ? mutants(output) : selected(output);
  if ((key === 'coverage' || key.startsWith('test:') || isMut) && !count) rc ||= 1;
  if (inputs() !== fingerprint || git('rev-parse', 'HEAD') !== head) rc ||= 1;
  let files = [];
  if (rc === 0) {
    if (key === 'sonar') {
      const task = '.scannerwork/report-task.txt';
      if (!fs.existsSync(task) || fs.statSync(task).mtimeMs < started || !/^ceTaskId=.+/m.test(fs.readFileSync(task, 'utf8'))) throw new Error('Sonar produced no fresh task receipt');
      files = artifacts([task]);
    } else files = artifacts(artifactNames);
  }
  write(key, { head, inputs: fingerprint, command, rc, ...(isMut ? { mutants: count, base_sha: baseSha } : { selected: count }), log, log_hash: snapshotFile(log), artifacts: files });
  if (rc) throw new Error(`${key} failed (${rc})${isMut && count && rc === 1 ? ' — surviving mutants, see log' : ''}; log: ${log}`);
  if (key === 'sonar') fs.rmSync(evidencePath('sonar-skip'), { force: true });
  console.log(`✓ ${key}: ${log}`);
}
try { main(); } catch (error) { console.error(`quality: ${error.message}`); process.exitCode = 1; }
