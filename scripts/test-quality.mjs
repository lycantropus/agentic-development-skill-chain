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
    let qualityEnv = process.env;
    const call = (...args) => spawnSync('bash', [chain, 'quality', '1', 'test', ...args], { cwd, encoding: 'utf8', env: qualityEnv });
    const ok = (...args) => { const r = call(...args); assert.equal(r.status, 0, r.stderr); return r.stdout; };
    const bad = (...args) => { const r = call(...args); assert.notEqual(r.status, 0, r.stdout); return r.stderr; };
    fs.mkdirSync(path.join(cwd, `${base}/3-4_plan`), { recursive: true });
    fs.mkdirSync(path.join(cwd, progress), { recursive: true });
    const progressPath = path.join(cwd, progress, 'PROJ-1-progress.md'), progressText = () => fs.readFileSync(progressPath, 'utf8');
    write(`${progress}/PROJ-1-progress.md`, '# PROJ-1 Progress\n\n## US-1: story\n');
    const seal = () => spawnSync('bash', [chain, 'quality', 'seal', '1', 'test'], { cwd, encoding: 'utf8', env: qualityEnv });
    // Real `sonar list issues` output (shortened): [0] MINOR/OPEN [1] MAJOR/OPEN [2] CRITICAL/OPEN [3] BLOCKER/OPEN (no line) [4] CRITICAL/CLOSED [5] MAJOR/RESOLVED.
    // issuesFile(moved) points the listed issues at the changed file source.txt; the rest stay in files this PROJ did not touch.
    const fixture = JSON.parse(fs.readFileSync(path.join(root, 'scripts/fixtures/sonar/list-issues.json'), 'utf8'));
    const issuesFile = (moved = [], edit = data => data, name = 'issues.json') => {
      const data = structuredClone(fixture);
      data.issues.forEach((issue, i) => { if (moved.includes(i)) issue.component = `${issue.project}:source.txt`; });
      write(`${progress}/${name}`, JSON.stringify(edit(data))); return `${progress}/${name}`;
    };
    const scan = (moved = []) => { ok('run', 'sonar'); ok('sonar-issues', issuesFile(moved)); };
    write('.gitignore', 'out/\ncoverage/\n.scannerwork/\n.env.local\nnode_modules/\n');
    write('source.txt', 'one');
    const config = {
      build_cmd: `mkdir -p out; echo build >> ${progress}/counter.log; echo output > out/build`, build_artifacts: ['out'],
      coverage_cmd: 'mkdir -p coverage; echo lcov > coverage/lcov.info; echo "Tests  2 passed (2)"', coverage_artifacts: ['coverage/lcov.info'],
      sonar_cmd: 'mkdir -p .scannerwork; echo ceTaskId=$(date +%s%N) > .scannerwork/report-task.txt',
      lint_cmd: 'true', phase_commands: [{ label: 'integration', phase: 'quality', command: 'echo "# tests 3"' }]
    };
    const saveConfig = () => write(`${base}/3-4_plan/wave-gate-config.json`, JSON.stringify(config)); saveConfig();
    git('init', '-q'); git('config', 'user.name', 'test'); git('config', 'user.email', 'test@example.invalid');
    const commit = () => { git('add', '.'); git('commit', '-qm', 'fixture'); }; commit();
    git('tag', 'proj-PROJ-1-base', execFileSync('git', ['rev-list', '--max-parents=0', 'HEAD'], { cwd, encoding: 'utf8' }).trim());
    bad('check'); ok('run', 'build'); assert.match(ok('run', 'build'), /reused/);
    assert.equal(fs.readFileSync(path.join(cwd, `${progress}/counter.log`), 'utf8'), 'build\n');
    write('out/build', 'tampered'); assert.doesNotMatch(ok('run', 'build'), /reused/);
    fs.rmSync(path.join(cwd, 'out'), { recursive: true }); assert.doesNotMatch(ok('run', 'build'), /reused/);
    write('.env.local', 'SETTING=new'); assert.doesNotMatch(ok('run', 'build'), /reused/);
    bad('run', 'sonar'); // coverage must finish first
    ok('run', 'coverage'); assert.match(ok('run', 'coverage'), /reused/);
    scan(); ok('run', 'lint'); ok('run', 'test:integration');
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
    ok('run', 'build'); ok('run', 'coverage'); scan(); ok('run', 'lint'); ok('run', 'test:integration'); ok('review', `${progress}/review.md`);
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
    Object.assign(config, { build_cmd: 'true', sonar_cmd: 'mkdir -p .scannerwork; echo ceTaskId=$(date +%s%N) > .scannerwork/report-task.txt', phase_commands: [] });
    saveConfig(); commit();
    assert.match(bad('run', 'mutation'), /missing command for mutation/);
    config.mutation_cmd = 'echo analysed everything'; saveConfig(); commit();
    bad('run', 'mutation'); bad('check'); // exit 0 without a mutant count is a silent no-op
    config.mutation_cmd = `echo "base=$BASE_SHA"; while IFS= read -r -d '' file; do printf 'file:%s\\n' "$file"; done < "$CHANGED_FILES_FILE"; echo "Mutants: 5"`; saveConfig(); commit();
    ok('run', 'mutation');
    const mutationRecord = () => JSON.parse(fs.readFileSync(path.join(cwd, `${progress}/quality-mutation.json`), 'utf8'));
    assert.equal(mutationRecord().mutants, 5); assert.equal(mutationRecord().selected, undefined);
    const mutationLog = fs.readFileSync(path.join(cwd, mutationRecord().log), 'utf8');
    assert.match(mutationLog, /base=[0-9a-f]{40}/); assert.match(mutationLog, /source\.txt/);
    ok('run', 'build'); ok('run', 'lint'); scan(); ok('review', `${progress}/review.md`); ok('check');
    const edited = (from, to) => { const text = progressText(); assert.ok(text.includes(from), from); write(`${progress}/PROJ-1-progress.md`, text.replace(from, to)); return text; };
    const restore = text => write(`${progress}/PROJ-1-progress.md`, text);
    ok('check'); assert.match(block(), /\| Mutation \| ran \|/); assert.equal(seal().status, 0, seal().stderr);
    const rendered = progressText();
    edited('| Mutation | ran |', '| Mutation | skipped (not configured) |'); assert.match(seal().stderr, /or edited/); restore(rendered);
    edited('| Mutation | ran |', '| Mutation | pending |'); assert.notEqual(seal().status, 0); restore(rendered);
    edited('| Mutation | ran |', '| Mutation | ran (3 survivors carried forward) |'); assert.match(seal().stderr, /or edited/); restore(rendered);
    write(`${progress}/PROJ-1-progress.md`, rendered.replace(block(), '')); assert.notEqual(seal().status, 0, 'a deleted block must fail'); restore(rendered);
    // The block counts only once and only inside the Quality Gate section.
    const bare = rendered.replace(block(), ''), heading = '## Quality Gate — PROJ-1';
    restore(`${block()}\n\n${bare}`); assert.match(seal().stderr, /outside the section/, 'block before the section'); restore(rendered);
    restore(`${bare}\n## Variant Notes\n${block()}\n`); assert.notEqual(seal().status, 0, 'block in a later section'); restore(rendered);
    restore(rendered.replace(block(), `${block()}\n\n${block()}`)); assert.match(seal().stderr, /duplicated/); restore(rendered);
    restore(rendered.replace(heading, '## Quality Results')); assert.match(seal().stderr, /section missing/); restore(rendered);
    // A refresh pulls a stray copy back into the section and drops duplicates.
    restore(`${block()}\n\n${rendered.replace(block(), `${block()}\n\n${block()}`)}`); ok('check');
    assert.equal(progressText().match(/<!-- quality-status:/g).length, 1); assert.equal(seal().status, 0, seal().stderr);
    restore(rendered);
    assert.equal(seal().status, 0, seal().stderr);
    // Only exit 1 means survivors; a crash or timeout with a printed count is a failed run.
    config.mutation_cmd = 'echo "Mutants: 5"; exit 2'; saveConfig(); commit();
    bad('run', 'mutation'); bad('check');
    // The recorded base tag is part of the evidence: moving it makes the scope differ.
    config.mutation_cmd = 'echo "Mutants: 5"'; saveConfig(); commit(); ok('run', 'mutation');
    ok('run', 'build'); ok('run', 'lint'); scan(); ok('review', `${progress}/review.md`); ok('check');
    const baseTag = execFileSync('git', ['rev-parse', 'proj-PROJ-1-base'], { cwd, encoding: 'utf8' }).trim();
    git('tag', '-f', 'proj-PROJ-1-base', 'HEAD'); assert.match(bad('check'), /base tag moved/);
    git('tag', '-f', 'proj-PROJ-1-base', baseTag); ok('check');
    // Survivors: exit 1 needs a printed "Survivors: N" with N > 0; the status says so and the progress notes must carry a bullet.
    const rerun = () => { ok('run', 'build'); ok('run', 'lint'); scan(); ok('review', `${progress}/review.md`); };
    config.mutation_cmd = 'echo "2 mutants survived"; echo "Mutants: 5"; exit 1'; saveConfig(); commit();
    assert.match(bad('run', 'mutation'), /without a "Survivors: N" line/); assert.equal(mutationRecord().rc, 1); rerun(); bad('check');
    config.mutation_cmd = 'echo "Mutants: 5"; echo "Survivors: 0"; exit 1'; saveConfig(); commit();
    bad('run', 'mutation'); rerun(); bad('check');
    config.mutation_cmd = 'echo "Mutants: 5"; echo "Survivors: 2"; exit 1'; saveConfig(); commit();
    assert.match(bad('run', 'mutation'), /surviving mutants/); assert.equal(mutationRecord().rc, 1); assert.equal(mutationRecord().survivors, 2);
    rerun(); ok('check');
    assert.match(block(), /\| Mutation \| ran \(2 survivors carried forward\) \|/);
    const section = '### Carried Forward (Mutation, 3 tests-only rounds exhausted)';
    assert.match(seal().stderr, /Carried Forward \(Mutation/, 'no section');
    const unnoted = progressText();
    restore(`${unnoted}\n${section}\n\nprose without a bullet\n`); assert.match(seal().stderr, /Carried Forward \(Mutation/, 'section without a bullet');
    restore(`${unnoted}\n- bullet outside the section\n\n${section}\n\n## Next\n- bullet after the section\n`); assert.notEqual(seal().status, 0, 'a bullet after the next heading does not count');
    restore(`${unnoted}\n${section}\n\n- source.txt: 2 mutants survived, see the mutation log\n`); assert.equal(seal().status, 0, seal().stderr);
    const survivors = progressText();
    edited('| Mutation | ran (2 survivors carried forward) |', '| Mutation | ran |'); assert.match(seal().stderr, /or edited/); restore(survivors);
    // A later commit (e.g. a Sonar fix) makes mutation evidence stale until it is rerun.
    write('source.txt', 'three'); commit(); bad('check'); assert.notEqual(seal().status, 0);
    // Unconfigured: the block says skipped; claiming a run does not pass.
    delete config.mutation_cmd; saveConfig(); commit();
    ok('run', 'build'); ok('run', 'lint'); scan(); ok('review', `${progress}/review.md`); ok('check');
    assert.match(block(), /\| Mutation \| skipped \(not configured\) \|/); assert.equal(seal().status, 0, seal().stderr);
    const unconfigured = progressText();
    edited('| Mutation | skipped (not configured) |', '| Mutation | ran |'); assert.notEqual(seal().status, 0); restore(unconfigured);

    // Sonar issues: the saved `sonar list issues` output is bound to the current scan; carrying issues forward needs the history and the notes.
    const issuesPath = path.join(cwd, `${progress}/quality-sonar-issues.json`), roundsPath = path.join(cwd, `${progress}/quality-sonar-rounds.json`);
    const scans = () => JSON.parse(fs.readFileSync(roundsPath, 'utf8')).length;
    write('issues-outside.json', JSON.stringify(fixture)); commit(); ok('run', 'build'); ok('run', 'lint'); ok('review', `${progress}/review.md`);
    scan(); const before = scans(); ok('run', 'sonar'); assert.equal(scans(), before + 1, 'a successful scan is appended to the history');
    assert.match(bad('check'), /sonar-issues: recorded for a different scan/); assert.notEqual(seal().status, 0, 'a new scan without recorded issues must not seal');
    fs.rmSync(issuesPath); assert.match(bad('check'), /quality-sonar-issues/); assert.notEqual(seal().status, 0, 'no issues record');
    assert.match(bad('sonar-issues', `${progress}/missing.json`), /ENOENT/);
    assert.match(bad('sonar-issues', issuesFile([], data => { data.paging.total = 7; return data; })), /incomplete \(6 of 7\)/);
    assert.match(bad('sonar-issues', issuesFile([], () => ({ error: 'x' }))), /not the output of sonar list issues/);
    assert.match(bad('sonar-issues', 'issues-outside.json'), /usage: sonar-issues/);
    assert.match(bad('sonar-issues', `${progress}/../issues-outside.json`), /usage: sonar-issues/);
    assert.match(bad('sonar-issues', issuesFile([], data => { data.issues.push(data.issues[0]); data.paging.total += 1; return data; })), /duplicates/);
    // A symlink under 5_progress must not smuggle in a file (or a directory) from outside.
    fs.symlinkSync(path.join(cwd, 'issues-outside.json'), path.join(cwd, progress, 'link.json'));
    assert.match(bad('sonar-issues', `${progress}/link.json`), /symlink/);
    fs.symlinkSync(cwd, path.join(cwd, progress, 'linkdir')); assert.match(bad('sonar-issues', `${progress}/linkdir/issues-outside.json`), /symlink/);
    assert.ok(!fs.existsSync(issuesPath), 'a rejected file leaves no record');
    ok('sonar-issues', issuesFile()); ok('check'); assert.equal(seal().status, 0, seal().stderr); // none of the real issues is in a changed file
    // A list saved before the current scan is not evidence for it, even though the file itself is unchanged.
    const stale = issuesFile([], data => data, 'stale.json'); ok('run', 'sonar'); assert.match(bad('sonar-issues', stale), /older than the current scan/);
    ok('sonar-issues', issuesFile()); ok('check');
    // The recorded base tag is part of the issues evidence: moving it changes which files count as changed.
    const tagged = execFileSync('git', ['rev-parse', 'proj-PROJ-1-base'], { cwd, encoding: 'utf8' }).trim();
    git('tag', '-f', 'proj-PROJ-1-base', 'HEAD'); assert.match(bad('check'), /sonar-issues: base tag moved/);
    git('tag', '-f', 'proj-PROJ-1-base', tagged); ok('check');
    // Issues recorded for an earlier head: a code change plus a fresh scan does not carry the old list over.
    write('source.txt', 'four'); commit(); ok('run', 'build'); ok('run', 'lint'); ok('review', `${progress}/review.md`); ok('run', 'sonar');
    assert.match(bad('check'), /sonar-issues: stale or failed evidence/); assert.notEqual(seal().status, 0);
    ok('sonar-issues', issuesFile([0, 4, 5])); // MINOR, CLOSED and RESOLVED are not blocking: still zero carried
    assert.match(ok('check'), /✓/); assert.match(block(), /\| SonarCloud \| ran \|/); assert.equal(seal().status, 0, seal().stderr);
    // Paths with leading whitespace or characters git would quote still count as changed.
    const odd = ' größe "x".txt'; write(odd, 'x'); commit(); ok('run', 'build'); ok('run', 'lint'); ok('review', `${progress}/review.md`); ok('run', 'sonar');
    ok('sonar-issues', issuesFile([], data => { data.issues[1].component = `${data.issues[1].project}:${odd}`; return data; }));
    assert.deepEqual(JSON.parse(fs.readFileSync(issuesPath, 'utf8')).open.map(issue => issue.file), [odd]);
    // Open BLOCKER/CRITICAL/MAJOR in changed files: three of the six real issues.
    fs.rmSync(roundsPath); scan([0, 1, 2, 3, 4, 5]);
    const open = JSON.parse(fs.readFileSync(issuesPath, 'utf8')).open; assert.deepEqual(open.map(issue => issue.severity), ['MAJOR', 'CRITICAL', 'BLOCKER']);
    assert.equal(open[2].line, null); assert.ok(open.every(issue => issue.file === 'source.txt'));
    assert.match(block(), /\| SonarCloud \| ran \(3 carried forward\) \|/); ok('check');
    const carried = '### Carried Forward (Sonar, 3 fix rounds exhausted)';
    assert.match(seal().stderr, /3 issue\(s\) open but 1 scan\(s\) recorded/, 'one scan is not three fix rounds');
    ok('run', 'sonar'); ok('sonar-issues', issuesFile([0, 1, 2, 3, 4, 5])); ok('run', 'sonar'); ok('sonar-issues', issuesFile([0, 1, 2, 3, 4, 5]));
    assert.match(seal().stderr, /3 issue\(s\) open but 3 scan\(s\) recorded/, 'three scans are still short');
    ok('run', 'sonar'); ok('sonar-issues', issuesFile([0, 1, 2, 3, 4, 5])); assert.equal(scans(), 4);
    assert.match(seal().stderr, new RegExp(`missing from "### Carried Forward \\(Sonar": ${open.map(issue => issue.key).join(', ')}`));
    const plain = progressText(), notes = keys => `${plain}\n${carried}\n\n${keys.map(key => `- ${key}: note`).join('\n')}\n`;
    restore(notes(open.slice(0, 2).map(issue => issue.key))); assert.match(seal().stderr, new RegExp(`missing from .*: ${open[2].key}\\n$`), 'one key missing');
    restore(notes(open.map(issue => `${issue.key}X`))); assert.match(seal().stderr, /missing from/, 'a longer key is not the key');
    restore(notes(open.map(issue => `X${issue.key}`))); assert.match(seal().stderr, /missing from/, "a longer key ending in the key is not the key");
    restore(`${plain}\n## Notes\n${open.map(issue => `- ${issue.key}`).join('\n')}\n\n${carried}\n\n- nothing here\n`); assert.notEqual(seal().status, 0, 'keys outside the section do not count');
    restore(notes(open.map(issue => issue.key))); assert.equal(seal().status, 0, seal().stderr);
    // Zero open issues after a single scan seal without notes.
    restore(plain); fs.rmSync(roundsPath); scan(); ok('check'); assert.equal(scans(), 1); assert.match(block(), /\| SonarCloud \| ran \|/); assert.equal(seal().status, 0, seal().stderr);

    // The seal runs in a plain environment but the commands ran with .env.local sourced: the seal loads it the same way.
    write('.env.local', '# comment\nA_KEY="quoted value"\nB_KEY=\'single\'\nBARE\n');
    const sourced = (...args) => { const r = spawnSync('bash', ['-c', 'source "$1"; shift; exec "$@"', '_', path.join(root, platform, 'skills/5_executing/scripts/env-local.sh'), 'bash', chain, 'quality', '1', 'test', ...args], { cwd, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); };
    sourced('run', 'build'); sourced('run', 'lint'); sourced('run', 'sonar'); sourced('sonar-issues', issuesFile()); sourced('review', `${progress}/review.md`); sourced('check');
    bad('check'); // a plain environment is a different environment ...
    assert.equal(seal().status, 0, seal().stderr); // ... which the seal reproduces from .env.local
    fs.rmSync(path.join(cwd, '.env.local'));
    ok('run', 'build'); ok('run', 'lint'); scan(); ok('review', `${progress}/review.md`);

    // Sonar policy is checked independently of plan validation, including by the seal.
    qualityEnv = { ...process.env, PATH: '/usr/bin:/bin' };
    assert.notEqual(spawnSync('bash', ['-c', 'command -v sonar && command -v sonar-scanner'], { env: qualityEnv }).status, 0, 'fixture PATH must omit a Sonar CLI');
    ok('run', 'build'); ok('run', 'lint'); ok('review', `${progress}/review.md`);
    ok('skip-sonar', 'sonar CLI unavailable'); ok('check');
    assert.equal(seal().status, 0, seal().stderr);
    ok('skip-sonar', 'project not configured'); ok('check');
    assert.match(block(), /\| SonarCloud \| skipped \(project not configured\) \|/);
    assert.equal(seal().status, 0, seal().stderr);
    for (const policy of ['required', 'configured', 'false-configured', 'malformed']) {
      delete config.sonar_required;
      if (policy === 'required') config.sonar_required = true;
      if (policy === 'false-configured') config.sonar_required = false;
      if (policy === 'malformed') config.sonar_required = 'false';
      if (policy.includes('configured')) write('sonar-project.properties', 'sonar.projectKey=fixture\n');
      saveConfig(); commit();
      const expected = policy === 'malformed' ? /sonar_required/ : /Sonar skip/;
      assert.match(bad('skip-sonar', 'project not configured'), expected, `${policy} must reject a project-not-configured skip`);
      assert.match(bad('skip-sonar', 'sonar CLI unavailable'), expected, `${policy} must reject a CLI-unavailable skip`);
      // Bring the previously valid skip record to the current inputs, so seal must
      // reject the policy itself rather than merely rejecting stale evidence.
      if (policy === 'malformed') {
        assert.match(seal().stderr, expected);
        for (const invalid of [null, 1]) {
          config.sonar_required = invalid; saveConfig();
          assert.match(bad('skip-sonar', 'project not configured'), /sonar_required/);
          assert.match(seal().stderr, /sonar_required/);
        }
        continue;
      }
      ok('run', 'build'); ok('run', 'lint'); ok('review', `${progress}/review.md`);
      const recordPath = path.join(cwd, `${progress}/quality-sonar-skip.json`);
      const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
      record.head = git('rev-parse', 'HEAD').toString().trim();
      record.inputs = ok('snapshot').trim();
      for (const reason of ['project not configured', 'sonar CLI unavailable']) {
        record.reason = reason;
        fs.writeFileSync(recordPath, JSON.stringify(record));
        assert.match(seal().stderr, expected, `${policy}: ${reason} skip must not seal`);
      }
      if (policy.includes('configured')) fs.rmSync(path.join(cwd, 'sonar-project.properties'));
    }
    qualityEnv = process.env;
    delete config.sonar_required; saveConfig(); commit();
    ok('run', 'build'); ok('run', 'lint'); scan(); ok('review', `${progress}/review.md`);

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
