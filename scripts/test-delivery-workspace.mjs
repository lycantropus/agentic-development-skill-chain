#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { validateInventory, remoteIdentity, inspectCheckout, discover, cloneOrReuse, ensureGithubRemote, nextBaselineStep } from '../codex/skills/delivery-workspace/scripts/workspace.mjs';
const root = mkdtempSync(join(tmpdir(), 'workspace-test-'));
const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const inventory = { schemaVersion: 1, mode: 'team', coordinationRepo: 'specs', repositories: [
  { key: 'specs', role: 'coordination', remote: 'https://git.example/team/specs', planned: false },
  { key: 'web', role: 'implementation', remote: 'https://git.example/team/web', planned: false, baseline: { status: 'accepted', commit: '1'.repeat(40), evidence: 'baseline-reviews/web.md' } },
  { key: 'api', role: 'implementation', remote: null, planned: true },
] };
try {
  assert.equal(remoteIdentity('git@git.example:team/specs.git'), 'https://git.example/team/specs');
  assert.equal(remoteIdentity('https://user:secret@git.example/team/specs.git?token=secret'), 'https://git.example/team/specs');
  validateInventory(inventory);
  for (const mutate of [x => x.repositories.push(x.repositories[0]), x => x.repositories[0].path = root, x => x.repositories[0].remote = 'https://user:secret@git.example/team/specs', x => x.repositories[1].baseline.commit = 'main', x => x.repositories[1].baseline.evidence = root, x => x.repositories[0].remote = null]) {
    const bad = structuredClone(inventory); mutate(bad); assert.throws(() => validateInventory(bad));
  }
  const offline = structuredClone(inventory); offline.mode = 'local-only'; offline.repositories[0].remote = null; validateInventory(offline);
  const bare = join(root, 'team.git'); git(root, 'init', '--bare', bare);
  const one = join(root, 'developer one');
  assert.equal(cloneOrReuse(bare, one).action, 'cloned');
  git(one, 'config', 'user.email', 'test@example.invalid'); git(one, 'config', 'user.name', 'Test');
  writeFileSync(join(one, 'delivery-workspace.json'), JSON.stringify(inventory));
  writeFileSync(join(one, 'README.md'), 'Team coordination\n');
  git(one, 'add', '.'); git(one, 'commit', '-m', 'Portable workspace'); git(one, 'push', 'origin', 'HEAD');
  mkdirSync(join(root, 'different layout'));
  const two = join(root, 'different layout', 'developer two'); cloneOrReuse(bare, two);
  git(two, 'config', 'user.email', 'test@example.invalid'); git(two, 'config', 'user.name', 'Test');
  assert.deepEqual(JSON.parse(readFileSync(join(two, 'delivery-workspace.json'))), inventory);
  assert(!readFileSync(join(two, 'delivery-workspace.json'), 'utf8').includes(root));
  writeFileSync(join(one, 'uncommitted'), 'preserve me');
  assert.equal(cloneOrReuse(bare, one).action, 'reused');
  assert.equal(readFileSync(join(one, 'uncommitted'), 'utf8'), 'preserve me');
  assert.equal(inspectCheckout(one).dirty, true);
  assert.equal(discover([one]).root, one);
  writeFileSync(join(one, 'delivery-workspace.json'), '{');
  assert.throws(() => discover([one]), /JSON|property/);
  writeFileSync(join(one, 'delivery-workspace.json'), JSON.stringify(inventory));
  assert.throws(() => discover([one, two]), /Ambiguous/);
  assert.equal(discover([join(root, 'absent')]).status, 'unidentified');
  assert.equal(inspectCheckout(join(root, 'absent')).status, 'missing');
  assert.throws(() => cloneOrReuse('https://git.example/other/repo', one), /different remote/);
  assert.throws(() => cloneOrReuse(bare, root), /not the selected Git root/);
  const worktree = join(root, 'work tree'); git(one, 'worktree', 'add', '-b', 'intake-resume', worktree);
  assert.equal(inspectCheckout(worktree).root, worktree);
  assert(inspectCheckout(worktree).intakeBranches.includes('intake-resume'));

  // Two developer edits require Git reconciliation; shared inventory never gains local bindings.
  writeFileSync(join(one, 'questions.md'), 'Q-1: pending\n'); git(one, 'add', 'questions.md'); git(one, 'commit', '-m', 'Question'); git(one, 'push', 'origin', 'HEAD');
  git(two, 'pull', '--ff-only');
  writeFileSync(join(one, 'questions.md'), 'Q-1: product answer\n'); git(one, 'add', 'questions.md'); git(one, 'commit', '-m', 'Answer'); git(one, 'push', 'origin', 'HEAD');
  writeFileSync(join(two, 'questions.md'), 'Q-1: different proposal\n'); git(two, 'add', 'questions.md'); git(two, 'commit', '-m', 'Proposal');
  assert.throws(() => git(two, 'push', 'origin', 'HEAD'));
  assert.throws(() => git(two, 'pull', '--ff-only'));

  const present = { status: 'present', intakeBranches: [], intakeDraft: false, productDocument: false };
  assert.equal(nextBaselineStep(inventory.repositories[0], present), 'not-applicable');
  assert.equal(nextBaselineStep(inventory.repositories[2], { status: 'missing' }), 'bootstrap');
  assert.equal(nextBaselineStep(inventory.repositories[1], present, { acceptedRevisionVerified: true, sealVerified: true }), 'reuse-accepted');
  for (const evidence of [{}, { acceptedRevisionVerified: true }, { sealVerified: true }]) {
    assert.equal(nextBaselineStep(inventory.repositories[1], present, evidence), 'verify-accepted-baseline');
  }
  assert.equal(nextBaselineStep(inventory.repositories[1], present, { activeIntake: { owner: 'developer', pr: 3 } }), 'coordinate-existing-intake');
  const staleIntake = { ...present, intakeBranches: ['intake-already-merged'] };
  assert.equal(nextBaselineStep(inventory.repositories[1], staleIntake), 'verify-accepted-baseline');
  assert.equal(nextBaselineStep(inventory.repositories[1], staleIntake, { acceptedRevisionVerified: true, sealVerified: true }), 'reuse-accepted');
  assert.equal(nextBaselineStep(inventory.repositories[1], present, { acceptedRevisionVerified: true, sealVerified: true, activeIntake: { owner: 'developer', pr: 3 } }), 'coordinate-existing-intake');
  assert.equal(nextBaselineStep({ role: 'implementation' }, staleIntake), 'coordinate-existing-intake');
  assert.equal(nextBaselineStep({ role: 'implementation' }, { ...present, productDocument: true }), 'resume-intake');
  assert.equal(nextBaselineStep({ role: 'implementation' }, present, { hasCode: true }), 'intake');
  for (const status of ['local-sealed', 'proposed']) {
    const repo = { role: 'implementation', baseline: { status } };
    assert.equal(nextBaselineStep(repo, present), 'await-team-acceptance');
    assert.equal(nextBaselineStep(repo, present, { activeIntake: { owner: 'developer', pr: 3 } }), 'coordinate-existing-intake');
  }
  assert.equal(nextBaselineStep({ role: 'implementation' }, present, { drift: true }), 'propose-drift-audit');

  function provider({ exists = false, denied = false, race = false, uncertain = false, invisible = false } = {}) {
    let checks = 0, creates = 0;
    const command = (bin, args) => {
      assert.equal(bin, 'gh');
      if (args[0] === 'repo') { creates++; assert.deepEqual(args, ['repo', 'create', 'team/specs', '--private']); exists = true; if (uncertain) throw new Error('timeout after create'); return ''; }
      if (args[1] === 'repos/team/specs') {
        checks++; if (denied) throw new Error('HTTP 403');
        if (race && checks === 2) exists = true;
        if (!exists) throw new Error('HTTP 404');
        return JSON.stringify({ full_name: 'team/specs', visibility: 'private', clone_url: 'https://git.example/team/specs.git' });
      }
      if (args[1] === 'users/team') return JSON.stringify({ type: 'Organization', login: 'team' });
      assert.deepEqual(args, ['api', '--paginate', '--slurp', 'orgs/team/repos?per_page=100']);
      return JSON.stringify([invisible ? [{ full_name: 'team/specs' }] : []]);
    };
    return { command, creates: () => creates };
  }
  let mock = provider({ exists: true }); assert.equal(ensureGithubRemote('team/specs', 'private', false, mock.command).action, 'reused'); assert.equal(mock.creates(), 0);
  mock = provider(); assert.throws(() => ensureGithubRemote('team/specs', 'private', false, mock.command), /authorization/); assert.equal(mock.creates(), 0);
  assert.throws(() => ensureGithubRemote('team/specs', undefined, true, mock.command), /visibility/);
  mock = provider(); assert.equal(ensureGithubRemote('team/specs', 'private', true, mock.command).action, 'created'); assert.equal(mock.creates(), 1);
  assert.equal(ensureGithubRemote('team/specs', 'private', true, mock.command).action, 'reused'); assert.equal(mock.creates(), 1);
  mock = provider({ denied: true }); assert.throws(() => ensureGithubRemote('team/specs', 'private', true, mock.command), /403/); assert.equal(mock.creates(), 0);
  mock = provider({ invisible: true }); assert.throws(() => ensureGithubRemote('team/specs', 'private', true, mock.command), /inaccessible/); assert.equal(mock.creates(), 0);
  mock = provider({ race: true }); assert.equal(ensureGithubRemote('team/specs', 'private', true, mock.command).action, 'reused'); assert.equal(mock.creates(), 0);
  mock = provider({ uncertain: true }); assert.equal(ensureGithubRemote('team/specs', 'private', true, mock.command).action, 'reconciled'); assert.equal(mock.creates(), 1);
  console.log('delivery-workspace: portable inventory, real Git collaboration/worktrees, intake routing and mocked remote lifecycle passed');
} finally { rmSync(root, { recursive: true, force: true }); }
