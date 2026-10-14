#!/usr/bin/env node
// Orphan-script check for the prose that drives the chain (skills, references, runner prompts, docs):
//  A. it must not name a script file the `chain` dispatcher routes (use `chain <verb>`); table rows are exempt;
//  B. a path-qualified script reference (`<skill>/scripts/<file>`, `scripts/<file>`) must point at a file that exists;
//  C. every `chain <verb> [<sub>]` must be a verb/sub in the dispatcher table (`chain --list`).
// Usage: check-chain-refs.mjs [repo-root]
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), ".."));
const rows = execFileSync("bash", [path.join(root, "claude/skills/5_executing/scripts/chain"), "--list"], { encoding: "utf8" })
  .trim().split("\n").map(line => line.split("|"));
const routed = [...new Set(rows.map(([, , script]) => script))];
const hasRow = (verb, sub) => rows.some(r => r[0] === verb && r[1] === sub);

// Files that exist as scripts: <skill>/scripts/*, runner/*, repo scripts/*.
const skills = fs.readdirSync(path.join(root, "claude/skills"));
const scriptFiles = new Set(["chain"]);
const listDir = dir => fs.existsSync(dir) ? fs.readdirSync(dir, { withFileTypes: true }).filter(e => e.isFile()).map(e => e.name) : [];
for (const platform of ["claude", "codex"]) for (const skill of skills) listDir(path.join(root, platform, "skills", skill, "scripts")).forEach(n => scriptFiles.add(n));
[...listDir(path.join(root, "runner")), ...listDir(path.join(root, "scripts"))].forEach(n => scriptFiles.add(n));

const files = [];
const walk = (dir, filter) => {
  if (!fs.existsSync(dir)) return;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { if (!["scripts", "evals", "fixtures", "node_modules"].includes(e.name)) walk(full, filter); }
    else if (/\.(md|tmpl|json)$/.test(e.name) && filter(full)) files.push(full);
  }
};
for (const platform of ["claude", "codex"]) walk(path.join(root, platform, "skills"), () => true);
for (const sub of ["prompts", "templates", "schemas"]) walk(path.join(root, "runner", sub), () => true);
walk(path.join(root, "docs"), () => true);
files.push(...["README.md", "runner/README.md"].map(f => path.join(root, f)).filter(f => fs.existsSync(f)));

const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const namedScript = new RegExp(`(?<![\\w.-])(${routed.map(escape).join("|")})(?![\\w-])`);
const problems = [];
for (const file of files) {
  fs.readFileSync(file, "utf8").split("\n").forEach((line, i) => {
    const at = `${path.relative(root, file)}:${i + 1}`;
    const isTableRow = line.trimStart().startsWith("|");
    const named = namedScript.exec(line);
    if (named && !isTableRow) problems.push(`${at}: names script '${named[1]}' — call it through chain (chain --list)`);
    for (const m of line.matchAll(/(?<![\w$.-])([0-9A-Za-z_]+(?:-[0-9A-Za-z_]+)*)\/scripts\/([\w.-]+)/g)) {
      const [, skill, name] = m, file2 = name.replace(/\.+$/, "");
      if (skills.includes(skill) && !["claude", "codex"].some(p => fs.existsSync(path.join(root, p, "skills", skill, "scripts", file2)))) problems.push(`${at}: ${skill}/scripts/${file2} does not exist`);
    }
    for (const m of line.matchAll(/(?<![\w$./-])scripts\/([\w-]+\.(?:sh|mjs))/g)) {
      if (!scriptFiles.has(m[1])) problems.push(`${at}: scripts/${m[1]} does not exist in any skill, runner/ or scripts/`);
    }
    for (const m of line.matchAll(/(?:scripts\/chain|`chain)\s+([a-z]+)(?:\s+([a-z][a-z-]*))?/g)) {
      const [, verb, sub] = m;
      if (!rows.some(r => r[0] === verb)) problems.push(`${at}: 'chain ${verb}' is not a chain verb`);
      else if (sub && !hasRow(verb, sub) && !hasRow(verb, "") && !isTableRow) problems.push(`${at}: 'chain ${verb} ${sub}' is not in the dispatcher table`);
    }
  });
}
if (problems.length) { console.error(problems.join("\n")); console.error(`check-chain-refs: ${problems.length} problem(s)`); process.exit(1); }
console.log(`check-chain-refs: ${files.length} files, ${routed.length} routed scripts, no orphan references`);
