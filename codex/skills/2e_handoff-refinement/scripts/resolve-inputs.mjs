#!/usr/bin/env node
// External inputs remain data: no source rewriting or product approval by inference.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const MARKER = 'external-handoff.json';
const text = v => typeof v === 'string' && v.trim().length > 0;
const hash = v => createHash('sha256').update(v).digest('hex');
const pin = v => typeof v === 'string' && /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(v);

export function resolveInputs(directory, { allowBlocked = false } = {}) {
  const base = path.resolve(directory);
  const marker = path.join(base, MARKER);
  if (!fs.lstatSync(marker, { throwIfNoEntry: false })) return null;
  const fail = message => { throw new Error(`${marker}: ${message}`); };
  let m;
  try { m = JSON.parse(fs.readFileSync(marker, 'utf8')); } catch (e) { fail(`invalid JSON: ${e.message}`); }
  const need = (ok, message) => { if (!ok) fail(message); };
  need(m?.schemaVersion === 1, 'schemaVersion must be 1');
  need(text(m.baseline?.id) && text(m.baseline?.version), 'baseline id and version required');
  const baseline = `${m.baseline.id}@${m.baseline.version}`;
  for (const key of ['repositories', 'sources', 'requirements', 'mappings', 'engineering', 'questions', 'responses', 'dependencies']) need(Array.isArray(m[key]), `${key} must be an array`);
  for (const key of ['sources', 'requirements', 'mappings', 'engineering', 'questions', 'responses', 'dependencies']) need(m[key].every(v => v && typeof v === 'object' && !Array.isArray(v)), `${key} entries must be objects`);
  need(m.repositories.length && m.repositories.every(v => typeof v === 'string' && /^[a-z][a-z0-9-]*$/.test(v)) && new Set(m.repositories).size === m.repositories.length, 'repositories must be unique keys');
  need(m.repositories.includes(m.repository), 'repository must select a listed key');
  const repos = values => Array.isArray(values) && values.length && values.every(r => m.repositories.includes(r)) && new Set(values).size === values.length;
  // An empty owner list is an honest "ownership unresolved" state: it blocks, but is never auto-assigned to the inspected repo.
  const blockers = [], unowned = [];
  const sources = new Map();
  for (const s of m.sources) {
    need(text(s.id) && !sources.has(s.id), 'duplicate or missing source identity');
    need(text(s.path) && !path.isAbsolute(s.path) && !s.path.split(/[\\/]/).includes('..'), `unsafe source path: ${s.path}`);
    let actual, bytes;
    try { actual = fs.realpathSync(path.join(base, s.path)); bytes = fs.readFileSync(actual); } catch (e) { fail(`missing source ${s.path}: ${e.message}`); }
    need(actual.startsWith(fs.realpathSync(base) + path.sep), `source escapes project: ${s.path}`);
    need(/^[a-f0-9]{64}$/.test(s.sha256) && hash(bytes) === s.sha256, `integrity failure: ${s.path}`);
    sources.set(s.id, bytes.toString('utf8'));
  }
  const excerpt = (source, value) => sources.has(source) && text(value) && sources.get(source).includes(value);
  need(m.requirements.length, 'requirements must be nonempty');
  const requirements = new Map();
  for (const r of m.requirements) {
    need(text(r.id) && r.id.startsWith(`${baseline}:`) && !requirements.has(r.id), 'duplicate or unnamespaced requirement identity');
    need(text(r.sourceId) && r.id === `${baseline}:${r.source}:${r.sourceId}` && excerpt(r.source, r.sourceId), `${r.id}: source criterion identity missing or inconsistent`);
    const lines = sources.get(r.source)?.split('\n');
    const range = r.sourceRange;
    need(Number.isInteger(range?.startLine) && Number.isInteger(range?.endLine) && range.startLine >= 1 && range.endLine >= range.startLine && range.endLine <= lines.length, `${r.id}: sourceRange needs valid complete line boundaries`);
    const quote = lines.slice(range.startLine - 1, range.endLine).join('\n');
    const sourceIdentity = new RegExp(`(?<![A-Za-z0-9_.-])${r.sourceId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![A-Za-z0-9_.-])`);
    need(text(r.text) && r.text === quote && sourceIdentity.test(quote), `${r.id}: text must be the complete verbatim sourceRange containing its criterion identity`);
    need(Array.isArray(r.repositories) && (r.repositories.length === 0 || repos(r.repositories)), `${r.id}: invalid repository coverage`);
    if (!r.repositories.length) { unowned.push(r.id); blockers.push(`ownership unresolved: ${r.id}`); }
    requirements.set(r.id, r);
  }
  const refs = values => Array.isArray(values) && values.length && values.every(id => requirements.has(id));
  const questions = new Map();
  for (const q of m.questions) {
    need(text(q.id) && !questions.has(q.id) && refs(q.requirements) && text(q.owner) && text(q.evidence) && text(q.alternatives), 'invalid or duplicate product question');
    need(Array.isArray(q.blockingRepositories) && q.blockingRepositories.every(r => m.repositories.includes(r)), `${q.id}: invalid blocking scope`);
    questions.set(q.id, q);
  }
  const answered = new Set(), responseIds = new Set();
  for (const r of m.responses) {
    need(questions.has(r.question) && !responseIds.has(r.question), 'unknown or duplicate response question');
    need(r.baseline === baseline && r.owner === questions.get(r.question).owner && /^\d{4}-\d{2}-\d{2}$/.test(r.date ?? ''), `${r.question}: response authority/date/baseline mismatch`);
    need(typeof r.approved === 'boolean' && excerpt(r.source, r.answer), `${r.question}: response requires explicit approval flag and pinned answer`);
    responseIds.add(r.question);
    if (r.approved) answered.add(r.question);
  }
  const engineeringStories = m.engineeringStories === undefined ? [] : m.engineeringStories;
  need(Array.isArray(engineeringStories), 'engineeringStories must be an array when supplied');
  const technical = new Map();
  for (const s of engineeringStories) {
    need(s && /^PROJ-[A-Za-z0-9-]+-ENG-US-\d+$/.test(s.id ?? '') && m.repositories.includes(s.repository) && text(s.rationale) && text(s.authority), 'engineering story needs a technical ID, repository, rationale and authority');
    const key = `${s.repository}:${s.id}`;
    need(!technical.has(key), `duplicate engineering story ${key}`);
    need(!Object.hasOwn(s, 'dependsOn'), `${s.id}: use existing wave-plan ordering and pinned repository dependencies, not a second story graph`);
    technical.set(key, s);
  }
  const acs = [], aliases = new Set(), coverage = new Set();
  for (const a of m.mappings) {
    const r = requirements.get(a.requirement);
    need(r && r.repositories.includes(a.repository), 'mapping references unknown requirement/repository scope');
    need(/^PROJ-[A-Za-z0-9-]+-PRD-\d+-US-\d+$/.test(a.story) && typeof a.ac === 'string' && new RegExp(`^${a.story}-AC-[A-Za-z0-9._-]+$`).test(a.ac), 'mapping requires local story and AC aliases');
    const key = `${a.repository}:${a.ac}`, covered = `${a.repository}:${a.requirement}`;
    need(!aliases.has(key) && !coverage.has(covered), `duplicate mapping: ${key}`);
    aliases.add(key); coverage.add(covered);
    if (a.repository === m.repository) acs.push({ id: a.ac, story: a.story, text: r.text, kind: 'product', source: r.id });
  }
  for (const r of requirements.values()) for (const repo of r.repositories) need(coverage.has(`${repo}:${r.id}`), `unmapped requirement: ${repo}:${r.id}`);
  for (const e of m.engineering) {
    need(/^ENG-AC-[A-Za-z0-9._-]+$/.test(e.id ?? '') && text(e.text) && text(e.authority) && Array.isArray(e.requirements) && e.requirements.every(id => requirements.has(id)) && m.repositories.includes(e.repository), 'engineering requirement needs separate ENG-AC identity, text, authority and traceability');
    need(technical.has(`${e.repository}:${e.story}`) || m.mappings.some(a => a.repository === e.repository && a.story === e.story), `${e.id}: engineering story is outside declared scope`);
    const key = `${e.repository}:${e.id}`;
    need(!aliases.has(key), `duplicate engineering identity ${key}`); aliases.add(key);
    if (e.repository === m.repository) acs.push({ id: e.id, story: e.story, text: e.text, kind: 'engineering', source: e.requirements.join(', '), requirements: e.requirements, authority: e.authority });
  }
  for (const s of engineeringStories) need(m.engineering.some(e => e.repository === s.repository && e.story === s.id), `${s.id}: engineering story needs at least one testable ENG criterion`);
  if (unowned.length && !acs.length) blockers.push('selected repository has no resolved scope'); else need(acs.length, 'selected repository has no scope');
  for (const d of m.dependencies) need(m.repositories.includes(d.repository) && m.repositories.includes(d.requires) && d.repository !== d.requires && pin(d.revision) && excerpt(d.source, d.evidence), 'dependency needs repository, requires, pinned revision and pinned evidence');
  if (m.prototype?.kind === 'runnable') need(pin(m.prototype.revision), 'runnable prototype requires immutable revision');
  need(['runnable', 'static', 'none'].includes(m.prototype?.kind) && text(m.prototype?.reference) && Array.isArray(m.prototype?.simulated) && m.prototype.simulated.every(text), 'prototype kind/reference/simulated required');
  blockers.push(...[...questions.values()].filter(q => q.blockingRepositories.includes(m.repository) && !answered.has(q.id)).map(q => q.id));
  if (!(m.team?.status === 'accepted' && pin(m.team.revision) && excerpt(m.team.source, m.team.evidence))) blockers.push('accepted team revision/evidence missing');
  if (m.derivedFrom !== baseline) blockers.push('baseline changed: reconcile derived inputs');
  if (!allowBlocked && blockers.length) fail(`not ready: ${blockers.join(', ')}`);
  return { ...m, engineeringStories, baselineIdentity: baseline, acs, blockers, fingerprint: hash(fs.readFileSync(marker)), prds: [...new Set(acs.filter(a => /-PRD-\d+-US-\d+$/.test(a.story)).map(a => a.story.replace(/-US-\d+$/, '')))] };
}

export function inputDirectory(directory) {
  return path.basename(directory) === '2_PRDs' ? path.dirname(directory) : directory;
}

export function externalStory(inputs, id) {
  if (!inputs) return '';
  const acs = inputs.acs.filter(a => a.story === id);
  if (!acs.length) throw new Error(`external inputs: story ${id} is outside repository scope`);
  const sourceIds = new Set(acs.flatMap(a => a.kind === 'product' ? [a.source] : a.requirements));
  const declaration = inputs.engineeringStories.find(s => s.repository === inputs.repository && s.id === id);
  const questions = inputs.questions.filter(q => q.requirements.some(id => sourceIds.has(id)));
  const responses = inputs.responses.filter(r => r.approved && questions.some(q => q.id === r.question));
  const unresolved = questions.filter(q => !responses.some(r => r.question === q.id)).map(q => {
    const proposal = inputs.responses.find(r => r.question === q.id);
    return `${q.id} (owner: ${q.owner}; blocking repositories: ${q.blockingRepositories.join(', ') || 'none'}): ${q.evidence}\nAlternatives: ${q.alternatives}` +
      (proposal ? `\nUnapproved response (not authority): ${proposal.answer} (source=${proposal.source}, ${proposal.date})` : '');
  });
  return `\n## Pinned external requirements\n\nBaseline: ${inputs.baselineIdentity}; team revision: ${inputs.team.revision}; inventory SHA-256: ${inputs.fingerprint}; repository: ${inputs.repository}\n\n` +
    (declaration ? `Engineering story: ${declaration.id}; rationale: ${declaration.rationale}; authority: ${declaration.authority}\n\n` : '') +
    acs.map(a => `- ${a.id} [${a.kind}; ${a.source}${a.authority ? `; authority: ${a.authority}` : ''}]: ${a.text}`).join('\n') +
    `\n\nExplicitly approved product responses (apply approved amendments to the named requirements; preserve original source AC text):\n${responses.map(r => `${r.question} (${r.owner}, ${r.date}, approved=${r.approved}, source=${r.source}): ${r.answer}`).join('\n') || 'None'}\n\nUnresolved product questions (not approval):\n${unresolved.join('\n\n') || 'None'}\n\nDo not invent product decisions for unresolved questions; keep affected choices open and report missing authority.\n\nDependencies: ${JSON.stringify(inputs.dependencies.filter(d => d.repository === inputs.repository))}\nPrototype: ${JSON.stringify(inputs.prototype)}\n`;
}

export function checkExternalStories(inputs, stories, { complete = false } = {}) {
  if (!inputs) {
    if (stories.some(s => s.acs.some(ac => ac.externalLiteral))) throw new Error('external-ac literals require an external handoff marker');
    if (stories.some(s => /-ENG-US-\d+$/.test(s.id))) throw new Error('engineering stories require registration in an external handoff marker');
    return;
  }
  const expected = new Map(inputs.acs.map(a => [a.id, a]));
  const seen = new Set();
  for (const s of stories) {
    externalStory(inputs, s.id);
    for (const ac of s.acs) {
      const e = expected.get(ac.id);
      if (!e || e.story !== s.id || e.text !== ac.text || seen.has(ac.id)) throw new Error(`external inputs: ${ac.id} is duplicate, outside scope, or differs from pinned wording`);
      seen.add(ac.id);
    }
    for (const e of inputs.acs.filter(a => a.story === s.id)) if (!seen.has(e.id)) throw new Error(`external inputs: missing ${e.id} in ${s.id}`);
  }
  if (complete) for (const e of expected.keys()) if (!seen.has(e)) throw new Error(`external inputs: uncovered ${e}`);
}

if (process.argv[1] && fs.existsSync(process.argv[1]) && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [dir, flag] = process.argv.slice(2);
    if (!dir || (flag && flag !== '--allow-blocked')) throw new Error('usage: resolve-inputs.mjs <project-directory> [--allow-blocked]');
    console.log(JSON.stringify(resolveInputs(dir, { allowBlocked: flag === '--allow-blocked' }) ?? { mode: 'linear' }, null, 2));
  } catch (e) { console.error(e.message); process.exitCode = 1; }
}
