#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolveInputs } from '../codex/skills/handoff-refinement/scripts/resolve-inputs.mjs';
import { integrationStatus, sharedInputFingerprint } from '../codex/skills/handoff-refinement/scripts/integration-status.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'external-inputs-'));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const story = 'PROJ-1-PRD-1-US-1', ac = `${story}-AC-1`;
try {
  for (const provider of ['codex', 'claude']) {
    const repo = path.join(temp, provider, 'non sibling checkout');
    const base = path.join(repo, 'specs/PROJ-1-demo'), planDir = path.join(base, '3-4_plan');
    fs.mkdirSync(planDir, { recursive: true });
    const source = 'Arbitrary external document\nCriterion A1: The plan is validated.\n';
    const evidence = 'Accepted by product owner in team review.\nApproved answer: Validate before writing.\nCompatible service revision verified.\n';
    fs.writeFileSync(path.join(base, 'source.txt'), source);
    fs.writeFileSync(path.join(base, 'answers.txt'), evidence);
    const id = 'product@v1:source:A1';
    const manifest = {
      schemaVersion: 1, baseline: { id: 'product', version: 'v1' }, derivedFrom: 'product@v1',
      repository: 'ui', repositories: ['ui', 'service'],
      team: { status: 'accepted', revision: 'a'.repeat(40), source: 'answers', evidence: 'Accepted by product owner in team review.' },
      sources: [{ id: 'source', path: 'source.txt', sha256: sha(source) }, { id: 'answers', path: 'answers.txt', sha256: sha(evidence) }],
      requirements: [{ id, source: 'source', sourceId: 'A1', sourceRange: { startLine: 2, endLine: 2 }, text: 'Criterion A1: The plan is validated.', repositories: ['ui', 'service'] }],
      mappings: ['ui', 'service'].map(repository => ({ requirement: id, repository, story, ac })),
      engineering: [{ id: 'ENG-AC-1', text: 'Reject invalid metadata.', authority: 'Engineering validation policy', requirements: [id], repository: 'ui', story }],
      questions: [{ id: 'Q1', requirements: [id], owner: 'Product owner', evidence: 'Existing handler writes before validation.', alternatives: 'Validate first; reject invalid records.', blockingRepositories: ['ui'] }],
      responses: [{ question: 'Q1', baseline: 'product@v1', owner: 'Product owner', date: '2026-10-25', approved: true, answer: 'Approved answer: Validate before writing.', source: 'answers' }],
      dependencies: [{ repository: 'ui', requires: 'service', revision: 'b'.repeat(40), source: 'answers', evidence: 'Compatible service revision verified.' }],
      prototype: { kind: 'static', reference: 'source.txt', simulated: ['Persistence is simulated.'] }
    };
    const marker = path.join(base, 'external-handoff.json');
    const save = (m = manifest) => fs.writeFileSync(marker, JSON.stringify(m, null, 2));
    save();
    const skills = path.join(root, provider, 'skills');
    const chain = path.join(skills, '5_executing/scripts/chain');
    const run = (args, ok = true) => {
      const result = spawnSync('bash', [chain, ...args], { cwd: repo, encoding: 'utf8' });
      assert.equal(result.status === 0, ok, `${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
      return result;
    };
    let plan = fs.readFileSync(path.join(root, 'scripts/fixtures/wave-plan-validator/plan-valid.md'), 'utf8');
    plan = plan.replace('The plan is validated.', 'Criterion A1: The plan is validated.');
    plan = plan.replace('## PROJ-1-PRD-1-US-1:', '**PRDs involved:** PROJ-1-PRD-1\n\n## PROJ-1-PRD-1-US-1:').replace('### Task', '- [ ] ENG-AC-1: Reject invalid metadata.\n\n### Task').replace(`**Fulfills:** ${ac}`, `**Fulfills:** ${ac}, ENG-AC-1`).replace('**What to build:**', '- `ENG-AC-1`: `npm test -- tests/validator.test.ts`\n\n**What to build:**');
    const planPath = path.join(planDir, 'PROJ-1-wave-1-plan.md'); fs.writeFileSync(planPath, plan);
    const config = JSON.parse(fs.readFileSync(path.join(root, 'scripts/fixtures/wave-plan-validator/config-valid.json')));
    config.waves['1'].ac_commands.push({ ...config.waves['1'].ac_commands[0], id: 'ENG-AC-1' });
    fs.writeFileSync(path.join(planDir, 'wave-gate-config.json'), JSON.stringify(config));
    const arch = path.join(planDir, 'PROJ-1-architecture.md');
    fs.writeFileSync(arch, '# PROJ-1 Architecture\n\n## Overview\nValidate input.\n\n## PRDs Covered\n- PROJ-1-PRD-1\n\n## Cross-Cutting Tech Decisions\n### Decision 1: Validate first\n**Affects:** all\n**Summary:** Reject bad input.\n');
    run(['check', 'inputs', base]);
    run(['check', 'prds', path.join(base, '2_PRDs')]);
    run(['check', 'architecture', arch, base]);
    run(['check', 'plan', planDir]);
    run(['render', 'context', 'compile', '1', 'demo']);
    const worker = fs.readFileSync(path.join(base, 'context/workers/wave-1', `${story}.md`), 'utf8');
    for (const expected of [id, 'ENG-AC-1', 'Approved answer: Validate before writing.', 'Persistence is simulated.', 'b'.repeat(40)]) assert.ok(worker.includes(expected), expected);
    const reviewerContext = fs.readFileSync(path.join(base, 'context/roles/wave-1/reviewer.md'), 'utf8');
    for (const expected of [id, 'ENG-AC-1', 'Approved answer: Validate before writing.']) assert.ok(reviewerContext.includes(expected));
    assert.ok(run(['render', 'slice', planPath, story]).stdout.includes(id));
    run(['render', 'context', 'check', '1', 'demo']);
    const invalid = [
      m => m.mappings.pop(),
      m => m.mappings[0].ac = story + '-AC-',
      m => m.sources.push(null),
      m => m.repositories[0] = '../ui',
      m => m.prototype.simulated = [42],
      m => m.engineeringStories = null,
      m => m.mappings.push({ ...m.mappings[0] }),
      m => m.requirements.push({ ...m.requirements[0] }),
      m => m.sources[0].sha256 = 'f'.repeat(64),
      m => m.sources[0].path = 'missing',
      m => m.sources[0].path = '../escape',
      m => m.requirements[0].sourceId = 'not present',
      m => m.requirements[0].text = 'The plan is validated.',
      m => m.requirements[0].sourceRange = { startLine: 1, endLine: 1 },
      m => m.requirements[0].sourceRange.endLine = 99,
      m => m.responses[0].approved = false,
      m => m.responses[0].baseline = 'product@v0',
      m => m.responses[0].answer = 'Invented answer',
      m => m.responses.push({ ...m.responses[0] }),
      m => m.team.status = 'proposed',
      m => m.baseline.version = 'v2',
      m => m.derivedFrom = 'product@v0',
      m => m.prototype.kind = 'runnable',
    ];
    for (const mutate of invalid) {
      const m = structuredClone(manifest); mutate(m); save(m);
      run(['check', 'inputs', base], false);
      const gate = run(['gate', 'wave', '1', '1', 'demo'], false);
      assert.match(gate.stderr + gate.stdout, /external.handoff|external inputs/i);
      run(['render', 'slice', planPath, story], false);
      run(['render', 'context', 'compile', '1', 'demo'], false);
    }
    const wrongIdentitySource = source.replace('A1:', 'A10:');
    fs.writeFileSync(path.join(base, 'source.txt'), wrongIdentitySource);
    const wrongIdentity = structuredClone(manifest);
    wrongIdentity.sources[0].sha256 = sha(wrongIdentitySource);
    wrongIdentity.requirements[0].text = 'Criterion A10: The plan is validated.';
    save(wrongIdentity);
    assert.throws(() => resolveInputs(base), /criterion identity/);
    fs.writeFileSync(path.join(base, 'source.txt'), source);
    const blocked = structuredClone(manifest); blocked.responses = []; save(blocked);
    assert.deepEqual(JSON.parse(run(['check', 'inputs', base, '--allow-blocked']).stdout).blockers, ['Q1']);
    assert.equal(resolveInputs(base, { allowBlocked: true }).questions[0].id, 'Q1');
    save();
    fs.writeFileSync(planPath, plan.replace('The plan is validated.', 'A different product behavior.'));
    run(['check', 'plan', planDir], false);
    run(['render', 'context', 'compile', '1', 'demo'], false);
    fs.writeFileSync(planPath, plan.replace('- [ ] ENG-AC-1: Reject invalid metadata.\n\n', ''));
    run(['check', 'plan', planDir], false);
    run(['render', 'context', 'compile', '1', 'demo'], false);
    fs.writeFileSync(planPath, plan);
    const proposal = structuredClone(manifest); proposal.questions[0].blockingRepositories = []; proposal.responses[0].approved = false; save(proposal);
    assert.ok(!run(['render', 'slice', planPath, story]).stdout.includes('Approved answer: Validate before writing.'));
    const single = structuredClone(manifest); single.repositories = ['ui']; single.requirements[0].repositories = ['ui']; single.mappings = [single.mappings[0]]; single.dependencies = [];
    single.prototype = { kind: 'runnable', revision: 'c'.repeat(40), reference: 'Pinned runnable bundle', simulated: [] }; save(single);
    run(['check', 'inputs', base]); run(['check', 'plan', planDir]);
    const independent = structuredClone(manifest); independent.engineering[0].requirements = []; save(independent);
    run(['check', 'inputs', base]); run(['check', 'plan', planDir]);
    const service = structuredClone(manifest); service.repository = 'service'; save(service);
    assert.equal(resolveInputs(base).acs.length, 1);
    assert.deepEqual(resolveInputs(base).blockers, []);
    save();
    // Optional technical stories are independent of product story mappings.
    const technicalId = 'PROJ-1-ENG-US-1';
    const technical = structuredClone(manifest);
    technical.engineeringStories = [{ id: technicalId, repository: 'ui', rationale: 'Validation is a shared prerequisite.', authority: 'Engineering owner' }];
    technical.engineering[0].story = technicalId;
    const originalArch = fs.readFileSync(arch, 'utf8');
    const technicalArch = originalArch + `\n## Engineering Stories Covered\n- ${technicalId}\n\n`;
    const mixedArch = technicalArch.replace('## Engineering Stories Covered', '### Decision 2: Technical validation boundary\n**Affects:** ENG-US-1\n**Summary:** TECHNICAL_BOUNDARY stays visible in technical waves.\n\n## Engineering Stories Covered');
    const productPlan = fs.readFileSync(path.join(root, 'scripts/fixtures/wave-plan-validator/plan-valid.md'), 'utf8').replace('The plan is validated.', manifest.requirements[0].text).replace('## PROJ-1-PRD-1-US-1:', '**PRDs involved:** PROJ-1-PRD-1\n\n## PROJ-1-PRD-1-US-1:');
    const technicalPlan = `# Engineering wave

## User Stories in this Wave
| US ID | Scope | Agent Type | Complexity | Can start when |
|---|---|---|---|---|
| ${technicalId} | backend | backend-implementer | sonnet | previous wave complete |

## ${technicalId}: Validate shared metadata
**Scope:** backend → backend-implementer

- [ ] ENG-AC-1: Reject invalid metadata.

### Task ${technicalId}-T1: Validate metadata
**Fulfills:** ENG-AC-1

**Files:**
- Create: \`src/metadata.ts\`
- Test: \`tests/validator.test.ts\`

**Gate commands:**
- \`ENG-AC-1\`: \`npm test -- tests/validator.test.ts\`

**What to build:** Reject invalid metadata before use.
`;
    const wave2Path = path.join(planDir, 'PROJ-1-wave-2-plan.md');
    const technicalConfig = structuredClone(config);
    technicalConfig.waves['1'].ac_commands = [technicalConfig.waves['1'].ac_commands[0]];
    technicalConfig.waves['2'] = structuredClone(technicalConfig.waves['1']);
    technicalConfig.waves['2'].ac_commands[0].id = 'ENG-AC-1';
    technicalConfig.waves['2'].ac_commands[0].task = `Task ${technicalId}-T1`;
    save(technical);
    fs.writeFileSync(planPath, productPlan); fs.writeFileSync(wave2Path, technicalPlan);
    fs.writeFileSync(arch, mixedArch);
    fs.writeFileSync(path.join(planDir, 'wave-gate-config.json'), JSON.stringify(technicalConfig));
    run(['check', 'inputs', base]); run(['check', 'architecture', arch, base]);
    run(['check', 'plan', planDir]);
    assert.equal(JSON.parse(run(['check', 'plan', '--stories', wave2Path]).stdout)[0].id, technicalId);
    run(['render', 'context', 'compile', '1', 'demo']);
    const technicalWorker = fs.readFileSync(path.join(base, 'context/workers/wave-2', `${technicalId}.md`), 'utf8');
    for (const expected of ['ENG-AC-1', 'Approved answer: Validate before writing.', 'TECHNICAL_BOUNDARY', 'Engineering owner', technicalId]) assert.ok(technicalWorker.includes(expected), expected);
    const technicalSlice = run(['render', 'slice', wave2Path, technicalId]).stdout;
    assert.ok(technicalSlice.includes('Approved answer: Validate before writing.'));
    assert.ok(!technicalSlice.includes(`- ${ac} [product`));
    for (const mutate of [
      m => delete m.engineeringStories,
      m => m.engineeringStories = null,
      m => m.engineeringStories.push({ ...m.engineeringStories[0] }),
      m => m.engineeringStories[0].rationale = '',
      m => m.engineeringStories[0].authority = '',
      m => m.engineeringStories[0].id = story,
      m => m.engineeringStories[0].dependsOn = ['PROJ-1-ENG-US-99'],
      m => m.engineering = [],
      m => m.dependencies[0].requires = 'unknown',
    ]) {
      const changed = structuredClone(technical); mutate(changed); save(changed);
      run(['check', 'inputs', base], false); run(['render', 'slice', wave2Path, technicalId], false);
    }
    save(technical);
    fs.writeFileSync(wave2Path, technicalPlan.replace('- [ ] ENG-AC-1: Reject invalid metadata.\n', ''));
    run(['check', 'plan', planDir], false); run(['render', 'context', 'compile', '1', 'demo'], false);
    fs.writeFileSync(wave2Path, technicalPlan);
    fs.writeFileSync(arch, originalArch);
    run(['check', 'architecture', arch, base], false);
    fs.writeFileSync(arch, mixedArch.replace('**Affects:** ENG-US-1', '**Affects:** ENG-US-99'));
    run(['check', 'architecture', arch, base], false);
    fs.writeFileSync(arch, mixedArch + '\n- ENG-US-99\n');
    run(['check', 'architecture', arch, base], false);
    fs.writeFileSync(arch, mixedArch);
    fs.writeFileSync(wave2Path, technicalPlan.replaceAll(technicalId, 'PROJ-1-ENG-US-99'));
    run(['check', 'plan', planDir], false); run(['render', 'context', 'compile', '1', 'demo'], false);
    run(['render', 'slice', wave2Path, 'PROJ-1-ENG-US-99'], false);
    fs.writeFileSync(wave2Path, technicalPlan);
    fs.rmSync(marker);
    run(['check', 'plan', planDir], false); run(['check', 'plan', '--stories', wave2Path], false);
    run(['render', 'context', 'compile', '1', 'demo'], false); run(['render', 'slice', wave2Path, technicalId], false);
    save(technical);

    // A separate checkout can own engineering-only scope without a synthetic PRD.
    const technicalRepo = path.join(temp, provider, 'independent technical checkout');
    const technicalBase = path.join(technicalRepo, 'specs/PROJ-1-demo');
    const technicalPlans = path.join(technicalBase, '3-4_plan');
    fs.mkdirSync(technicalPlans, { recursive: true });
    for (const name of ['source.txt', 'answers.txt']) fs.copyFileSync(path.join(base, name), path.join(technicalBase, name));
    const engineeringOnly = structuredClone(technical);
    engineeringOnly.repositories.push('build'); engineeringOnly.repository = 'build';
    engineeringOnly.engineeringStories[0].repository = 'build'; engineeringOnly.engineering[0].repository = 'build';
    fs.writeFileSync(path.join(technicalBase, 'external-handoff.json'), JSON.stringify(engineeringOnly));
    fs.writeFileSync(path.join(technicalPlans, 'PROJ-1-wave-1-plan.md'), technicalPlan);
    const onlyConfig = { ...technicalConfig, waves: { '1': technicalConfig.waves['2'] } };
    fs.writeFileSync(path.join(technicalPlans, 'wave-gate-config.json'), JSON.stringify(onlyConfig));
    const onlyArch = mixedArch.replace('- PROJ-1-PRD-1', 'None (engineering-only repository scope).');
    fs.writeFileSync(path.join(technicalPlans, 'PROJ-1-architecture.md'), onlyArch);
    assert.deepEqual(resolveInputs(technicalBase).prds, []);
    for (const args of [
      ['check', 'prds', technicalBase],
      ['check', 'architecture', path.join(technicalPlans, 'PROJ-1-architecture.md'), technicalBase],
      ['check', 'plan', technicalPlans], ['render', 'context', 'compile', '1', 'demo'],
      ['render', 'slice', path.join(technicalPlans, 'PROJ-1-wave-1-plan.md'), technicalId],
    ]) {
      const result = spawnSync('bash', [chain, ...args], { cwd: technicalRepo, encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
    }
    assert.ok(fs.readFileSync(path.join(technicalBase, 'context/workers/wave-1', `${technicalId}.md`), 'utf8').includes('TECHNICAL_BOUNDARY'));
    assert.equal(fs.existsSync(path.join(technicalBase, '2_PRDs')), false);
    fs.rmSync(wave2Path); fs.writeFileSync(planPath, plan); fs.writeFileSync(arch, originalArch);
    fs.writeFileSync(path.join(planDir, 'wave-gate-config.json'), JSON.stringify(config)); save();
    // Repo-local success must not claim aggregate completion; shared evidence pins both revisions.
    const integrationPath = path.join(base, 'refinement/integration.json');
    assert.equal(integrationStatus(resolveInputs(base), base).status, 'pending');
    const integrationEvidence = `Combined test: save and reload; command: node integration-test.mjs; result: passed. ui@${'c'.repeat(40)} service@${'b'.repeat(40)}`;
    fs.writeFileSync(path.join(base, 'integration-evidence.txt'), integrationEvidence);
    const integratedManifest = structuredClone(manifest);
    integratedManifest.sources.push({ id: 'integration', path: 'integration-evidence.txt', sha256: sha(integrationEvidence) });
    save(integratedManifest);
    const report = { schemaVersion: 1, baseline: 'product@v1', inputFingerprint: sharedInputFingerprint(base),
      repositories: [{ key: 'ui', revision: 'c'.repeat(40) }, { key: 'service', revision: 'b'.repeat(40) }],
      releaseOrder: ['service', 'ui'],
      outcomes: [{ requirement: id, repositories: ['ui', 'service'], status: 'passed', source: 'integration', evidence: integrationEvidence }] };
    fs.mkdirSync(path.dirname(integrationPath), { recursive: true });
    const saveReport = (value = report) => fs.writeFileSync(integrationPath, JSON.stringify(value));
    saveReport();
    assert.equal(integrationStatus(resolveInputs(base), base).status, 'verified');
    // Changing only the selected repository does not invalidate centrally shared evidence.
    save({ ...integratedManifest, repository: 'service' });
    assert.equal(integrationStatus(resolveInputs(base), base).status, 'verified');
    save(integratedManifest);
    for (const mutate of [r => r.repositories.pop(), r => r.outcomes[0].repositories.pop(), r => r.outcomes = [], r => r.outcomes[0].status = 'failed', r => r.releaseOrder.reverse(), r => r.inputFingerprint = 'f'.repeat(64)]) {
      const changed = structuredClone(report); mutate(changed); saveReport(changed);
      assert.equal(integrationStatus(resolveInputs(base), base).status, 'pending');
    }
    saveReport();
    run(['state', 'init', '1', 'demo']);
    const rendered = run(['render', 'pr', '1', 'demo']).stdout;
    assert.ok(rendered.includes('Shared integration: verified'));
    assert.ok(rendered.includes('ui@' + 'c'.repeat(40)));
    fs.rmSync(integrationPath);
    assert.ok(run(['render', 'pr', '1', 'demo']).stdout.includes('Shared integration: pending'));
    save();
    fs.writeFileSync(marker, '{'); run(['check', 'prds', base], false);
    fs.rmSync(marker); fs.symlinkSync('missing-marker', marker); run(['check', 'inputs', base], false);
    fs.rmSync(marker); assert.equal(resolveInputs(base), null); save();
    assert.equal(fs.readFileSync(path.join(base, 'source.txt'), 'utf8'), source);
    assert.equal(fs.readFileSync(path.join(base, 'answers.txt'), 'utf8'), evidence);
  }
  console.log('external inputs: both providers, real validators/context/slice, immutability, scope, approval and integrity passed');
} finally { fs.rmSync(temp, { recursive: true, force: true }); }
