#!/usr/bin/env node
// Read-only discovery by default; explicit clone/create commands never publish handoffs.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const run = (bin, args, cwd) => execFileSync(bin, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const git = (cwd, ...args) => run('git', args, cwd);
const required = (condition, message) => { if (!condition) throw new Error(message); };
const object = (x) => x && typeof x === 'object' && !Array.isArray(x);
const keys = (x, allowed, label) => {
  required(object(x), `${label}: expected object`);
  required(Object.keys(x).every(k => allowed.includes(k)), `${label}: unknown fields (local bindings belong outside the inventory)`);
};
export function remoteIdentity(remote) {
  const scp = remote.match(/^(?:[^@/:]+@)?([^/:]+):([^/].*)$/);
  let url;
  try { url = new URL(scp && !remote.includes('://') ? `https://${scp[1]}/${scp[2]}` : remote); } catch { return null; }
  if (!['https:', 'http:', 'ssh:'].includes(url.protocol)) return null;
  return `https://${url.hostname.toLowerCase()}${url.port ? `:${url.port}` : ''}/${url.pathname.replace(/^\/+|\/+$/g, '').replace(/\.git$/, '')}`;
}
export function validateInventory(data) {
  keys(data, ['schemaVersion', 'mode', 'coordinationRepo', 'repositories'], 'inventory');
  required(data.schemaVersion === 1, 'unsupported workspace schemaVersion');
  required(['team', 'local-only'].includes(data.mode), 'choose team or explicit local-only mode');
  required(Array.isArray(data.repositories) && data.repositories.length, 'repositories required');
  const seen = new Set();
  for (const repo of data.repositories) {
    keys(repo, ['key', 'role', 'remote', 'planned', 'baseline'], 'repository');
    required(/^[a-z][a-z0-9-]*$/.test(repo.key) && !seen.has(repo.key), 'invalid or duplicate repository key');
    seen.add(repo.key);
    required(['coordination', 'implementation', 'both'].includes(repo.role), `${repo.key}: invalid role`);
    required(typeof repo.planned === 'boolean', `${repo.key}: planned must be boolean`);
    required(repo.remote === null || (typeof repo.remote === 'string' && remoteIdentity(repo.remote) === repo.remote && !new URL(repo.remote).username && !new URL(repo.remote).password && !new URL(repo.remote).search && !new URL(repo.remote).hash), `${repo.key}: remote must be a sanitized canonical HTTPS identity or null`);
    if (repo.baseline) {
      keys(repo.baseline, ['status', 'commit', 'evidence'], 'baseline');
      required(['accepted', 'local-sealed', 'proposed', 'partial', 'missing'].includes(repo.baseline.status), `${repo.key}: invalid baseline status`);
      if (['accepted', 'local-sealed', 'proposed'].includes(repo.baseline.status)) {
        required(/^[a-f0-9]{40}$/.test(repo.baseline.commit), `${repo.key}: immutable baseline commit required`);
        required(typeof repo.baseline.evidence === 'string' && /^(https:\/\/[^\s]+|[a-zA-Z0-9_-][^\s:]*\.md(?:#[^\s]*)?)$/.test(repo.baseline.evidence) && !repo.baseline.evidence.includes('..'), `${repo.key}: portable acceptance/seal evidence required`);
        if (repo.baseline.evidence.startsWith('https:')) {
          const url = new URL(repo.baseline.evidence);
          required(!url.username && !url.password && !url.search, `${repo.key}: credential-free evidence required`);
        }
      }
    }
  }
  const coordination = data.repositories.find(r => r.key === data.coordinationRepo);
  required(coordination && ['coordination', 'both'].includes(coordination.role) && !coordination.planned, 'coordinationRepo must identify an existing coordination repository');
  required(data.mode !== 'team' || coordination.remote, 'team mode requires a coordination remote');
  return data;
}
export function inspectCheckout(path) {
  if (!existsSync(path)) return { status: 'missing', next: 'Select or clone the intended checkout; do not guess a working directory.' };
  let root;
  try { root = git(path, 'rev-parse', '--show-toplevel'); } catch { return { status: 'not-git' }; }
  const remotes = git(root, 'remote').split('\n').filter(Boolean).map(name => ({ name, identity: remoteIdentity(git(root, 'remote', 'get-url', name)) }));
  return { status: 'present', root: realpathSync(root), remotes, dirty: Boolean(git(root, 'status', '--porcelain')), intakeBranches: git(root, 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes').split('\n').filter(s => /intake/i.test(s)), intakeDraft: existsSync(resolve(root, 'specs/intake')), productDocument: existsSync(resolve(root, 'docs/PRODUCT.md')) };
}
export function discover(paths, identity) {
  const candidates = paths.map(inspectCheckout).filter(x => x.status === 'present');
  const unique = [...new Map(candidates.map(x => [x.root, x])).values()];
  const matches = identity ? unique.filter(x => x.remotes.some(r => r.identity === identity)) : unique.filter(x => existsSync(resolve(x.root, 'delivery-workspace.json')));
  for (const match of matches) {
    const marker = resolve(match.root, 'delivery-workspace.json');
    if (existsSync(marker)) validateInventory(JSON.parse(readFileSync(marker, 'utf8')));
  }
  required(matches.length <= 1, 'Ambiguous coordination checkouts; select the owning checkout explicitly');
  return matches[0] ?? { status: 'unidentified', next: 'Request the team repository address or inspect the selected organization; local absence does not establish remote absence.' };
}
export function cloneOrReuse(remote, destination) {
  if (existsSync(destination)) {
    const checkout = inspectCheckout(destination);
    required(checkout.status === 'present' && checkout.root === realpathSync(destination), 'Destination exists and is not the selected Git root; choose another path');
    const matches = git(destination, 'remote').split('\n').filter(Boolean).some(name => {
      const existing = git(destination, 'remote', 'get-url', name);
      return remoteIdentity(remote) ? remoteIdentity(existing) === remoteIdentity(remote) : existing === remote;
    });
    required(matches, 'Destination belongs to a different remote; choose another path');
    return { ...checkout, action: 'reused' };
  }
  // git clone refuses a concurrently populated target and preserves existing content.
  run('git', ['clone', '--', remote, destination]);
  return { ...inspectCheckout(destination), action: 'cloned' };
}

export function ensureGithubRemote(ownerName, visibility, authorized, command = run) {
  required(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(ownerName), 'Specify owner/name');
  required(['private', 'internal', 'public'].includes(visibility), 'Explicit visibility required');
  const inspect = () => {
    try {
      const info = JSON.parse(command('gh', ['api', `repos/${ownerName}`]));
      required(info.full_name?.toLowerCase() === ownerName.toLowerCase(), 'Provider returned a different repository');
      required(info.visibility === visibility, 'Existing repository visibility differs from the selected target');
      const identity = remoteIdentity(info.clone_url);
      required(identity, 'Provider returned no usable repository identity');
      return { identity, visibility: info.visibility };
    } catch (error) {
      // A 404 may conceal a private repo. Only an authenticated owner-scoped absence check permits creation.
      if (String(error.stderr ?? error.message).includes('HTTP 404')) return null;
      throw error;
    }
  };
  const existing = inspect();
  if (existing) return { ...existing, action: 'reused' };
  required(authorized === true, 'Remote creation requires authorization for this exact owner/name, visibility and minimal initial content');
  // Listing the selected owner distinguishes an accessible namespace from an unknown target.
  const owner = JSON.parse(command('gh', ['api', `users/${ownerName.split('/')[0]}`]));
  required(['Organization', 'User'].includes(owner.type), 'Cannot verify target owner');
  if (owner.type === 'User') {
    const current = JSON.parse(command('gh', ['api', 'user']));
    required(current.login?.toLowerCase() === owner.login?.toLowerCase(), 'Cannot create in another personal account; verify owner/access');
  }
  const endpoint = owner.type === 'Organization' ? `orgs/${owner.login}/repos?per_page=100` : 'user/repos?affiliation=owner&per_page=100';
  const pages = JSON.parse(command('gh', ['api', '--paginate', '--slurp', endpoint]));
  required(Array.isArray(pages) && pages.every(Array.isArray), 'Could not verify repository inventory');
  required(!pages.flat().some(r => r.full_name?.toLowerCase() === ownerName.toLowerCase()), 'Target exists but is inaccessible; resolve access');
  const raced = inspect();
  if (raced) return { ...raced, action: 'reused' };
  let creationError;
  try { command('gh', ['repo', 'create', ownerName, `--${visibility}`]); } catch (error) { creationError = error; }
  // Never retry mutation after an uncertain response: verify once, then report the blocker.
  const result = inspect();
  if (!result) throw creationError ?? new Error('Creation not confirmed; inspect target/access before retrying');
  return { ...result, action: creationError ? 'reconciled' : 'created' };
}

export function nextBaselineStep(repo, checkout, evidence = {}) {
  if (repo.role === 'coordination') return 'not-applicable';
  if (repo.planned) return 'bootstrap';
  if (checkout.status !== 'present') return 'locate-checkout';
  if (evidence.drift) return 'propose-drift-audit';
  if (evidence.activeIntake) return 'coordinate-existing-intake';
  if (repo.baseline?.status === 'accepted' && evidence.acceptedRevisionVerified && evidence.sealVerified) return 'reuse-accepted';
  if (repo.baseline?.status === 'accepted') return 'verify-accepted-baseline';
  if (checkout.intakeBranches?.length) return 'coordinate-existing-intake';
  if (repo.baseline?.status === 'local-sealed' || repo.baseline?.status === 'proposed') return 'await-team-acceptance';
  if (checkout.intakeDraft || checkout.productDocument || repo.baseline?.status === 'partial') return 'resume-intake';
  return evidence.hasCode === false ? 'bootstrap' : 'intake';
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [cmd, ...args] = process.argv.slice(2);
    let result;
    if (cmd === 'check' && args.length === 1) result = validateInventory(JSON.parse(readFileSync(args[0], 'utf8')));
    else if (cmd === 'inspect' && args.length === 1) result = inspectCheckout(args[0]);
    else if (cmd === 'discover' && args.length) result = discover(args);
    else if (cmd === 'clone' && args.length === 2) result = cloneOrReuse(...args);
    else if (cmd === 'ensure-github' && args.length >= 2 && args.length <= 3 && (!args[2] || args[2] === '--authorized')) result = ensureGithubRemote(args[0], args[1], args[2] === '--authorized');
    else throw new Error('Usage: workspace.mjs check inventory.json | inspect checkout | discover checkout... | clone remote destination | ensure-github owner/name visibility [--authorized]');
    console.log(JSON.stringify(result, null, 2));
  } catch (error) { console.error(`workspace: ${error.message}`); process.exitCode = 1; }
}
