#!/usr/bin/env node
// Mechanical preservation only: the lead owns scope, complete ranges and classification.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const need = (ok, message) => { if (!ok) throw new Error(message); };
function files(root, prefix = '') {
  return fs.readdirSync(path.join(root, prefix), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name)).flatMap(e => {
    const relative = path.posix.join(prefix, e.name);
    need(!e.isSymbolicLink(), `Symlink not portable: ${relative}`);
    if (e.isDirectory()) return files(root, relative);
    need(e.isFile(), `Not a regular file: ${relative}`);
    return [relative];
  });
}
function contained(root, relative) {
  need(typeof relative === 'string' && relative && !path.isAbsolute(relative) && !relative.includes('\\') && !relative.split('/').includes('..'), `Unsafe relative path: ${relative}`);
  const actual = fs.realpathSync(path.join(root, relative));
  need(actual.startsWith(fs.realpathSync(root) + path.sep), `Path escapes package: ${relative}`);
  return actual;
}
export function inventory(root) {
  return files(root).map(file => ({ id: file, path: file, sha256: sha(fs.readFileSync(path.join(root, file))) }));
}
export function copyPackage(source, destination) {
  const origin = fs.realpathSync(source), target = path.resolve(destination);
  need(!fs.existsSync(target), 'Destination must be new; received files are never overwritten');
  const resolvedTarget = path.join(fs.realpathSync(path.dirname(target)), path.basename(target));
  need(!resolvedTarget.startsWith(origin + path.sep), 'Destination cannot be inside source');
  const before = inventory(origin);
  fs.mkdirSync(target);
  for (const file of before) {
    const out = path.join(target, file.path);
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.copyFileSync(path.join(origin, file.path), out, fs.constants.COPYFILE_EXCL);
  }
  need(JSON.stringify(inventory(target)) === JSON.stringify(before) && JSON.stringify(inventory(origin)) === JSON.stringify(before), 'Copy integrity changed; keep output non-consumable and inspect source');
  return before;
}
export function extractRanges(root, baseline, selections) {
  need(typeof baseline === 'string' && baseline.includes('@') && Array.isArray(selections), 'Baseline identity and range array required');
  const identities = new Set();
  return selections.map(s => {
    need(s && typeof s.sourceId === 'string' && /^[A-Za-z0-9_.-]+$/.test(s.sourceId), 'Source criterion ID required');
    const bytes = fs.readFileSync(contained(root, s.path));
    const text = bytes.toString('utf8');
    need(Buffer.from(text).equals(bytes), `Not UTF-8 text: ${s.path}`);
    const lines = text.split('\n'), { startLine, endLine } = s;
    need(Number.isInteger(startLine) && Number.isInteger(endLine) && startLine >= 1 && endLine >= startLine && endLine <= lines.length, 'Invalid complete line range');
    const excerpt = lines.slice(startLine - 1, endLine).join('\n');
    const escaped = s.sourceId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    need(new RegExp(`(?<![A-Za-z0-9_.-])${escaped}(?![A-Za-z0-9_.-])`).test(excerpt), `Range lacks identity: ${s.sourceId}`);
    const id = `${baseline}:${s.path}:${s.sourceId}`;
    need(!identities.has(id), `Duplicate criterion: ${id}`); identities.add(id);
    return { id, source: s.path, sourceId: s.sourceId, sourceRange: { startLine, endLine }, text: excerpt, repositories: [] };
  });
}
export function sourceStatus(checkout, packagedRevision) {
  need(/^[a-f0-9]{40}$/.test(packagedRevision), 'Full packaged source commit required');
  const git = (...args) => execFileSync('git', args, { cwd: checkout, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const examinedRevision = git('rev-parse', 'HEAD');
  git('cat-file', '-e', `${packagedRevision}^{commit}`);
  return { packagedRevision, examinedRevision, moved: packagedRevision !== examinedRevision,
    changedPaths: git('diff', '--name-status', packagedRevision, examinedRevision),
    workingTreeChanges: git('status', '--porcelain'),
    next: 'Review supplied source context for unexported behavior changes; preserve frozen ACs and request source reconciliation/new packaging where needed.' };
}
export function checkLinks(root) {
  const checked = [], external = [];
  for (const file of files(root).filter(f => /\.(md|html?)$/i.test(f))) {
    const content = fs.readFileSync(path.join(root, file), 'utf8');
    const label = value => value.trim().replace(/\s+/g, ' ').toLowerCase();
    const definitions = new Set([...content.matchAll(/^ {0,3}\[([^\]]+)\]:/gm)].map(m => label(m[1])));
    for (const ref of content.matchAll(/\[([^\]\n]+)\]\[([^\]\n]*)\]/g)) {
      need(definitions.has(label(ref[2] || ref[1])), `Undefined reference link in ${file}: ${ref[2] || ref[1]}`);
    }
    // Reference definitions, inline Markdown links/images and HTML assets cover generated returns.
    const targets = [...content.matchAll(/\]\(<?([^\s)>]+)>?(?:\s+"[^"]*")?\)|^\s*\[[^\]]+\]:\s*<?([^\s>]+)>?|(?:href|src)=["']([^"']+)["']/gm)].map(m => m[1] ?? m[2] ?? m[3]);
    for (const target of targets) {
      if (target.startsWith('#')) continue;
      if (/^https:\/\//i.test(target)) {
        const url = new URL(target);
        need(!url.username && !url.password && !url.search, `Credential/query URL requires manual sanitizing: ${file}`);
        external.push({ file, target }); continue;
      }
      need(!/^[a-z][a-z0-9+.-]*:|^\/\//i.test(target), `Non-portable URL: ${target}`);
      const decoded = decodeURIComponent(target.split(/[?#]/)[0]);
      need(!path.isAbsolute(decoded) && !decoded.includes('\\'), `Non-portable link: ${target}`);
      const relative = path.posix.normalize(path.posix.join(path.posix.dirname(file), decoded));
      contained(root, relative); checked.push({ file, target });
    }
  }
  return { checked, external, limitation: 'External accessibility/pins, fragments and unsupported Markdown syntax require lead review.' };
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const [cmd, ...args] = process.argv.slice(2);
    let result;
    if (cmd === 'copy' && args.length === 2) result = copyPackage(...args);
    else if (cmd === 'inventory' && args.length === 1) result = inventory(args[0]);
    else if (cmd === 'ranges' && args.length === 3) result = extractRanges(args[0], args[1], JSON.parse(fs.readFileSync(args[2], 'utf8')));
    else if (cmd === 'source-status' && args.length === 2) result = sourceStatus(...args);
    else if (cmd === 'links' && args.length === 1) result = checkLinks(args[0]);
    else throw new Error('Usage: package-tools.mjs copy source new-destination | inventory directory | ranges directory baseline@version selections.json | source-status checkout packaged-source-commit | links detached-round-directory');
    console.log(JSON.stringify(result, null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
