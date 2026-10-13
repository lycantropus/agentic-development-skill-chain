#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
const root = process.cwd(), temp = fs.mkdtempSync(path.join(os.tmpdir(), 'quality-evidence-'));
try {
  for (const platform of ['codex', 'claude']) {
    const cwd = path.join(temp, platform); fs.mkdirSync(cwd);
    const base = 'specs/PROJ-1-test', progress = `${base}/5_progress`;
    const write = (name, value) => fs.writeFileSync(path.join(cwd, name), value);
    const git = (...args) => execFileSync('git', args, { cwd, stdio: 'pipe' });
    const helper = path.join(root, platform, 'skills/5_executing/scripts/quality-evidence.mjs');
    const call = (...args) => spawnSync('node', [helper, '1', 'test', ...args], { cwd, encoding: 'utf8' });
    const ok = (...args) => { const r = call(...args); assert.equal(r.status, 0, r.stderr); return r.stdout; };
    const bad = (...args) => { const r = call(...args); assert.notEqual(r.status, 0, r.stdout); return r.stderr; };
    fs.mkdirSync(path.join(cwd, `${base}/3-4_plan`), { recursive: true });
    fs.mkdirSync(path.join(cwd, progress), { recursive: true });
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
    const buildProof = JSON.parse(fs.readFileSync(path.join(cwd, `${progress}/quality-build.json`), 'utf8'));
    const savedLog = fs.readFileSync(path.join(cwd, buildProof.log));
    write(buildProof.log, 'tampered log'); bad('check'); write(buildProof.log, savedLog); ok('check');
    const statuses = ['Code Review', 'Build', 'Tests', 'Lint'].map(name => `### ${name}\nStatus: passed\n`).join('');
    write(`${progress}/PROJ-1-progress.md`, `## Quality Gate — PROJ-1\n${statuses}### SonarCloud\nStatus: ran\n`);
    const proof = () => spawnSync('bash', [path.join(root, platform, 'skills/5_executing/scripts/quality-gate-proof.sh'), '1', 'test'], { cwd, encoding: 'utf8' });
    // This fixture's .env.local is not sourced for direct helper calls.
    const sourceEnv = process.env.SETTING; process.env.SETTING = 'new';
    assert.notEqual(proof().status, 0, 'environment change must invalidate apparently green statuses');
    if (sourceEnv === undefined) delete process.env.SETTING; else process.env.SETTING = sourceEnv;
    fs.rmSync(path.join(cwd, '.env.local')); // re-verify all commands with one environment
    ok('run', 'build'); ok('run', 'coverage'); ok('run', 'sonar'); ok('run', 'lint'); ok('run', 'test:integration'); ok('review', `${progress}/review.md`);
    assert.equal(proof().status, 0, proof().stderr);
    commit(); ok('check'); // committing operational evidence preserves code proof
    write('source.txt', 'two'); bad('check'); assert.notEqual(proof().status, 0, 'stale green markdown must fail'); bad('run', 'build'); commit(); bad('check');
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
    const statuses2 = ['Code Review', 'Build', 'Tests', 'Lint'].map(name => `### ${name}\nStatus: passed\n`).join('');
    const progressFile = mutation => write(`${progress}/PROJ-1-progress.md`, `## Quality Gate — PROJ-1\n${statuses2}### SonarCloud\nStatus: ran\n${mutation ? `### Mutation\nStatus: ${mutation}\n` : ''}`);
    const proofCall = () => spawnSync('bash', [path.join(root, platform, 'skills/5_executing/scripts/quality-gate-proof.sh'), '1', 'test'], { cwd, encoding: 'utf8' });
    progressFile('ran'); assert.equal(proofCall().status, 0, proofCall().stderr);
    progressFile('skipped (not configured)'); assert.match(proofCall().stderr, /needs Status: ran/);
    progressFile('pending'); assert.notEqual(proofCall().status, 0);
    progressFile(null); assert.notEqual(proofCall().status, 0, 'configured mutation needs a Mutation block');
    progressFile('ran (survivors carried forward)'); assert.match(proofCall().stderr, /shows none/);
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
    progressFile('ran'); assert.match(proofCall().stderr, /surviving mutants/);
    progressFile('ran (survivors carried forward)'); assert.equal(proofCall().status, 0, proofCall().stderr);
    // A later commit (e.g. a Sonar fix) makes mutation evidence stale until it is rerun.
    write('source.txt', 'three'); commit(); bad('check'); assert.notEqual(proofCall().status, 0);
    // Unconfigured: an absent block or an explicit skip passes; claiming a run does not.
    delete config.mutation_cmd; saveConfig(); commit();
    ok('run', 'build'); ok('run', 'lint'); ok('run', 'sonar'); ok('review', `${progress}/review.md`);
    progressFile(null); assert.equal(proofCall().status, 0, proofCall().stderr);
    progressFile('skipped (not configured)'); assert.equal(proofCall().status, 0, proofCall().stderr);
    progressFile('ran'); assert.notEqual(proofCall().status, 0);
  }
  console.log('quality evidence behavior tests (codex + claude): PASS');
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
