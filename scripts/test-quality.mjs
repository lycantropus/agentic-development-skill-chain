#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
const root = process.cwd(), temp = fs.mkdtempSync(path.join(os.tmpdir(), 'quality-'));
try {
  for (const platform of ['codex', 'claude']) {
    const cwd = path.join(temp, platform); fs.mkdirSync(cwd);
    const base = 'specs/PROJ-1-test', progress = `${base}/5_progress`;
    const write = (name, value) => fs.writeFileSync(path.join(cwd, name), value);
    const git = (...args) => execFileSync('git', args, { cwd, stdio: 'pipe' });
    const chain = path.join(root, platform, 'skills/5_executing/scripts/chain');
    const call = (...args) => spawnSync('bash', [chain, 'quality', '1', 'test', ...args], { cwd, encoding: 'utf8' });
    const ok = (...args) => { const r = call(...args); assert.equal(r.status, 0, r.stderr); return r.stdout; };
    const bad = (...args) => { const r = call(...args); assert.notEqual(r.status, 0, r.stdout); return r.stderr; };
    fs.mkdirSync(path.join(cwd, `${base}/3-4_plan`), { recursive: true });
    fs.mkdirSync(path.join(cwd, progress), { recursive: true });
    const progressPath = path.join(cwd, progress, 'PROJ-1-progress.md'), progressText = () => fs.readFileSync(progressPath, 'utf8');
    write(`${progress}/PROJ-1-progress.md`, '# PROJ-1 Progress\n\n## US-1: story\n');
    const seal = () => spawnSync('bash', [chain, 'quality', 'seal', '1', 'test'], { cwd, encoding: 'utf8' });
    write('.gitignore', 'out/\ncoverage/\n.scannerwork/\n.env.local\nnode_modules/\n');
    write('source.txt', 'one');
    const config = {
      build_cmd: `mkdir -p out; echo build >> ${progress}/counter.log; echo output > out/build`, build_artifacts: ['out'],
      coverage_cmd: 'mkdir -p coverage; echo lcov > coverage/lcov.info; echo "Tests  2 passed (2)"', coverage_artifacts: ['coverage/lcov.info'],
      sonar_cmd: 'mkdir -p .scannerwork; echo ceTaskId=123 > .scannerwork/report-task.txt',
      lint_cmd: 'true', phase_commands: [{ label: 'integration', phase: 'quality', command: 'echo "# tests 3"' }]
    };
    const saveConfig = () => write(`${base}/3-4_plan/wave-gate-config.json`, JSON.stringify(config)); saveConfig();
    git('init', '-q'); git('config', 'user.name', 'test'); git('config', 'user.email', 'test@example.invalid');
    const commit = () => { git('add', '.'); git('commit', '-qm', 'fixture'); }; commit();
    bad('check'); ok('run', 'build'); assert.match(ok('run', 'build'), /reused/);
    assert.equal(fs.readFileSync(path.join(cwd, `${progress}/counter.log`), 'utf8'), 'build\n');
    write('out/build', 'tampered'); assert.doesNotMatch(ok('run', 'build'), /reused/);
    fs.rmSync(path.join(cwd, 'out'), { recursive: true }); assert.doesNotMatch(ok('run', 'build'), /reused/);
    write('.env.local', 'SETTING=new'); assert.doesNotMatch(ok('run', 'build'), /reused/);
    bad('run', 'sonar'); // coverage must finish first
    ok('run', 'coverage'); assert.match(ok('run', 'coverage'), /reused/);
    ok('run', 'sonar'); ok('run', 'lint'); ok('run', 'test:integration');
    write(`${progress}/review.md`, 'Reviewed integration; no P0/P1 findings.'); ok('review', `${progress}/review.md`);
    ok('check');
    const block = () => progressText().match(/<!-- quality-status:[\s\S]*?<!-- \/quality-status -->/)?.[0];
    for (const row of ['Code Review | passed', 'Mutation | skipped (not configured)', 'Build | passed', 'Tests | passed', 'Lint | passed', 'SonarCloud | ran']) assert.match(block(), new RegExp(`\\| ${row.replace(/[()|]/g, '\\$&')} \\|`));
    assert.match(progressText(), /^## Quality Gate — PROJ-1$/m); assert.ok(progressText().startsWith('# PROJ-1 Progress\n\n## US-1: story\n'));
    const buildProof = JSON.parse(fs.readFileSync(path.join(cwd, `${progress}/quality-build.json`), 'utf8'));
    const savedLog = fs.readFileSync(path.join(cwd, buildProof.log));
    write(buildProof.log, 'tampered log'); bad('check'); write(buildProof.log, savedLog); ok('check');
    const proof = seal;
    // This fixture's .env.local is not sourced for direct helper calls.
    const sourceEnv = process.env.SETTING; process.env.SETTING = 'new';
    assert.notEqual(proof().status, 0, 'environment change must invalidate a rendered green block');
    if (sourceEnv === undefined) delete process.env.SETTING; else process.env.SETTING = sourceEnv;
    fs.rmSync(path.join(cwd, '.env.local')); // re-verify all commands with one environment
    ok('run', 'build'); ok('run', 'coverage'); ok('run', 'sonar'); ok('run', 'lint'); ok('run', 'test:integration'); ok('review', `${progress}/review.md`);
    assert.equal(proof().status, 0, proof().stderr);
    commit(); ok('check'); // committing operational evidence preserves code proof
    write('source.txt', 'two'); bad('check'); assert.notEqual(proof().status, 0, 'stale evidence must fail the seal'); bad('run', 'build'); commit(); bad('check');
    assert.doesNotMatch(ok('run', 'build'), /reused/);
    config.phase_commands[0].command = 'echo no-tests'; saveConfig(); commit(); bad('run', 'test:integration');
    config.coverage_cmd = 'exit 7'; saveConfig(); commit(); bad('run', 'coverage'); bad('run', 'sonar');
    config.coverage_cmd = 'mkdir -p coverage; echo lcov > coverage/lcov.info; echo "# tests 2"';
    config.sonar_cmd = 'true'; saveConfig(); commit(); ok('run', 'coverage'); bad('run', 'sonar');
    fs.mkdirSync(path.join(cwd, 'scripts'));
    fs.copyFileSync(path.join(root, platform, 'skills/5_executing/scripts/worktree.sh'), path.join(cwd, 'scripts/worktree.sh'));
    config.auth_budget = { preflight_cmd: 'true' };
    config.phase_commands = [{ label: 'auth', phase: 'quality', auth_consuming: true, command: `test -e /proc/$$/fd/8 && echo called >> ${progress}/auth-calls.log && echo "# tests 1"` }];
    saveConfig(); commit(); ok('run', 'test:auth');
    config.auth_budget.preflight_cmd = 'exit 75'; saveConfig(); commit(); bad('run', 'test:auth');
    assert.equal(fs.readFileSync(path.join(cwd, `${progress}/auth-calls.log`), 'utf8'), 'called\n');
    config.build_cmd = 'exit 8'; saveConfig(); commit(); bad('run', 'build');
    const failedBuild = JSON.parse(fs.readFileSync(path.join(cwd, `${progress}/quality-build.json`), 'utf8')); assert.equal(failedBuild.rc, 8);

    // Mutation hardening: positive control, env handoff, survivors, proof status agreement, staleness.
    delete config.build_artifacts; delete config.coverage_artifacts; delete config.coverage_cmd; delete config.auth_budget;
    Object.assign(config, { build_cmd: 'true', sonar_cmd: 'mkdir -p .scannerwork; echo ceTaskId=9 > .scannerwork/report-task.txt', phase_commands: [] });
    git('tag', 'proj-PROJ-1-base', execFileSync('git', ['rev-list', '--max-parents=0', 'HEAD'], { cwd, encoding: 'utf8' }).trim());
    saveConfig(); commit();
    assert.match(bad('run', 'mutation'), /missing command for mutation/);
    config.mutation_cmd = 'echo analysed everything'; saveConfig(); commit();
    bad('run', 'mutation'); bad('check'); // exit 0 without a mutant count is a silent no-op
    config.mutation_cmd = 'echo "base=$BASE_SHA"; echo "files:$CHANGED_FILES"; echo "Mutants: 5"'; saveConfig(); commit();
    ok('run', 'mutation');
    const mutationRecord = () => JSON.parse(fs.readFileSync(path.join(cwd, `${progress}/quality-mutation.json`), 'utf8'));
    assert.equal(mutationRecord().mutants, 5); assert.equal(mutationRecord().selected, undefined);
    const mutationLog = fs.readFileSync(path.join(cwd, mutationRecord().log), 'utf8');
    assert.match(mutationLog, /base=[0-9a-f]{40}/); assert.match(mutationLog, /source\.txt/);
    ok('run', 'build'); ok('run', 'lint'); ok('run', 'sonar'); ok('review', `${progress}/review.md`); ok('check');
    const edited = (from, to) => { const text = progressText(); assert.ok(text.includes(from), from); write(`${progress}/PROJ-1-progress.md`, text.replace(from, to)); return text; };
    const restore = text => write(`${progress}/PROJ-1-progress.md`, text);
    ok('check'); assert.match(block(), /\| Mutation \| ran \|/); assert.equal(seal().status, 0, seal().stderr);
    const rendered = progressText();
    edited('| Mutation | ran |', '| Mutation | skipped (not configured) |'); assert.match(seal().stderr, /missing or edited/); restore(rendered);
    edited('| Mutation | ran |', '| Mutation | pending |'); assert.notEqual(seal().status, 0); restore(rendered);
    edited('| Mutation | ran |', '| Mutation | ran (survivors carried forward) |'); assert.match(seal().stderr, /missing or edited/); restore(rendered);
    write(`${progress}/PROJ-1-progress.md`, rendered.replace(block(), '')); assert.notEqual(seal().status, 0, 'a deleted block must fail'); restore(rendered);
    assert.equal(seal().status, 0, seal().stderr);
    // Only exit 1 means survivors; a crash or timeout with a printed count is a failed run.
    config.mutation_cmd = 'echo "Mutants: 5"; exit 2'; saveConfig(); commit();
    bad('run', 'mutation'); bad('check');
    // The recorded base tag is part of the evidence: moving it makes the scope differ.
    config.mutation_cmd = 'echo "Mutants: 5"'; saveConfig(); commit(); ok('run', 'mutation');
    ok('run', 'build'); ok('run', 'lint'); ok('run', 'sonar'); ok('review', `${progress}/review.md`); ok('check');
    const baseTag = execFileSync('git', ['rev-parse', 'proj-PROJ-1-base'], { cwd, encoding: 'utf8' }).trim();
    git('tag', '-f', 'proj-PROJ-1-base', 'HEAD'); assert.match(bad('check'), /base tag moved/);
    git('tag', '-f', 'proj-PROJ-1-base', baseTag); ok('check');
    // Survivors: non-zero exit with mutants analysed is evidence, not a silent no-op; the status must say so.
    config.mutation_cmd = 'echo "2 mutants survived"; echo "Mutants: 5"; exit 1'; saveConfig(); commit();
    assert.match(bad('run', 'mutation'), /surviving mutants/); assert.equal(mutationRecord().rc, 1);
    ok('run', 'build'); ok('run', 'lint'); ok('run', 'sonar'); ok('review', `${progress}/review.md`); ok('check');
    assert.match(block(), /\| Mutation \| ran \(survivors carried forward\) \|/); assert.equal(seal().status, 0, seal().stderr);
    const survivors = progressText();
    edited('| Mutation | ran (survivors carried forward) |', '| Mutation | ran |'); assert.match(seal().stderr, /missing or edited/); restore(survivors);
    // A later commit (e.g. a Sonar fix) makes mutation evidence stale until it is rerun.
    write('source.txt', 'three'); commit(); bad('check'); assert.notEqual(seal().status, 0);
    // Unconfigured: the block says skipped; claiming a run does not pass.
    delete config.mutation_cmd; saveConfig(); commit();
    ok('run', 'build'); ok('run', 'lint'); ok('run', 'sonar'); ok('review', `${progress}/review.md`); ok('check');
    assert.match(block(), /\| Mutation \| skipped \(not configured\) \|/); assert.equal(seal().status, 0, seal().stderr);
    const unconfigured = progressText();
    edited('| Mutation | skipped (not configured) |', '| Mutation | ran |'); assert.notEqual(seal().status, 0); restore(unconfigured);

    // The seal runs in a plain environment but the commands ran with .env.local sourced: the seal loads it the same way.
    write('.env.local', '# comment\nA_KEY="quoted value"\nB_KEY=\'single\'\nBARE\n');
    const sourced = (...args) => { const r = spawnSync('bash', ['-c', 'source "$1"; shift; exec "$@"', '_', path.join(root, platform, 'skills/5_executing/scripts/env-local.sh'), 'bash', chain, 'quality', '1', 'test', ...args], { cwd, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); };
    sourced('run', 'build'); sourced('run', 'lint'); sourced('run', 'sonar'); sourced('review', `${progress}/review.md`); sourced('check');
    bad('check'); // a plain environment is a different environment ...
    assert.equal(seal().status, 0, seal().stderr); // ... which the seal reproduces from .env.local
    fs.rmSync(path.join(cwd, '.env.local'));
    ok('run', 'build'); ok('run', 'lint'); ok('run', 'sonar'); ok('review', `${progress}/review.md`);

    // Seal exits: 64 on usage, 1 without a progress file; check keeps existing progress prose and rewrites only its own block.
    assert.equal(spawnSync('bash', [chain, 'quality', 'seal'], { cwd, encoding: 'utf8' }).status, 64);
    ok('check'); const settled = progressText(); ok('check'); assert.equal(progressText(), settled, 'rendering twice changes nothing');
    fs.renameSync(progressPath, `${progressPath}.off`); const noProgress = seal(); assert.equal(noProgress.status, 1); assert.match(noProgress.stderr, /progress file missing/);
    ok('check'); assert.ok(!fs.existsSync(progressPath), 'a missing progress file is never created'); fs.renameSync(`${progressPath}.off`, progressPath);
    write(`${progress}/PROJ-1-progress.md`, `# P\n\n## Quality Gate — PROJ-1\n\n### Code Review\nSpec: 0 findings\n\n## Variant Notes\n- note\n`); ok('check');
    assert.match(progressText(), /## Quality Gate — PROJ-1\n\n<!-- quality-status:[\s\S]*<!-- \/quality-status -->\n\n### Code Review\nSpec: 0 findings\n\n## Variant Notes\n- note\n/);
    assert.equal(seal().status, 0, seal().stderr);
  }
  console.log('quality evidence behavior tests (codex + claude): PASS');
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
