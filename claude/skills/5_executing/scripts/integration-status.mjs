// Shared evidence is separate from each repo's state and never inferred from its PR.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
const hash = value => createHash('sha256').update(value).digest('hex');
const pin = value => typeof value === 'string' && /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value);

export function sharedInputFingerprint(base) {
  const inventory = JSON.parse(fs.readFileSync(path.join(base, 'external-handoff.json'), 'utf8'));
  delete inventory.repository;
  return hash(JSON.stringify(inventory));
}

export function integrationStatus(inputs, base) {
  const file = path.join(base, 'refinement', 'integration.json');
  if (!fs.existsSync(file)) return { status: 'pending', reasons: ['shared integration evidence not recorded'] };
  const report = JSON.parse(fs.readFileSync(file, 'utf8'));
  const fail = message => { throw new Error(`${file}: ${message}`); };
  const need = (ok, message) => { if (!ok) fail(message); };
  need(report.schemaVersion === 1 && Array.isArray(report.repositories) && Array.isArray(report.outcomes) && Array.isArray(report.releaseOrder), 'invalid integration report');
  const reasons = [];
  if (report.baseline !== inputs.baselineIdentity || report.inputFingerprint !== sharedInputFingerprint(base)) reasons.push('integration evidence is stale for the shared inputs');
  const revisions = new Map();
  for (const r of report.repositories) {
    need(inputs.repositories.includes(r.key) && !revisions.has(r.key) && pin(r.revision), 'invalid or duplicate repository revision');
    revisions.set(r.key, r.revision);
  }
  for (const key of inputs.repositories) if (!revisions.has(key)) reasons.push(`missing tested revision: ${key}`);
  need(new Set(report.releaseOrder).size === report.releaseOrder.length && report.releaseOrder.every(key => inputs.repositories.includes(key)), 'invalid release order');
  for (const key of inputs.repositories) if (!report.releaseOrder.includes(key)) reasons.push(`missing release order: ${key}`);
  for (const dependency of inputs.dependencies) {
    if (revisions.get(dependency.requires) !== dependency.revision) reasons.push(`incompatible dependency revision: ${dependency.repository} requires ${dependency.requires}`);
    if (report.releaseOrder.indexOf(dependency.requires) >= report.releaseOrder.indexOf(dependency.repository)) reasons.push(`release prerequisite out of order: ${dependency.requires} before ${dependency.repository}`);
  }
  const covered = new Set();
  for (const outcome of report.outcomes) {
    const requirement = inputs.requirements.find(r => r.id === outcome.requirement);
    need(requirement && !covered.has(outcome.requirement), 'unknown or duplicate integration outcome');
    covered.add(outcome.requirement);
    need(Array.isArray(outcome.repositories) && new Set(outcome.repositories).size === outcome.repositories.length && outcome.repositories.every(key => requirement.repositories.includes(key)), 'invalid outcome repository coverage');
    need(['passed', 'failed', 'pending'].includes(outcome.status), 'invalid outcome status');
    if (outcome.status !== 'passed') reasons.push(`${outcome.requirement}: ${outcome.status}`);
    for (const key of requirement.repositories) if (!outcome.repositories.includes(key)) reasons.push(`${outcome.requirement}: missing ${key} integration coverage`);
    const source = inputs.sources.find(s => s.id === outcome.source);
    need(source && typeof outcome.evidence === 'string' && outcome.evidence.trim(), 'outcome needs pinned evidence');
    const bytes = fs.readFileSync(path.join(base, source.path));
    need(hash(bytes) === source.sha256 && bytes.toString('utf8').includes(outcome.evidence), 'integration evidence integrity failure');
    // Evidence must name the exact combination under test, not just individual green repos.
    for (const key of outcome.repositories) if (revisions.has(key)) need(bytes.toString('utf8').includes(revisions.get(key)), `evidence lacks tested revision for ${key}`);
  }
  for (const requirement of inputs.requirements) if (!covered.has(requirement.id)) reasons.push(`missing integration outcome: ${requirement.id}`);
  for (const q of inputs.questions) if (q.blockingRepositories.length && !inputs.responses.some(r => r.question === q.id && r.approved)) reasons.push(`unresolved product question: ${q.id}`);
  reasons.push(...inputs.blockers);
  return { status: reasons.length ? 'pending' : 'verified', reasons, repositories: report.repositories, releaseOrder: report.releaseOrder };
}
